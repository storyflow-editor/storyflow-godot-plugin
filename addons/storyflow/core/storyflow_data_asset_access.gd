extends RefCounted
## THE ONE `.sfd` HOST LADDER, shared by StoryFlowComponent and StoryFlowManager.
##
## Both public surfaces read and write Data Assets, and before this existed only the component
## could: the whole ladder - id-or-name resolution, the declaration walk, the scalar type gate, the
## P4 character branch, the store write - lived on it, so a game with no component object had no
## way in. Copying it onto the manager would have been two ladders answering one question, which
## the engine contract names as the thing to avoid ("both public mirrors inherit it and cannot
## diverge"). It moved here instead, verbatim, and both surfaces are now thin.
##
## MINTED PER CALL, like the store refs it consults: it holds the manager and the caller's
## PRE-LOCALIZATION fallback language, both of which a host surface can have changed between calls.
## Cheap enough for a host API - these are game-code calls, not an inner loop - and it means
## neither surface can be left holding a stale manager.
##
## THE CACHE CLEAR IS NOT HERE. A write's boolean-memo clear belongs to whoever owns an execution
## context, and the manager owns none; the component clears after a successful call. Returning the
## result and letting the caller act is what keeps this layer free of surface-specific state.

const StoryFlowCharacter = preload("res://addons/storyflow/core/storyflow_character.gd")
const StoryFlowDataAssetStore = preload("res://addons/storyflow/core/storyflow_data_asset_store.gd")
const StoryFlowLocalization = preload("res://addons/storyflow/core/storyflow_localization.gd")
const StoryFlowProject = preload("res://addons/storyflow/core/storyflow_project.gd")
const StoryFlowTypes = preload("res://addons/storyflow/core/storyflow_types.gd")
const StoryFlowVariant = preload("res://addons/storyflow/core/storyflow_variant.gd")

var _mgr: Node = null
var _fallback_language: String = "en"


func _init(manager: Node, fallback_language: String = "en") -> void:
	_mgr = manager
	_fallback_language = fallback_language


## Emit one host-accessor refusal warning AT MOST ONCE per (asset, variable, kind).
##
## A refused accessor is usually a stale NAME - a rename plus a re-sync, an export var nobody
## assigned - and stale names are read from _process. Per-call warnings turn that into a
## continuous flood in the editor output and in player logs, where the first line already said
## everything the hundredth does.
##
## The latch lives on the MANAGER (see should_warn_data_asset_access there) so component churn
## cannot re-arm it, and re-arms on set_project and reset_all_state. The character accessors
## above keep this file's per-call idiom deliberately: this is the new surface, and only the new
## surface changes shape.
func warn_data_asset_once(asset: String, variable_name: String, kind: String, message: String) -> void:
	var mgr := _mgr
	# With no manager there is nothing to latch against; a warning is still better than silence.
	if not mgr or mgr.should_warn_data_asset_access(asset, variable_name, kind):
		push_warning(message)


## The asset id [param asset] names, or "" when nothing (or more than one thing) matches.
##
## ID first and EXACTLY, then a unique display NAME. An ambiguous name FAILS rather than picking:
## a lookup with two right answers has no better one, and silently choosing would make which
## asset a game reads depend on dictionary order.
func resolve_data_asset_id(asset: String) -> String:
	if asset.is_empty():
		return ""
	var mgr := _mgr
	if not mgr:
		return ""
	var seed: Dictionary = mgr.get_data_asset_seed()
	if seed.has(asset):
		return asset

	var matched := ""
	for asset_id in seed:
		var def = seed[asset_id]
		if def is Dictionary and str(def.get("name", "")) == asset:
			if not matched.is_empty():
				warn_data_asset_once(asset, "", "ambiguous",
					"StoryFlow: Data Asset name '%s' is ambiguous - it matches at least '%s' and '%s'. Use the asset id." % [asset, matched, asset_id])
				return ""
			matched = str(asset_id)
	if matched.is_empty():
		warn_data_asset_once(asset, "", "noasset",
			"StoryFlow: No Data Asset with the id or name '%s'" % asset)
	return matched


