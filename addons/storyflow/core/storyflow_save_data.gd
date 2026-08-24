class_name StoryFlowSaveData
extends RefCounted

# Preloaded by path so parsing never depends on the global class name cache,
# which can be stale or mid-rewrite when the game launches (godotengine/godot#75388).
const StoryFlowCharacter = preload("res://addons/storyflow/core/storyflow_character.gd")
const StoryFlowDataAssetStore = preload("res://addons/storyflow/core/storyflow_data_asset_store.gd")
const StoryFlowTypes = preload("res://addons/storyflow/core/storyflow_types.gd")
const StoryFlowVariant = preload("res://addons/storyflow/core/storyflow_variant.gd")

## Reads and writes the UNIFIED StoryFlow state format shared by the Unreal, Unity and Godot
## plugins, and still reads the LEGACY Godot-only format every save written before v1.3.0 is in.
##
## SHAPE AUTHORITY: storyflow-unity's Runtime/Utilities/StoryFlowStateSerializer.cs and the
## cross-engine golden tests/fixtures/unified-state-v1.json, which tests/test_save_unified.gd
## loads through the reader below. The `dataAssets` key's authority is one step further out —
## the HTML runtime's runtime-data-assets.js snapshot()/restore(), whose table it is
## byte-shape-identical to (engine contract 7), making it the first section all four runtimes
## share verbatim even though the documents around it differ.
##
## Type codes are written as NAMES, never integer codes. Godot and Unreal declare None = 0 and
## Boolean = 1; Unity has no None and starts at Boolean = 0, so a format keyed on integers would
## silently mistype every value moved between engines. The names are the whole mapping.
##
## Globals key by variable ID, character variables key by NAME, and every record carries both an
## id and a name so any engine can match on its native key.
##
## COMPATIBILITY RUNS ONE WAY. This build reads both dialects, so every save a player already has
## keeps loading. A save this build WRITES is NOT readable by a pre-v1.3.0 build: that reader
## looks for the snake_case sections, finds none, and restores nothing while still reporting
## success, which leaves the player on a fresh game rather than on an error. Downgrading the
## plugin below 1.3.0 after saving is therefore not supported.
const SAVE_FORMAT_VERSION := "1"
const SAVE_DIR := "user://storyflow_saves/"

## Which document a parsed save turned out to be, decided by [method _sniff_dialect] and reported
## back on the load result so callers (and tests) can tell the two arms apart.
const DIALECT_UNIFIED := "unified"
const DIALECT_LEGACY := "legacy"


## Write the unified v1 document.
##
## The Data Asset pair is REQUIRED rather than defaulted. Defaulting it would let a caller ship
## saves that silently drop the whole .sfd session, and the SEED is needed alongside the overlay
## because the overlay's values are written BARE — only the declaration can say whether a value
## is array-shaped (contract 7 and [method _bare_value_to_json]).
static func save_to_slot(slot_name: String, global_variables: Dictionary,
		runtime_characters: Dictionary, used_once_only_options: Dictionary,
		data_asset_seed: Dictionary, data_asset_overlay: Dictionary) -> bool:
	_ensure_save_dir()

	var data := {
		"version": SAVE_FORMAT_VERSION,
		"globalVariables": _serialize_variables(global_variables),
		"characters": _serialize_characters(runtime_characters),
		"usedOnceOnlyOptions": used_once_only_options.keys(),
		# ALWAYS PRESENT, {} when the session has written nothing — the reference's envelope
		# convention, and what makes "the key is absent" mean "an older save" rather than "an
		# untouched session".
		"dataAssets": _serialize_data_assets(data_asset_seed, data_asset_overlay),
	}

	var json_string := JSON.stringify(data, "\t")
	var path := SAVE_DIR + slot_name + ".json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("[StoryFlow] Failed to save to slot '%s': %s" % [slot_name, error_string(FileAccess.get_open_error())])
		return false

	file.store_string(json_string)
	file.close()
	return true


## Read a save of EITHER dialect into the manager's restore shape:
##   { "dialect", "global_variables", "runtime_characters", "used_once_only_options",
##     "data_assets" }
## where runtime_characters is `path -> { "variables", ["name"], ["image"] }` for both arms and
## data_assets is the already-TYPED overlay table (empty for a legacy save, which carries none).
##
## [param data_asset_seed] is what types the overlay's bare values; pass the live seed. Without
## it the whole `dataAssets` key drops, which is the correct answer for a caller that has no
## data assets to restore into.
static func load_from_slot(slot_name: String, data_asset_seed: Dictionary = {}) -> Dictionary:
	var path := SAVE_DIR + slot_name + ".json"
	if not FileAccess.file_exists(path):
		push_error("[StoryFlow] Save slot '%s' does not exist" % slot_name)
		return {}

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("[StoryFlow] Failed to load slot '%s': %s" % [slot_name, error_string(FileAccess.get_open_error())])
		return {}

	var json_string := file.get_as_text()
	file.close()

	var parsed = JSON.parse_string(json_string)
	if not parsed is Dictionary:
		push_error("[StoryFlow] Failed to parse save file '%s'" % slot_name)
		return {}

	if _sniff_dialect(parsed) == DIALECT_LEGACY:
		return {
			"dialect": DIALECT_LEGACY,
			"global_variables": _deserialize_variables(_as_dict(parsed.get("global_variables"))),
			# The legacy arm hands back `path -> vars`; wrap it so the manager's restore code
			# has one shape to handle. A legacy character record carries no name or image —
			# their absence is what the manager reads as "keep the current ones".
			"runtime_characters": _wrap_legacy_characters(_deserialize_characters(_as_dict(parsed.get("runtime_characters")))),
			"used_once_only_options": _deserialize_once_only(_as_array(parsed.get("used_once_only_options"))),
			# A legacy save predates .sfd entirely. Replace-on-load with an empty table is the
			# correct restore: seed state, which is the state such a save was made in.
			"data_assets": {},
		}

	return {
		"dialect": DIALECT_UNIFIED,
		"global_variables": _unified_variables_from_json(parsed.get("globalVariables")),
		"runtime_characters": _unified_characters_from_json(parsed.get("characters")),
		"used_once_only_options": _deserialize_once_only(_as_array(parsed.get("usedOnceOnlyOptions"))),
		"data_assets": _deserialize_data_assets(parsed.get("dataAssets"), data_asset_seed),
	}


## Shape guards for the SECTION level. Every reader below tolerates a malformed record inside its
## own section, but the typed helper signatures cannot tolerate a section that is not a container
## at all — and a save file is exactly the input that arrives hand-edited, truncated or
## half-synced. One section of the wrong kind restores as nothing instead of failing the load.
static func _as_dict(value) -> Dictionary:
	return value if value is Dictionary else {}


static func _as_array(value) -> Array:
	return value if value is Array else []


## Which dialect a parsed save is, decided STRUCTURALLY on the section keys.
##
## NOT on the version field, though this engine alone could: the legacy document carries
## `save_version` and the unified one carries `version`, and their values differ only as the
## integer 1 against the string "1" — a distinction one tolerant `int()` anywhere in the chain
## erases. The section keys are what the sibling ports' docs teach as the discriminator, they
## are the thing that actually changes how the rest of the document must be read, and a
## hand-edited or half-migrated file is far more likely to have a plausible version number than
## a plausible mix of camelCase and snake_case sections.
##
## Unknown documents fall through to the UNIFIED arm, whose readers are all tolerant of absent
## sections, so a truncated or foreign file restores nothing rather than restoring garbage.
static func _sniff_dialect(parsed: Dictionary) -> String:
	if parsed.has("global_variables"):
		return DIALECT_LEGACY
	return DIALECT_UNIFIED


static func does_save_exist(slot_name: String) -> bool:
	return FileAccess.file_exists(SAVE_DIR + slot_name + ".json")


static func delete_save(slot_name: String) -> void:
	var path := SAVE_DIR + slot_name + ".json"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