## The declaration [param variable_name] names on the asset's chain (root-most wins), or {}.
## Warns on both misses, which is the whole of what the typed accessors share above the gate.
func find_data_asset_declaration(asset: String, asset_id: String, variable_name: String) -> Dictionary:
	var mgr := _mgr
	if not mgr:
		return {}
	var declaration := StoryFlowDataAssetStore.find_declaration_by_name(
		mgr.get_data_asset_seed(), asset_id, variable_name)
	if declaration.is_empty():
		warn_data_asset_once(asset, variable_name, "novariable",
			"StoryFlow: Data Asset '%s' declares no variable named '%s'" % [asset, variable_name])
	return declaration


## The scalar type gate: the declared type must be one this accessor answers for, and it must not
## be array-shaped.
func data_asset_scalar_gate(asset: String, variable_name: String, declaration: Dictionary, expected: Array) -> bool:
	if not expected.has(declaration.get("type", StoryFlowTypes.VariableType.NONE)):
		warn_data_asset_once(asset, variable_name, "wrongtype",
			"StoryFlow: Data Asset '%s.%s' is not of the requested type" % [asset, variable_name])
		return false
	if bool(declaration.get("is_array", false)):
		warn_data_asset_once(asset, variable_name, "isarray",
			"StoryFlow: Data Asset '%s.%s' is an array - use get_data_asset_variant" % [asset, variable_name])
		return false
	return true


## One host scalar read: the resolved variant, or null with the warning already emitted.
func read_data_asset_scalar(asset: String, variable_name: String, expected: Array) -> StoryFlowVariant:
	var mgr := _mgr
	if not mgr:
		return null
	# P4 character branch: a seed-missing character id routes to the character system's
	# state (seed-first — see the character-branch block below).
	if routes_to_character(asset):
		return read_character_scalar(asset, variable_name, expected)
	var asset_id := resolve_data_asset_id(asset)
	if asset_id.is_empty():
		return null
	var declaration := find_data_asset_declaration(asset, asset_id, variable_name)
	if declaration.is_empty():
		return null
	if not data_asset_scalar_gate(asset, variable_name, declaration, expected):
		return null
	return StoryFlowDataAssetStore.try_read(mgr.get_data_asset_seed(),
		mgr.get_data_asset_overlay(), data_asset_locale(), asset_id, str(declaration.get("id", "")))


## One host scalar write into the overlay, reporting whether it landed.
##
## The variant is minted against the DECLARATION rather than from the caller's Godot type, so an
## image-declared variable written through set_data_asset_string lands with the tag the store
## expects (StoryFlowDataAssetStore.storage_type) and an enum lands ENUM-tagged.
func write_data_asset_scalar(asset: String, variable_name: String, expected: Array, raw) -> bool:
	var mgr := _mgr
	if not mgr:
		return false
	# P4 character branch, same seed-first routing as the read above.
	if routes_to_character(asset):
		return write_character_scalar(asset, variable_name, expected, raw)
	var asset_id := resolve_data_asset_id(asset)
	if asset_id.is_empty():
		return false
	var declaration := find_data_asset_declaration(asset, asset_id, variable_name)
	if declaration.is_empty():
		return false
	if not data_asset_scalar_gate(asset, variable_name, declaration, expected):
		return false

	var declared_type = declaration.get("type", StoryFlowTypes.VariableType.NONE)
	var value := StoryFlowVariant.new()
	match declared_type:
		StoryFlowTypes.VariableType.BOOLEAN: value.set_bool(bool(raw))
		StoryFlowTypes.VariableType.INTEGER: value.set_int(int(raw))
		StoryFlowTypes.VariableType.FLOAT: value.set_float(float(raw))
		StoryFlowTypes.VariableType.ENUM: value.set_enum(str(raw))
		_: value.set_string(str(raw))

	if not StoryFlowDataAssetStore.try_set(mgr.get_data_asset_seed(),
			mgr.get_data_asset_overlay(), asset_id, str(declaration.get("id", "")), value):
		warn_data_asset_once(asset, variable_name, "writerefused",
			"StoryFlow: Data Asset write '%s.%s' was refused" % [asset, variable_name])
		return false

	# THE CACHE-CLEAR OBLIGATION every .sfd writer carries (StoryFlowDataAssetStore.try_set's
	# header). The accessor's own read is carved out of the boolean memo, but a memoized PARENT
	# above it is not: an option gated through andBool(accessor, true) keeps answering the
	# pre-write value until this runs. Same line, same reason and the same SELECTIVE reach as
	# _handle_set_data_asset_var - a host write can land while a dialogue is parked mid-chain,
	# so it has exactly as much business wiping array outputs as a graph write does: none.
	return true