static func list_save_slots() -> PackedStringArray:
	var slots := PackedStringArray()
	var dir := DirAccess.open(SAVE_DIR)
	if dir == null:
		return slots
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".json"):
			slots.append(file_name.get_basename())
		file_name = dir.get_next()
	return slots


# =============================================================================
# Serialization Helpers
# =============================================================================

static func _ensure_save_dir() -> void:
	if not DirAccess.dir_exists_absolute(SAVE_DIR):
		DirAccess.make_dir_recursive_absolute(SAVE_DIR)


# --- Type NAMES, the whole cross-engine mapping ------------------------------

## The wire NAME of a variable type. Unknown / NONE writes "None", which Unity's reader rejects
## and Godot's own [method _parse_type_name] maps back to NONE — a record no engine can use is
## better skipped on the way in than guessed at.
static func _type_name(type: StoryFlowTypes.VariableType) -> String:
	match type:
		StoryFlowTypes.VariableType.BOOLEAN: return "Boolean"
		StoryFlowTypes.VariableType.INTEGER: return "Integer"
		StoryFlowTypes.VariableType.FLOAT: return "Float"
		StoryFlowTypes.VariableType.STRING: return "String"
		StoryFlowTypes.VariableType.ENUM: return "Enum"
		StoryFlowTypes.VariableType.IMAGE: return "Image"
		StoryFlowTypes.VariableType.AUDIO: return "Audio"
		StoryFlowTypes.VariableType.CHARACTER: return "Character"
		StoryFlowTypes.VariableType.MAP: return "Map"
		_: return "None"


## [method _type_name]'s inverse. Deliberately its own table rather than a reuse of
## [method StoryFlowTypes.parse_variable_type]: that one parses the EXPORTER's lowercase wire
## tokens ("boolean"), which the contract pins as case-sensitive, and these are the SAVE format's
## capitalized names ("Boolean"). Two vocabularies, two tables — folding them together would make
## each one silently accept the other's spelling.
static func _parse_type_name(name: String) -> StoryFlowTypes.VariableType:
	match name:
		"Boolean": return StoryFlowTypes.VariableType.BOOLEAN
		"Integer": return StoryFlowTypes.VariableType.INTEGER
		"Float": return StoryFlowTypes.VariableType.FLOAT
		"String": return StoryFlowTypes.VariableType.STRING
		"Enum": return StoryFlowTypes.VariableType.ENUM
		"Image": return StoryFlowTypes.VariableType.IMAGE
		"Audio": return StoryFlowTypes.VariableType.AUDIO
		"Character": return StoryFlowTypes.VariableType.CHARACTER
		"Map": return StoryFlowTypes.VariableType.MAP
		_: return StoryFlowTypes.VariableType.NONE


# --- Variants <-> native JSON ------------------------------------------------

## One variant as a NATIVE JSON value — a bool, a number, a string — never the legacy
## {type, value} envelope. The type lives once, on the record around it.
##
## Values persist EXACTLY as held in memory. This engine resolves the strings table at READ time
## (see the evaluator's _resolve_string_key), so a string-family value in a save is normally the
## raw table key, matching what the other three runtimes write.
static func _variant_to_json(v: StoryFlowVariant):
	if v == null:
		return null
	match v.type:
		StoryFlowTypes.VariableType.BOOLEAN:
			return v.get_bool()
		StoryFlowTypes.VariableType.INTEGER:
			return v.get_int()
		StoryFlowTypes.VariableType.FLOAT:
			return v.get_float()
		StoryFlowTypes.VariableType.STRING, StoryFlowTypes.VariableType.ENUM:
			# The whole string family flattens to STRING in this engine's storage (image, audio
			# and character values are bare path strings), so this one arm covers all of them.
			return v.get_string()
		_:
			return null


## One native JSON value back into a variant of [param type]. NON-THROWING on every shape: a
## token of the wrong kind produces the type's DEFAULT rather than an error, because this input
## arrives from a file a player (or a cloud sync) could have mangled.
static func _variant_from_json(token, type: StoryFlowTypes.VariableType) -> StoryFlowVariant:
	var v := StoryFlowVariant.new()
	match type:
		StoryFlowTypes.VariableType.BOOLEAN:
			v.set_bool(token if token is bool else false)
		StoryFlowTypes.VariableType.INTEGER:
			v.set_int(int(token) if (token is int or token is float) else 0)
		StoryFlowTypes.VariableType.FLOAT:
			v.set_float(float(token) if (token is int or token is float) else 0.0)
		StoryFlowTypes.VariableType.ENUM:
			v.set_enum(str(token) if token is String else "")
		StoryFlowTypes.VariableType.STRING, StoryFlowTypes.VariableType.IMAGE, \
		StoryFlowTypes.VariableType.AUDIO, StoryFlowTypes.VariableType.CHARACTER:
			v.set_string(str(token) if token is String else "")
		_:
			v.type = type
	return v


# --- Variable records --------------------------------------------------------

## Is this variable record array-shaped?
##
## GLOBAL records carry an explicit is_array from the importer and it is authoritative — the same
## declaration-vetoes-residue rule [method _bare_value_to_json] applies, and for the same reason:
## StoryFlowVariant's scalar setters do not clear _array_value, so a variant that once held an
## array and was re-set as a scalar still carries the old elements.
##
## CHARACTER variable records carry no such flag (the importer's character parse never writes
## one), so the element count is the only signal there is. It is exactly the fallback Unity and
## Unreal use for a declaration-less value, and it only has to be harmless: it can misread an
## EMPTIED character array as a scalar, which is what the legacy format did to every array on
## every save.
static func _record_is_array(v: Dictionary) -> bool:
	if v.has("is_array"):
		return bool(v["is_array"])
	var value = v.get("value", null)
	if not value is StoryFlowVariant:
		return false
	return value.type != StoryFlowTypes.VariableType.MAP and value.get_array().size() > 0


## One variable as a v1 typed record: id + name + type NAME + isArray + a native value.
## [param fallback_id] is the table key, used when the record itself carries no id — which is
## every CHARACTER variable, since those key by name.
static func _variable_to_json(fallback_id: String, v: Dictionary) -> Dictionary:
	var type: StoryFlowTypes.VariableType = v.get("type", StoryFlowTypes.VariableType.NONE)
	var is_array := _record_is_array(v)
	var value = v.get("value", null)

	var obj := {
		"id": str(v.get("id", fallback_id)),
		"name": str(v.get("name", fallback_id)),
		"type": _type_name(type),
		"isArray": is_array,
	}

	if type == StoryFlowTypes.VariableType.MAP:
		obj["keyType"] = _type_name(v.get("key_type", StoryFlowTypes.VariableType.STRING))
		obj["valueType"] = _type_name(v.get("value_type", StoryFlowTypes.VariableType.STRING))
		obj["value"] = _map_entries_to_json(value)
	elif is_array:
		var elements := []
		if value is StoryFlowVariant:
			for element in value.get_array():
				elements.append(_variant_to_json(element))
		obj["value"] = elements
	else:
		obj["value"] = _variant_to_json(value if value is StoryFlowVariant else null)

	# Enum value LISTS travel with the record (the golden fixture carries them and Unreal writes
	# them). Godot reads its own back from the project rather than from the save, so these are
	# written for the format and for the other engines' readers, not for this one.
	_append_string_list(obj, "enumValues", v.get("enum_values", []))
	_append_string_list(obj, "keyEnumValues", v.get("key_enum_values", []))
	_append_string_list(obj, "valueEnumValues", v.get("value_enum_values", []))
	return obj


static func _append_string_list(obj: Dictionary, key: String, values) -> void:
	if not values is Array or values.is_empty():
		return
	var out := []
	for value in values:
		out.append(str(value))
	obj[key] = out