# =============================================================================
# The P4 character branch of the Data Asset surface (characters engine contract §3/§4)
# =============================================================================
#
# The DA-surface door onto CHARACTERS: a character FILE id passed as [param asset] routes the
# typed accessors above to the character system's runtime state — the one store characters
# have. get_data_asset_int("da_<char id>", "Trust") and a char-var node write are the same
# state by construction.
#
# SEED-FIRST (Unity's inherited branch-order ruling, kept deliberately): an id the data-asset
# seed carries IS a data asset, full stop; only a seed-missing da_ id consults the character
# bridge. The two can never collide — characters never enter the seed (contract §2), pinned
# by test through a real import — so the branch order is a tie-break that can never fire, and
# that is exactly why it is safe to inherit unchanged.
#
# THE SCRIPT-LANE LADDER IS UNTOUCHED: scripts cannot bind characters through DA pins (the
# reference pill's assetId always names a data asset; the editor never offers a character
# there), so the node accessors keep their five-rung ladder with no character branch.
#
# NAME-ROUTED, per amendment A1: character variable access is name-keyed — the record's
# variable map has no rename-stable ids to key by — and the reserved cf_name/cf_image ids
# answer the builtin Name/Image through the shared first-tier predicates (A2(a)).
# A5: this surface answers the STORED name key, never the localized string — a CHARACTER-lane
# property, unchanged by spec §2's .sfd amendment (which moved only how .sfd DECLARATIONS
# resolve, see the block header above); the public get_character_variable is the RESOLVING door.
# A2(b): no write on this branch raises character_variable_changed — the signal is node-lane
# only, a contract property.
# A3(b): a write naming a variable the record does not declare NEVER creates it — refusal
# with this surface's posture (false, warned once).
#
# HOST LANE, so warns latch on the MANAGER's character pair (should_warn_character_id_access,
# re-armed on set_project / reset_all_state only), never the context pair — a host call may
# run with no dialogue anywhere. Refusal kinds compose the variable into the pair's
# id|reason key shape ("novariable:<name>", "wrongtype:<name>", "isarray:<name>"); the
# resolver's own "unloaded" rung joins the same pair. A DANGLING id — seed-missing AND
# bridge-missing — never reaches this branch at all: it falls through to the DA ladder and
# gets the pre-P4 noasset treatment, byte-identical. The ById surface above is the
# deliberate opposite (the GP3 vocabulary ruling): a NEW character surface with no pre-P4
# wording to protect, so its dangling rung warns in the CHARACTER vocabulary instead.


## Whether [param asset] routes to the character branch rather than the DA ladder.
func routes_to_character(asset: String) -> bool:
	var mgr := _mgr
	if not mgr:
		return false
	if not StoryFlowCharacter.is_character_id(asset):
		return false
	if mgr.get_data_asset_seed().has(asset):
		return false
	return mgr.get_character_id_bridge().has(asset)