## A map variant's ORDERED [{key, value}] entry list (contract 2.1). Entry order is authored and
## observable, and Godot Dictionaries preserve insertion order, so this is a plain walk.
##
## NOTE, unchanged from the legacy writer: aliasing topology does NOT survive a round trip. Every
## variable serializes its own entries, so two variables sharing storage via setMap reload as
## equal-but-detached maps — the same posture as the Unreal and HTML runtimes.
static func _map_entries_to_json(value) -> Array:
	var entries := []
	if not value is StoryFlowVariant:
		return entries
	var map: Dictionary = value.get_map()
	for key in map:
		var entry_value = map[key]
		if entry_value is StoryFlowVariant:
			entries.append({"key": key, "value": _variant_to_json(entry_value)})
	return entries


static func _serialize_variables(variables: Dictionary) -> Dictionary:
	var result := {}
	for var_id in variables:
		var v = variables[var_id]
		if v is Dictionary:
			result[var_id] = _variable_to_json(str(var_id), v)
	return result


## Characters, keyed by their NORMALIZED path, with name and image PERSISTED.
##
## Both are runtime VALUES, not declarations: setCharacterVar("Name") and setCharacterVar("Image")
## mutate them at story time, and the legacy writer persisted neither — so every save silently
## reverted both to the imported defaults. This is the fix; tests/test_save_legacy_shape.gd
## records what it replaced.
static func _serialize_characters(characters: Dictionary) -> Dictionary:
	var result := {}
	for path in characters:
		var c: StoryFlowCharacter = characters[path]
		if c == null:
			continue
		var vars := {}
		for vname in c.variables:
			var vdata = c.variables[vname]
			if vdata is Dictionary:
				# Character variables key by NAME in this format; globals key by id.
				vars[vname] = _variable_to_json(str(vname), vdata)
		result[path] = {
			"name": c.character_name,
			"image": c.image_key,
			"variables": vars,
		}
	return result


# --- The Data Asset overlay: the sparse `dataAssets` key (contract 7) --------
#
# NORMATIVE SOURCE: the HTML runtime's runtime-data-assets.js snapshot()/restore(), whose table
# this key is byte-shape-identical to. BARE values, not the typed records _variable_to_json
# writes for globals and characters: the seed is schema-authoritative and always ships with the
# game, so a save that pinned types would freeze content the author later edited.

## The sparse overlay table: { assetId: { variableId: bare value } }.
static func _serialize_data_assets(seed: Dictionary, overlay: Dictionary) -> Dictionary:
	var root := {}
	for asset_id in overlay:
		var table = overlay[asset_id]
		if not table is Dictionary:
			continue
		var obj := {}
		for variable_id in table:
			var declaration := StoryFlowDataAssetStore.find_declaration(seed, str(asset_id), str(variable_id))
			obj[variable_id] = _bare_value_to_json(table[variable_id], declaration)
		root[asset_id] = obj
	return root


## One overlay value as a BARE JSON value: a native scalar, an array of scalars, or a map's
## ordered [{key, value}] entry list.
##
## THE DECLARATION DECIDES array-vs-scalar, and it can say NO as well as yes. Scalar setters do
## not clear _array_value (only set_array and set_map do), so a variant that once held an array
## and was re-set as a scalar still carries the old elements — trusting "there are elements" over
## the declaration would persist that residue as a JSON array under a scalar declaration, and it
## would reload as a scalar, silently losing the value. No writer produces that state today; the
## rule costs nothing and does not depend on that staying true.
##
## A map is told by the variant's own TYPE rather than by its entry Dictionary being non-empty: a
## Map-typed variant with no entries must still write [] rather than fall through to the scalar
## writer, which would answer null.
##
## The element count only answers for a value with NO declaration at all (deleted from the .sfd
## since the write), which is dropped on the way back in anyway, so that fallback only has to be
## harmless.
static func _bare_value_to_json(value: StoryFlowVariant, declaration: Dictionary):
	if value == null:
		return null

	if value.type == StoryFlowTypes.VariableType.MAP:
		return _map_entries_to_json(value)

	var is_array := value.get_array().size() > 0
	if not declaration.is_empty():
		is_array = bool(declaration.get("is_array", false))
	if is_array:
		var elements := []
		for element in value.get_array():
			elements.append(_variant_to_json(element))
		return elements

	return _variant_to_json(value)