## The character record and variable row behind one branch access, shared by ALL THREE doors
## (typed read, typed write, variant) so they degrade on exactly the same rungs. Returns {}
## with the warning already emitted on any refusal; a builtin token returns
## {"builtin": "name"/"image"} instead of a row. An EMPTY [param expected] means any-type:
## the variant door skips the type and array rungs (arrays and maps are exactly what it is
## for) while keeping the resolution and novariable rungs shared.
func resolve_character_branch(id: String, variable_name: String, expected: Array) -> Dictionary:
	var mgr := _mgr
	var record_key := StoryFlowCharacter.resolve_character_key(
		mgr.get_character_id_bridge(), mgr.get_runtime_characters(), id, mgr)
	if record_key.is_empty():
		return {} # unloaded — warned once by the resolver, on the manager pair
	var character: StoryFlowCharacter = mgr.get_runtime_characters()[record_key]

	# Builtins first — the same shadowing order every builtin arm keeps (first tier, A2(a)).
	# Name behaves as a string declaration and Image as an image declaration, so the string
	# door answers both and a mistyped read refuses like any other wrong type.
	if StoryFlowCharacter.is_name_token(variable_name):
		if not expected.is_empty() and not expected.has(StoryFlowTypes.VariableType.STRING):
			warn_character_access_once(id, "wrongtype:%s" % variable_name,
				"StoryFlow: Character variable '%s.%s' is not of the requested type" % [id, variable_name])
			return {}
		return {"character": character, "builtin": "name"}
	if StoryFlowCharacter.is_image_token(variable_name):
		if not expected.is_empty() and not expected.has(StoryFlowTypes.VariableType.IMAGE):
			warn_character_access_once(id, "wrongtype:%s" % variable_name,
				"StoryFlow: Character variable '%s.%s' is not of the requested type" % [id, variable_name])
			return {}
		return {"character": character, "builtin": "image"}

	if not character.variables.has(variable_name):
		warn_character_access_once(id, "novariable:%s" % variable_name,
			"StoryFlow: Character '%s' declares no variable named '%s'" % [id, variable_name])
		return {}
	var row: Dictionary = character.variables[variable_name]
	if not expected.is_empty() and not expected.has(row.get("type", StoryFlowTypes.VariableType.NONE)):
		warn_character_access_once(id, "wrongtype:%s" % variable_name,
			"StoryFlow: Character variable '%s.%s' is not of the requested type" % [id, variable_name])
		return {}
	if not expected.is_empty() and bool(row.get("is_array", false)):
		warn_character_access_once(id, "isarray:%s" % variable_name,
			"StoryFlow: Character variable '%s.%s' is an array - use get_data_asset_variant" % [id, variable_name])
		return {}
	return {"character": character, "row": row}


## One character-branch scalar read: the resolved variant, or null with the warning emitted.
func read_character_scalar(id: String, variable_name: String, expected: Array) -> StoryFlowVariant:
	var resolved := resolve_character_branch(id, variable_name, expected)
	if resolved.is_empty():
		return null
	var character: StoryFlowCharacter = resolved["character"]
	match resolved.get("builtin", ""):
		"name":
			return StoryFlowVariant.from_string(character.character_name)
		"image":
			return StoryFlowVariant.from_string(character.image_key)
	var value = resolved["row"].get("value")
	return value if value is StoryFlowVariant else null


## One character-branch scalar write into the character's runtime state, reporting whether it
## landed. The variant is minted against the row's declared type, like the .sfd write above;
## the write REPLACES the row's value the way the node lane does. A3(b): a missing variable
## was already refused in _resolve_character_branch — nothing here can create one.
func write_character_scalar(id: String, variable_name: String, expected: Array, raw) -> bool:
	var resolved := resolve_character_branch(id, variable_name, expected)
	if resolved.is_empty():
		return false
	var character: StoryFlowCharacter = resolved["character"]
	match resolved.get("builtin", ""):
		"name":
			character.character_name = str(raw)
			return true
		"image":
			character.image_key = str(raw)
			return true

	var row: Dictionary = resolved["row"]
	var value := StoryFlowVariant.new()
	match row.get("type", StoryFlowTypes.VariableType.NONE):
		StoryFlowTypes.VariableType.BOOLEAN: value.set_bool(bool(raw))
		StoryFlowTypes.VariableType.INTEGER: value.set_int(int(raw))
		StoryFlowTypes.VariableType.FLOAT: value.set_float(float(raw))
		StoryFlowTypes.VariableType.ENUM: value.set_enum(str(raw))
		_: value.set_string(str(raw))
	row["value"] = value

	# THE CACHE-CLEAR OBLIGATION, in parity with _write_data_asset_scalar above: a char-var
	# boolean behind a memoized parent goes stale across a host write in exactly the same
	# way a .sfd one does. No overlay is touched — character state lives on the character.
	return true