# =============================================================================
# Deserialization: the UNIFIED arm
# =============================================================================

## Global variable records back into the manager's record shape, keyed by id.
##
## A record whose type NAME this engine does not know is SKIPPED rather than failing the whole
## document — that includes the "None" the other engines can emit. The manager applies only the
## VALUES from what comes back, so a skipped record leaves its variable at the state it already
## had, which is the same outcome as an absent record.
static func _unified_variables_from_json(data) -> Dictionary:
	var result := {}
	if not data is Dictionary:
		return result
	for var_id in data:
		var record = data[var_id]
		if not record is Dictionary:
			continue
		var parsed := _variable_from_json(str(var_id), record)
		if not parsed.is_empty():
			result[var_id] = parsed
	return result


## One typed v1 record back into a variable Dictionary, or {} for an unusable one.
static func _variable_from_json(fallback_id: String, record: Dictionary) -> Dictionary:
	var type := _parse_type_name(str(record.get("type", "")))
	if type == StoryFlowTypes.VariableType.NONE:
		return {}

	var is_array := bool(record.get("isArray", false))
	var token = record.get("value", null)
	var v := {
		"id": str(record.get("id", fallback_id)),
		"name": str(record.get("name", fallback_id)),
		"type": type,
		"is_array": is_array,
	}

	if type == StoryFlowTypes.VariableType.MAP:
		var key_type := _parse_type_name(str(record.get("keyType", "")))
		if key_type == StoryFlowTypes.VariableType.NONE:
			key_type = StoryFlowTypes.VariableType.STRING
		var value_type := _parse_type_name(str(record.get("valueType", "")))
		if value_type == StoryFlowTypes.VariableType.NONE:
			value_type = StoryFlowTypes.VariableType.STRING
		v["key_type"] = key_type
		v["value_type"] = value_type
		v["value"] = StoryFlowVariant.from_map(_map_entries_from_json(token, key_type, value_type))
		return v

	if is_array:
		var elements: Array = []
		if token is Array:
			for element in token:
				elements.append(_variant_from_json(element, type))
		var array_variant := StoryFlowVariant.new()
		array_variant.set_array(elements)
		# The ELEMENT TYPE is stated, never inferred: set_array reads the tag off element zero,
		# so an emptied array would come back untyped and a variable that reads back typed or
		# untyped depending on the last writer is a variable whose next save has a different
		# shape.
		array_variant.type = StoryFlowDataAssetStore.storage_type(type)
		v["value"] = array_variant
		return v

	v["value"] = _variant_from_json(token, type)
	return v


## An ordered entry list back into an insertion-ordered Dictionary of coerced key -> variant.
##
## Keys are coerced from the declared keyType exactly as the importer's _coerce_map_key does —
## JSON numbers can parse back as float, and an integer-keyed map must not grow a second, float
## spelling of a key it already has. An entry with NO key is unaddressable and is skipped.
static func _map_entries_from_json(token, key_type: StoryFlowTypes.VariableType,
		value_type: StoryFlowTypes.VariableType) -> Dictionary:
	var entries := {}
	if not token is Array:
		return entries
	for entry_obj in token:
		if not entry_obj is Dictionary or not entry_obj.has("key"):
			continue
		var key = entry_obj["key"]
		if key_type == StoryFlowTypes.VariableType.INTEGER or key is float:
			key = int(key) if (key is int or key is float) else str(key)
		elif not key is int:
			key = str(key)
		entries[key] = _variant_from_json(entry_obj.get("value"), value_type)
	return entries