## The ELEMENT-level twin of the scalar gate's string-family tolerance: a value stored as a string
## satisfies a string, image, audio or character declaration, because all four store the same way.
## ENUM is excluded for the same reason the scalar gate excludes it - it carries its own type tag.
func element_type_matches(declared, offered) -> bool:
	if offered == StoryFlowTypes.VariableType.STRING:
		return declared == StoryFlowTypes.VariableType.STRING 			or declared == StoryFlowTypes.VariableType.IMAGE 			or declared == StoryFlowTypes.VariableType.AUDIO 			or declared == StoryFlowTypes.VariableType.CHARACTER
	return declared == offered


## The store write and cache clear the two container setters share - the tail of
## _write_data_asset_scalar with the scalar gate already behind it.
func commit_data_asset_container(asset: String, asset_id: String, variable_name: String,
		declaration: Dictionary, value: StoryFlowVariant) -> bool:
	var mgr := _mgr
	if not StoryFlowDataAssetStore.try_set(mgr.get_data_asset_seed(),
			mgr.get_data_asset_overlay(), asset_id, str(declaration.get("id", "")), value):
		warn_data_asset_once(asset, variable_name, "writerefused",
			"StoryFlow: Data Asset write '%s.%s' was refused" % [asset, variable_name])
		return false
	return true


## The lookup context both host .sfd doors hand the store, built in ONE place so the two cannot
## drift (the same reason the node lane's four accessor pins travel as one Dictionary).
##
## NO SCRIPT, ON EITHER SIDE OF A DIALOGUE - which is the one way this differs from
## [method _resolve_string], and deliberately: that door adds the running script's own strings
## table, while a .sfd id is keyed by data-assets.json and merged into the project globals, so a
## script table could only SHADOW it and which dialogue happened to be open would decide what an
## item is called. A host .sfd read therefore answers the same text whether or not a dialogue is
## running. [member _fallback_language] is the PRE-LOCALIZATION fallback here exactly as it is there.
func data_asset_locale() -> Dictionary:
	var mgr := _mgr
	if not mgr:
		return {}
	var project: StoryFlowProject = mgr.get_project()
	if not project:
		return {}
	return StoryFlowLocalization.reading_locale(
		mgr.get_localization(), project.global_strings, _fallback_language)


# =============================================================================
# Array Variable Access
# =============================================================================


## Emit one character-branch refusal warning AT MOST ONCE per (id, reason), on the manager's
## host-lane character pair — the same caller-formats-inside-the-if shape as
## warn_data_asset_once above.
func warn_character_access_once(id: String, reason: String, message: String) -> void:
	var mgr := _mgr
	if not mgr or mgr.should_warn_character_id_access(id, reason):
		push_warning(message)


## The UNTYPED door: the resolved value whatever its declared type, as a DETACHED copy, or null.
##
## READ-ONLY on purpose. It is how a host reaches an array or a map (the typed accessors above
## are scalar-only) and how it reads a value whose type it does not want to hardcode. A write
## needs a declaration to mint the right element tags against — that is what the typed setters
## and the graph's Set node do.
##
## No type gate runs here, so the caller owns checking what came back; the variant's own type tag
## says what it is.
## Replace a Data Asset's ARRAY variable with [param elements]. True when the write landed.
##
## The container half of the surface, which used to be read-only: every type could be READ (scalars
## typed, arrays and maps through get_data_asset_variant) and only scalars could be written, so a
## Data Asset holding a list was a list a game could not edit - the graph's Set node was the only
## way in.
##
## TWO TYPED SETTERS, NOT ONE VARIANT SETTER, and that is the design rather than a detail. A
## StoryFlowVariant cannot say whether it IS an array, so a variant setter could not tell "write an
## empty array" from "the caller passed a scalar", and writing the second over an array declaration
## leaves a value nothing can read - which is why V2 left the container half out rather than
## half-building it. Here the shape is in the SIGNATURE, so there is nothing to infer.
##
## THE SHAPE GATE runs before anything is written: the declaration must be an array (never a map,
## never a scalar) and every element must match its declared type. One mismatch refuses the WHOLE
## write - a partial list is a shape no author declared. An EMPTY list is a legitimate write and
## clears the variable.
func set_array(asset: String, variable_name: String, elements: Array) -> bool:
	var mgr := _mgr
	if not mgr:
		return false
	var asset_id := resolve_data_asset_id(asset)
	if asset_id.is_empty():
		return false
	var declaration := find_data_asset_declaration(asset, asset_id, variable_name)
	if declaration.is_empty():
		return false

	var declared_type = declaration.get("type", StoryFlowTypes.VariableType.NONE)
	if not bool(declaration.get("is_array", false)) or declared_type == StoryFlowTypes.VariableType.MAP:
		warn_data_asset_once(asset, variable_name, "notarray",
			"StoryFlow: Data Asset '%s.%s' is not an array" % [asset, variable_name])
		return false

	var typed: Array = []
	for element in elements:
		if not (element is StoryFlowVariant) or not element_type_matches(declared_type, element.type):
			warn_data_asset_once(asset, variable_name, "wrongelement",
				"StoryFlow: an element offered to '%s.%s' does not match its declared type" % [asset, variable_name])
			return false
		typed.append(element)

	var value := StoryFlowVariant.new()
	value.set_array(typed)
	# set_array infers `type` from the FIRST element and has nothing to infer from when the list is
	# empty, so the DECLARED type is stamped after: an empty write must still land as an array of
	# that type rather than as a type-less variant.
	value.type = declared_type
	return commit_data_asset_container(asset, asset_id, variable_name, declaration, value)