## Character records back into `path -> { "name", "image", "variables" }`.
##
## name and image are RUNTIME VALUES and are carried only when the document actually has them;
## their absence is what the manager reads as "keep the current ones", which is how a legacy
## save (which never had them) restores correctly through the same code path.
static func _unified_characters_from_json(data) -> Dictionary:
	var result := {}
	if not data is Dictionary:
		return result
	for path in data:
		var record = data[path]
		if not record is Dictionary:
			continue
		var entry := {"variables": {}}
		if record.get("name", null) is String:
			entry["name"] = record["name"]
		if record.get("image", null) is String:
			entry["image"] = record["image"]
		var vars = record.get("variables", {})
		if vars is Dictionary:
			for vname in vars:
				var vrecord = vars[vname]
				if not vrecord is Dictionary:
					continue
				var parsed := _variable_from_json(str(vname), vrecord)
				if not parsed.is_empty():
					entry["variables"][vname] = parsed
		result[path] = entry
	return result


## REPLACE the overlay with the saved table (contract 7). The caller clears FIRST and
## unconditionally, so an absent or malformed key restores seed state — which is exactly the
## state such a save was made in. Merging instead would let the pre-load session's writes survive
## into the loaded game.
##
## Two kinds of entry are DROPPED rather than restored:
##  - an asset the current seed does not carry (deleted since the save). Resolution starts its
##    walk at seed[assetId], so the entry can never be read, and keeping it would make it ride
##    every subsequent save forever. WARNED, once per saved asset: a whole asset gone means the
##    save outlived the .sfd, which is a project-shape change worth surfacing.
##  - a variable no level of that asset's chain declares any more (contract 7's carve-out). QUIET:
##    this is the expected residue of any variable rename, one line per stale entry. The HTML
##    reference keeps such entries because JS values need no declaration; a variant does, and the
##    same read rule that honours a value only where the chain declares the id already makes it
##    dead data.
##
## An asset whose every entry was dropped leaves NO entry behind — an empty inner table would
## ride every subsequent save carrying nothing.
##
## Values are NOT otherwise re-validated: a stale-TYPED entry is typed against the declaration
## through the store's one typing rule and degrades at the accessor via contract 6.1, exactly as
## a stale session write does.
static func _deserialize_data_assets(data, seed: Dictionary) -> Dictionary:
	var result := {}
	if not data is Dictionary:
		return result

	for asset_id in data:
		if not StoryFlowDataAssetStore.has_asset(seed, str(asset_id)):
			push_warning("[StoryFlow] Save load dropped Data Asset '%s' - no such asset in this project" % asset_id)
			continue
		var table = data[asset_id]
		if not table is Dictionary:
			continue

		var values := {}
		for variable_id in table:
			var declaration := StoryFlowDataAssetStore.find_declaration(seed, str(asset_id), str(variable_id))
			if declaration.is_empty():
				continue
			values[variable_id] = _bare_value_from_json(table[variable_id], declaration)
		if not values.is_empty():
			result[asset_id] = values
	return result


## One saved bare value back into a variant, TYPED FROM THE DECLARATION.
##
## The save carries no types, so the declaration is the only authority — and it is the SAME rule,
## through the same function, that build_seed's second pass applies to file overrides. Getting it
## wrong is invisible to a read (an enum and a string both answer get_string) and visible in the
## NEXT save, so a save -> load -> save cycle would stop being stable.
##
## A value the declaration cannot type falls back to the declared TYPE DEFAULT rather than being
## dropped, matching the sibling ports' non-throwing readers: this input arrives from a file, and
## the store's invariant is that a stored value is always of the declared shape.
static func _bare_value_from_json(token, declaration: Dictionary) -> StoryFlowVariant:
	var typed := StoryFlowDataAssetStore.type_value(declaration, token)
	if typed != null:
		return typed
	return StoryFlowDataAssetStore.type_default(declaration)


# =============================================================================
# Deserialization: the LEGACY arm — FROZEN
#
# These read the pre-v1.3.0 document and nothing else. No writer produces that shape any more
# (tests/fixtures/legacy-save-v1.json is the frozen corpus they are pinned against), so there is
# nothing here to keep in step with the format: changing them can only break saves players
# already have. The one thing above them that is NOT frozen is what the manager DOES with the
# records they return, which is shared with the unified arm on purpose.
# =============================================================================

## The legacy character table (`path -> vars`) in the shared restore shape. No name or image:
## the legacy writer never persisted either, and their absence means "keep the current ones".
static func _wrap_legacy_characters(by_path: Dictionary) -> Dictionary:
	var result := {}
	for path in by_path:
		result[path] = {"variables": by_path[path]}
	return result


static func _deserialize_variables(data: Dictionary) -> Dictionary:
	var result := {}
	for var_id in data:
		var entry: Dictionary = data[var_id]
		var v := {
			"id": var_id,
			"name": entry.get("name", ""),
			"type": int(entry.get("type", 0)),
			"is_array": entry.get("is_array", false),
		}
		# Restore map K/V type metadata (absent on pre-map saves → string defaults)
		if v["type"] == StoryFlowTypes.VariableType.MAP:
			v["key_type"] = int(entry.get("key_type", StoryFlowTypes.VariableType.STRING))
			v["value_type"] = int(entry.get("value_type", StoryFlowTypes.VariableType.STRING))
		if entry.has("value"):
			v["value"] = _deserialize_variant(entry["value"])
		result[var_id] = v
	return result


static func _deserialize_variant(data) -> StoryFlowVariant:
	if data is Dictionary:
		var v := StoryFlowVariant.new()
		var t: int = int(data.get("type", 0))
		match t:
			StoryFlowTypes.VariableType.BOOLEAN:
				v.set_bool(bool(data.get("value", false)))
			StoryFlowTypes.VariableType.INTEGER:
				v.set_int(int(data.get("value", 0)))
			StoryFlowTypes.VariableType.FLOAT:
				v.set_float(float(data.get("value", 0.0)))
			StoryFlowTypes.VariableType.STRING:
				v.set_string(str(data.get("value", "")))
			StoryFlowTypes.VariableType.ENUM:
				v.set_enum(str(data.get("value", "")))
			StoryFlowTypes.VariableType.MAP:
				# Tolerant: absent/malformed entry list degrades to an empty map
				# with the MAP type preserved (set_map types the variant); a
				# keyless entry is skipped. JSON numbers parse as float — coerce
				# numeric keys back to the int storage type (the importer's key
				# coercion rule); everything else stores as String.
				var entries := {}
				var raw = data.get("value")
				if raw is Array:
					for entry_obj in raw:
						if not (entry_obj is Dictionary) or not entry_obj.has("key"):
							continue
						var key = entry_obj["key"]
						if key is float:
							key = int(key)
						elif not (key is int):
							key = str(key)
						entries[key] = _deserialize_variant(entry_obj.get("value"))
				v.set_map(entries)
		if data.has("array"):
			var arr: Array = []
			for elem in data["array"]:
				arr.append(_deserialize_variant(elem))
			v.set_array(arr)
		return v
	return StoryFlowVariant.new()


static func _deserialize_characters(data: Dictionary) -> Dictionary:
	var result := {}
	for path in data:
		var entry: Dictionary = data[path]
		var vars := {}
		var vars_data: Dictionary = entry.get("variables", {})
		for vname in vars_data:
			var ventry: Dictionary = vars_data[vname]
			var vdata := {"name": vname, "type": int(ventry.get("type", 0))}
			if vdata["type"] == StoryFlowTypes.VariableType.MAP:
				vdata["key_type"] = int(ventry.get("key_type", StoryFlowTypes.VariableType.STRING))
				vdata["value_type"] = int(ventry.get("value_type", StoryFlowTypes.VariableType.STRING))
			if ventry.has("value"):
				vdata["value"] = _deserialize_variant(ventry["value"])
			vars[vname] = vdata
		result[path] = vars
	return result


static func _deserialize_once_only(data: Array) -> Dictionary:
	var result := {}
	for key in data:
		result[str(key)] = true
	return result