## Replace a Data Asset's MAP variable with these entries. The map twin of
## [method set_array] - see it for why the shape lives in the signature.
##
## The gate is one step wider: every KEY must match the declared key type and every VALUE the
## declared value type. KEYS ARE RAW (a String or an int) because that is how this engine stores
## them; only values are variants. Parallel arrays mirror the map getters' shape, and a length mismatch refuses
## rather than truncating to the shorter, which would silently drop entries the caller listed. Entry
## ORDER is the caller's and is preserved.
func set_map(asset: String, variable_name: String, keys: Array, values: Array) -> bool:
	var mgr := _mgr
	if not mgr:
		return false
	var asset_id := resolve_data_asset_id(asset)
	if asset_id.is_empty():
		return false
	var declaration := find_data_asset_declaration(asset, asset_id, variable_name)
	if declaration.is_empty():
		return false

	if declaration.get("type", StoryFlowTypes.VariableType.NONE) != StoryFlowTypes.VariableType.MAP:
		warn_data_asset_once(asset, variable_name, "notmap",
			"StoryFlow: Data Asset '%s.%s' is not a map" % [asset, variable_name])
		return false

	if keys.size() != values.size():
		warn_data_asset_once(asset, variable_name, "mapcount",
			"StoryFlow: '%s.%s' was offered %d keys and %d values" % [asset, variable_name, keys.size(), values.size()])
		return false

	var key_type = declaration.get("key_type", StoryFlowTypes.VariableType.NONE)
	var value_type = declaration.get("value_type", StoryFlowTypes.VariableType.NONE)
	# Keys are RAW (a String or an int), because that is how this engine stores them; only values
	# are variants. Checking a raw key against its declared type is therefore a GDScript type test.
	var key_is_text: bool = key_type == StoryFlowTypes.VariableType.STRING 		or key_type == StoryFlowTypes.VariableType.ENUM
	# A DICTIONARY keyed by the raw key with variant values - the shape this engine stores maps in
	# (see _snapshot_map_entries), not an entry list. GDScript preserves insertion order, so the
	# caller's order is the stored order.
	var entries := {}
	for i in keys.size():
		var k = keys[i]
		var v = values[i]
		var key_ok: bool = (typeof(k) == TYPE_STRING) if key_is_text else (typeof(k) == TYPE_INT)
		if not key_ok or not (v is StoryFlowVariant) or not element_type_matches(value_type, v.type):
			warn_data_asset_once(asset, variable_name, "wrongentry",
				"StoryFlow: an entry offered to '%s.%s' does not match its declared key/value types" % [asset, variable_name])
			return false
		entries[k] = v

	var value := StoryFlowVariant.new()
	value.set_map(entries)
	return commit_data_asset_container(asset, asset_id, variable_name, declaration, value)
