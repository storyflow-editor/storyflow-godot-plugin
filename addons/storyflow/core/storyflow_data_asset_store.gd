class_name StoryFlowDataAssetStore
extends RefCounted

# Preloaded by path so parsing never depends on the global class name cache,
# which can be stale or mid-rewrite when the game launches (godotengine/godot#75388).
const StoryFlowProject = preload("res://addons/storyflow/core/storyflow_project.gd")
const StoryFlowTypes = preload("res://addons/storyflow/core/storyflow_types.gd")
const StoryFlowVariant = preload("res://addons/storyflow/core/storyflow_variant.gd")

## The .sfd Data Asset STORE (engine contract section 3) and its chain RESOLVER (section 4).
##
## NORMATIVE SOURCE: the HTML runtime's src/renderer/runtime/runtime-data-assets.js. Its
## resolveEntry() is the chain walk every function here mirrors, isDeclaredOnChain() the
## write guard, declaration() the root-most declaration lookup and declMatches() the
## snapshot rule. Where this file and that one disagree, that one is right. The shared
## golden fixtures under tests/fixtures/engine-contract/ are generated from it and pin the
## agreement (tests/test_data_asset_store.gd).
##
## The store is two halves, both plain Dictionaries owned by StoryFlowManager and passed in
## so tests can drive the resolver against a seed built straight from the fixture JSON:
##  - the SEED: the imported table, keyed by assetId. Read-only, forever.
##  - the OVERLAY: this session's script writes, assetId -> { variableId -> StoryFlowVariant }.
##    Cleared on a game reset, persisted sparsely in saves (section 7).
##
## Definition shape (one entry per .sfd file, flat by asset id):
##   { "id", "name", "parent", "variables": Array[Dictionary], "overrides": { varId -> StoryFlowVariant } }
## Declaration shape (the ordered "variables" entries — DECLARATION ORDER IS CONTRACTUAL):
##   { "id", "name", "type": VariableType, "is_array", "key_type", "value_type",
##     "enum_values", "key_enum_values", "value_enum_values", "value": StoryFlowVariant }
##
## ONE HOLE IN "the seed is never mutated": find_declaration and find_declaration_by_name
## hand back the declaration Dictionary BY REFERENCE into the seed, and GDScript has no
## const to stop a caller writing through it. Everything else here copies —
## [method try_resolve] duplicates out, [method try_set] duplicates in — so those two are the
## only way to reach seed storage. Read declarations, never write to them.
##
## Deliberately does NOT resolve string-table keys the way character and global variables do:
## data-assets.json carries no strings table (the exporter writes .sfd values verbatim), so a
## .sfd string value is a LITERAL, and running the lookup over it would replace every literal
## with a failed lookup.

## Chain depth cap, matching the reference implementation's MAX_DEPTH (contract section 4.4).
## The walk tests the counter BEFORE incrementing it, exactly like runtime-data-assets.js's
## `depth++ <= MAX_DEPTH`, so MAX_CHAIN_DEPTH ancestors PLUS the starting level — 65 levels —
## are visited before a malformed chain is abandoned. A cycle is caught earlier by the
## visited set.
##
## Deliberately NOT StoryFlowExecutionContext.MAX_EVALUATION_DEPTH (100), despite the family
## resemblance. That one is a local stack-safety limit this plugin chose for itself; this one
## is a CONTRACT value shared by all four runtimes, and moving it would make Godot resolve a
## chain the other three abandon (or the reverse).
const MAX_CHAIN_DEPTH := 64


# =============================================================================
# Seed construction
# =============================================================================

## Build the runtime seed from a project's imported Data Assets (contract section 3 init).
##
## Clears [param out_seed] IN PLACE and refills it — never rebinds, because the manager hands
## this same dictionary to every running dialogue and a fresh object would strand them.
## The caller clears the overlay too; a fresh seed is a fresh session.
##
## TWO PASSES, and they cannot be merged. Pass 1 builds every level with its declarations and
## NO overrides. Pass 2 types each stored override against the declaration that owns its id
## somewhere on the chain — an ancestor pass 1 may not have reached yet, because assets arrive
## keyed by id in dictionary order and nothing orders them leaf-to-root.
##
## The declaration ARRAY is shared by reference with [param project] rather than copied: the
## seed is read-only forever and reads copy out, so there is nothing for a copy to protect
## against, and this runs again on every game reset.
static func build_seed(project: StoryFlowProject, out_seed: Dictionary) -> void:
	out_seed.clear()
	if project == null:
		return

	var defs: Dictionary = project.data_assets

	# --- Pass 1: levels and declarations, overrides left empty ---
	for asset_id in defs:
		var raw_def = defs[asset_id]
		if not raw_def is Dictionary:
			continue
		var parent = raw_def.get("parent", "")
		var variables = raw_def.get("variables", [])
		out_seed[asset_id] = {
			# The MAP KEY is the authoritative assetId — it is what the pills, the resolver
			# and the save key all use, and what the walk's visited set is keyed on.
			"id": str(asset_id),
			"name": str(raw_def.get("name", "")),
			"parent": "" if parent == null else str(parent),
			"variables": variables if variables is Array else [],
			"overrides": {},
		}

	# --- Pass 2: overrides, typed against the chain's declaration ---
	for asset_id in defs:
		var raw_def = defs[asset_id]
		if not raw_def is Dictionary:
			continue
		if not out_seed.has(asset_id):
			continue
		var raw_overrides = raw_def.get("raw_overrides", {})
		if not raw_overrides is Dictionary:
			continue
		var overrides: Dictionary = out_seed[asset_id]["overrides"]
		for variable_id in raw_overrides:
			var declaration := find_declaration(out_seed, str(asset_id), str(variable_id))
			if declaration.is_empty():
				# ORPHAN: the base variable this override shadowed was deleted. The resolver
				# would ignore it anyway (section 4.3 honours a value only where the chain still
				# declares the id), and there is nothing to type it against, so it never
				# enters the seed at all.
				print("[StoryFlow] Data Asset '%s' overrides '%s', which no level of its chain declares - dropping the override." % [asset_id, variable_id])
				continue
			var value := type_value(declaration, raw_overrides[variable_id])
			if value == null:
				# Dropping HERE rather than at read time is the whole point: try_resolve
				# answering a value must always mean the caller has one of the declared shape.
				print("[StoryFlow] Data Asset '%s' has an override of '%s' that does not fit its declaration - dropping the override." % [asset_id, declaration.get("name", variable_id)])
				continue
			overrides[variable_id] = value


# =============================================================================
# Value typing
# =============================================================================

## The variant TYPE TAG a declared .sfd type stores its values under.
##
## The string family (string / image / audio / character) all store as STRING because
## [method StoryFlowVariant.get_string] only answers for STRING and ENUM — the same flattening
## [code]_parse_variant[/code] already does for character and global variables. ENUM keeps its
## own tag, which is what makes an enum value distinguishable from a plain string.
static func storage_type(declared_type: StoryFlowTypes.VariableType) -> StoryFlowTypes.VariableType:
	match declared_type:
		StoryFlowTypes.VariableType.IMAGE, \
		StoryFlowTypes.VariableType.AUDIO, \
		StoryFlowTypes.VariableType.CHARACTER:
			return StoryFlowTypes.VariableType.STRING
		_:
			return declared_type


## Type one raw JSON value against the declaration that owns it, or [code]null[/code] when the
## JSON cannot produce a value of the declared shape.
##
## THE one typing rule for .sfd values, used for both a declaration's own default (at import)
## and a stored override (in [method build_seed] pass 2) — two code paths producing values for
## the same declaration would be two chances to disagree about the shape a read hands out.
##
## Driven by the DECLARATION, not by the JSON: an enum array's elements come out ENUM-tagged
## rather than STRING-tagged, an integer-declared 2 stays an int where the JSON parser would
## have guessed, and an empty array stays array-shaped.
static func type_value(declaration: Dictionary, raw) -> StoryFlowVariant:
	if declaration.is_empty() or raw == null:
		return null

	var declared_type: StoryFlowTypes.VariableType = declaration.get("type", StoryFlowTypes.VariableType.NONE)

	if declared_type == StoryFlowTypes.VariableType.MAP:
		# Map values are ORDERED ENTRY LISTS (section 2.1), never JSON objects. Anything else
		# cannot be read as a map, so it is not stored as one either.
		if not raw is Array:
			return null
		return StoryFlowVariant.from_map(_type_map_entries(declaration, raw))

	if bool(declaration.get("is_array", false)):
		if not raw is Array:
			return null
		var elements: Array = []
		for item in raw:
			var element := _type_scalar(declared_type, item)
			if element == null:
				return null
			elements.append(element)
		var array_variant := StoryFlowVariant.new()
		array_variant.set_array(elements)
		# set_array infers the tag from element ZERO (storyflow_variant.gd:92-93), which
		# leaves an EMPTY array untyped. The declaration is the authority — stamp it.
		array_variant.type = storage_type(declared_type)
		return array_variant

	if raw is Array or raw is Dictionary:
		return null
	return _type_scalar(declared_type, raw)


## The value a declaration with no usable JSON resolves to: its TYPE DEFAULT, array- and
## map-shaped where the declaration says so. Never fails.
##
## A declaration carrying no value at all still RESOLVES (contract section 4.3 asks only whether
## some level declares the id) — it just resolves to this.
static func type_default(declaration: Dictionary) -> StoryFlowVariant:
	var declared_type: StoryFlowTypes.VariableType = declaration.get("type", StoryFlowTypes.VariableType.NONE)

	if declared_type == StoryFlowTypes.VariableType.MAP:
		return StoryFlowVariant.from_map({})

	if bool(declaration.get("is_array", false)):
		var array_variant := StoryFlowVariant.new()
		array_variant.set_array([])
		array_variant.type = storage_type(declared_type)
		return array_variant

	return _scalar_default(declared_type)


static func _scalar_default(declared_type: StoryFlowTypes.VariableType) -> StoryFlowVariant:
	var variant := StoryFlowVariant.new()
	variant.type = storage_type(declared_type)
	return variant


## One scalar typed against its declared type, or [code]null[/code] when the JSON does not fit.
## Integer and float declarations accept either JSON numeric shape (JSON cannot express 0.0
## distinctly); everything else must arrive as its own JSON type.
static func _type_scalar(declared_type: StoryFlowTypes.VariableType, raw) -> StoryFlowVariant:
	if raw == null:
		return null
	match declared_type:
		StoryFlowTypes.VariableType.BOOLEAN:
			if not raw is bool:
				return null
			return StoryFlowVariant.from_bool(raw)
		StoryFlowTypes.VariableType.INTEGER:
			if not (raw is int or raw is float):
				return null
			return StoryFlowVariant.from_int(int(raw))
		StoryFlowTypes.VariableType.FLOAT:
			if not (raw is int or raw is float):
				return null
			return StoryFlowVariant.from_float(float(raw))
		StoryFlowTypes.VariableType.ENUM:
			if not raw is String:
				return null
			return StoryFlowVariant.from_enum(raw)
		StoryFlowTypes.VariableType.STRING, \
		StoryFlowTypes.VariableType.IMAGE, \
		StoryFlowTypes.VariableType.AUDIO, \
		StoryFlowTypes.VariableType.CHARACTER:
			if not raw is String:
				return null
			return StoryFlowVariant.from_string(raw)
		_:
			return null


## Map entries from the exported ordered array of {key, value} objects, as an insertion-ordered
## Dictionary of coerced key -> StoryFlowVariant. Entry ORDER is contractual (section 2.1) and
## Godot Dictionaries preserve insertion order.
##
## Keys are raw values coerced from the declared keyType — never strings-table keys — matching
## [code]StoryFlowImporter._coerce_map_key[/code]. An entry whose value does not fit the
## declared valueType keeps its key with the type default rather than vanishing: a missing KEY
## makes an entry unaddressable, a bad value does not.
static func _type_map_entries(declaration: Dictionary, raw: Array) -> Dictionary:
	var key_type: StoryFlowTypes.VariableType = declaration.get("key_type", StoryFlowTypes.VariableType.NONE)
	var value_type: StoryFlowTypes.VariableType = declaration.get("value_type", StoryFlowTypes.VariableType.NONE)
	var entries: Dictionary = {}
	for entry_obj in raw:
		if not entry_obj is Dictionary:
			continue
		if not entry_obj.has("key") or entry_obj["key"] == null:
			continue
		var key = int(entry_obj["key"]) if key_type == StoryFlowTypes.VariableType.INTEGER else str(entry_obj["key"])
		var value := _type_scalar(value_type, entry_obj.get("value"))
		if value == null:
			value = _scalar_default(value_type)
		entries[key] = value
	return entries


# =============================================================================
# The chain walk
# =============================================================================

## THE chain walk, leaf -> root, shared by every function in this file so none of them can
## disagree about chain order, the depth cap or the cycle guard. Calls [param visit] per level
## and stops early when it returns [code]false[/code].
##
## Mirrors runtime-data-assets.js's `depth++ <= MAX_DEPTH` boundary exactly: the counter is
## tested BEFORE it is incremented, so MAX_CHAIN_DEPTH ancestors plus the starting level — 65
## levels — are visited. An absent parent, a cycle, or the cap ends the walk SILENTLY, and
## callers answer with whatever they collected so far (contract section 4.4).
static func _walk_chain(seed: Dictionary, asset_id: String, visit: Callable) -> void:
	if asset_id.is_empty():
		return
	var level = seed.get(asset_id, null)
	var visited: Dictionary = {}
	var depth := 0
	while level is Dictionary:
		if depth > MAX_CHAIN_DEPTH:
			return
		depth += 1
		var level_id: String = str(level.get("id", ""))
		if visited.has(level_id):
			return
		visited[level_id] = true
		if not visit.call(level):
			return
		var parent: String = str(level.get("parent", ""))
		if parent.is_empty():
			return
		level = seed.get(parent, null)


## The declaration of [param variable_id] on ONE level, or an empty Dictionary.
static func _find_declared_on_level(level: Dictionary, variable_id: String) -> Dictionary:
	var variables = level.get("variables", [])
	if not variables is Array:
		return {}
	for declaration in variables:
		if declaration is Dictionary and str(declaration.get("id", "")) == variable_id:
			return declaration
	return {}


## The first declaration NAMED [param name] on ONE level, or an empty Dictionary.
##
## FIRST DECLARED WINS within a level, which only matters because names, unlike ids, are not
## unique by construction: the editor keeps them unique per asset, but nothing in the seed
## format enforces it. Between LEVELS the root-most declaration still wins — that rule lives
## in the walk, not here.
static func _find_declared_on_level_by_name(level: Dictionary, name: String) -> Dictionary:
	var variables = level.get("variables", [])
	if not variables is Array:
		return {}
	for declaration in variables:
		if declaration is Dictionary and str(declaration.get("name", "")) == name:
			return declaration
	return {}


# =============================================================================
# Reads
# =============================================================================

## Is [param asset_id] carried by the seed at all?
##
## Tells a DEAD REFERENCE (a pill pointing at an asset this build does not carry) apart from a
## STALE BINDING (the asset is here, the variable is not), which [method find_declaration]
## alone cannot — the two have different fixes, and the degraded ladder names them separately.
static func has_asset(seed: Dictionary, asset_id: String) -> bool:
	return not asset_id.is_empty() and seed.has(asset_id)


## The declaration [param variable_id] resolves to on the asset's chain, or an empty Dictionary
## when the asset is unknown or no level declares the id.
##
## ROOT-MOST declaration wins (contract section 4.3): a descendant re-declaring an inherited id
## does not shadow the ancestor's definition, which is why a hit must NOT stop the walk.
## Returned BY REFERENCE into the seed — read it, never write through it.
static func find_declaration(seed: Dictionary, asset_id: String, variable_id: String) -> Dictionary:
	if variable_id.is_empty():
		return {}
	# GDScript lambdas capture locals BY VALUE and cannot assign back to them, so the
	# accumulator is a Dictionary: captured by value, but pointing at the same storage.
	var acc := {"declaration": {}}
	var visit := func(level: Dictionary) -> bool:
		var declaration := _find_declared_on_level(level, variable_id)
		if not declaration.is_empty():
			acc["declaration"] = declaration
		return true
	_walk_chain(seed, asset_id, visit)
	return acc["declaration"]


## [method find_declaration]'s twin for the host API, matching on the display NAME instead of
## the id, with the same root-most-wins rule.
##
## Two lookups exist because two audiences do: everything the exporter emits is keyed by id
## (ids survive a rename), while a game programmer holds the name they typed in the editor.
##
## SILENT on collisions, deliberately, matching the sibling ports: the SAME NAME on two
## different ids across levels leaves the descendant's variable unreachable by name — one rule,
## no special case, and a name lookup with two right answers has no better one. This is a
## per-call path (the host accessors run it on every access, which a game can do per frame), so
## a diagnostic here would be an unlatched log in a hot loop; duplicate-name diagnostics belong
## to the public API, which can decide once when a caller binds a name.
static func find_declaration_by_name(seed: Dictionary, asset_id: String, name: String) -> Dictionary:
	if name.is_empty():
		return {}
	var acc := {"declaration": {}}
	var visit := func(level: Dictionary) -> bool:
		var declaration := _find_declared_on_level_by_name(level, name)
		if not declaration.is_empty():
			acc["declaration"] = declaration
		return true
	_walk_chain(seed, asset_id, visit)
	return acc["declaration"]


## True when any level of the asset's chain declares the id (what a write validates against).
## Unlike [method find_declaration] this stops at the FIRST hit — any declaration answers the
## question, and root-most-ness does not matter to a yes/no.
static func is_declared_on_chain(seed: Dictionary, asset_id: String, variable_id: String) -> bool:
	if variable_id.is_empty():
		return false
	var acc := {"declared": false}
	var visit := func(level: Dictionary) -> bool:
		if _find_declared_on_level(level, variable_id).is_empty():
			return true
		acc["declared"] = true
		return false
	_walk_chain(seed, asset_id, visit)
	return acc["declared"]


## Effective value of [param variable_id] as seen by [param asset_id] (contract section 4), or
## [code]null[/code] for an unknown asset or an id nothing on the chain declares.
##
## Walks leaf -> root taking, per level and IN ORDER, the overlay entry, else that level's own
## override; first hit wins, so an ancestor's entry cascades to every descendant that does not
## shadow it. A level whose overlay table exists but lacks the key falls through to that same
## level's override. With no such hit the ROOT-MOST declaration's own value answers.
##
## COPY-ON-READ (contract section 3): the value is duplicated out, so graph code cannot mutate
## the seed or the overlay through a read.
static func try_resolve(seed: Dictionary, overlay: Dictionary, asset_id: String, variable_id: String) -> StoryFlowVariant:
	var found := _walk_for_value(seed, overlay, asset_id, variable_id)
	if not found["found"]:
		return null
	if found["has_nearest"]:
		var nearest: StoryFlowVariant = found["nearest"]
		return nearest.duplicate_variant()
	var declaration: Dictionary = found["declaration"]
	var declared_value = declaration.get("value", null)
	if declared_value is StoryFlowVariant:
		return declared_value.duplicate_variant()
	return type_default(declaration)


## resolveEntry's ONE walk, with its two accumulators kept apart on purpose:
##  - "nearest": the FIRST overlay-or-override hit leaf -> root (section 4.1 / 4.2).
##  - "declaration": the ROOT-MOST DECLARATION (section 4.3), which is why a declaration must
##    NOT stop the walk.
## Returning early on an override would resurrect ORPHAN overrides on other levels; an override
## counts only where the chain still declares the id, and the declaration that proves it may be
## further up than the override is.
##
## "found" is its OWN FLAG, not "the value came back non-null": "did any level declare this id?"
## and "does that declaration carry a value?" are different questions, and section 4.3 asks only
## the first. Keying success on the value reports a VALUELESS declaration as undeclared — the
## same answer a deleted variable gets — so an accessor would take the degraded path instead of
## reading its type default.
##
## An EMPTY overlay skips the session lookups entirely — that is the write path, which needs
## the declaration and nothing else.
static func _walk_for_value(seed: Dictionary, overlay: Dictionary, asset_id: String, variable_id: String) -> Dictionary:
	var acc := {"has_nearest": false, "nearest": null, "found": false, "declaration": {}}
	if variable_id.is_empty():
		return acc

	var visit := func(level: Dictionary) -> bool:
		if not acc["has_nearest"]:
			var level_id: String = str(level.get("id", ""))
			var level_overlay = overlay.get(level_id, null)
			if level_overlay is Dictionary and level_overlay.has(variable_id):
				acc["nearest"] = level_overlay[variable_id]
				acc["has_nearest"] = true
			else:
				var overrides = level.get("overrides", {})
				if overrides is Dictionary and overrides.has(variable_id):
					acc["nearest"] = overrides[variable_id]
					acc["has_nearest"] = true
		var declaration := _find_declared_on_level(level, variable_id)
		if not declaration.is_empty():
			acc["declaration"] = declaration
			acc["found"] = true
		return true
	_walk_chain(seed, asset_id, visit)
	return acc


# =============================================================================
# Writes
# =============================================================================

## Record a session write in the overlay (contract section 5), reporting whether it landed.
##
## Writes go to THE REFERENCED ASSET'S OWN LEVEL, always — never to the declaring ancestor:
## setting via a child overrides for that child's subtree, setting via the base cascades to
## every descendant that does not shadow it. There is no "write to base" switch.
##
## Refuses an unknown asset or an id no chain level declares. Both guards run BEFORE the
## per-asset table is minted, so a refused write leaves no empty table behind to ride every
## later save. The two are NOT redundant despite answering the same way for an absent asset:
## they ask different questions ("is this asset here at all?" vs "does its chain declare this
## id?"), which is the line the degraded ladder draws between a dead reference and a stale
## binding.
##
## DEEP-COPY-ON-WRITE: the value is duplicated in, so a caller mutating its own container
## afterwards cannot reach into the store. A map write REPLACES the whole value.
##
## The CALLER owns the warning: the node arms have a per-node warn latch (contract section 6)
## and the host API does not, so this reports the refusal rather than logging it.
static func try_set(seed: Dictionary, overlay: Dictionary, asset_id: String, variable_id: String, value: StoryFlowVariant) -> bool:
	if value == null:
		return false
	if not has_asset(seed, asset_id):
		return false
	if not is_declared_on_chain(seed, asset_id, variable_id):
		return false

	if not overlay.has(asset_id):
		overlay[asset_id] = {}
	var level_overlay: Dictionary = overlay[asset_id]
	level_overlay[variable_id] = value.duplicate_variant()
	return true


## Drop every session write (game restart / new game). Cleared IN PLACE — never rebound,
## because the manager hands this same dictionary to every running dialogue. The seed is
## untouched.
static func reset_overlay(overlay: Dictionary) -> void:
	overlay.clear()


# =============================================================================
# The snapshot match rule
# =============================================================================

## Does the seed's declaration still match the spawn-time snapshot an accessor node's pins were
## built from (contract section 6.1, mirroring runtime-data-assets.js's declMatches)?
##
## Stale is treated as MISSING — no silent coercion, ever, because within the string family a
## value carries no evidence of which type declared it, which is exactly why the check is on
## the DECLARATION rather than the value.
##
## Takes the snapshot as the WIRE STRINGS the exporter wrote onto the node, because that is
## what the node data holds. They convert through the ONE shared table
## ([method StoryFlowTypes.parse_variable_type], a Dictionary lookup and therefore exact and
## case-SENSITIVE per the contract's ordinal-lowercase rule), and a type string that table does
## not know parses to NONE and can never match — so a garbled or case-variant snapshot degrades
## instead of resolving.
##
## [param key_type] / [param value_type] are compared for MAPS ONLY; [param is_array] always,
## since an array pin and a scalar pin of the same type are different pins.
static func decl_matches(declaration: Dictionary, wire_type: String, is_array: bool, key_type: String, value_type: String) -> bool:
	if declaration.is_empty():
		return false

	var parsed_type := StoryFlowTypes.parse_variable_type(wire_type)
	if parsed_type == StoryFlowTypes.VariableType.NONE:
		return false
	if declaration.get("type", StoryFlowTypes.VariableType.NONE) != parsed_type:
		return false
	if bool(declaration.get("is_array", false)) != is_array:
		return false

	if parsed_type == StoryFlowTypes.VariableType.MAP:
		var parsed_key := StoryFlowTypes.parse_variable_type(key_type)
		if parsed_key == StoryFlowTypes.VariableType.NONE:
			return false
		if declaration.get("key_type", StoryFlowTypes.VariableType.NONE) != parsed_key:
			return false
		var parsed_value := StoryFlowTypes.parse_variable_type(value_type)
		if parsed_value == StoryFlowTypes.VariableType.NONE:
			return false
		if declaration.get("value_type", StoryFlowTypes.VariableType.NONE) != parsed_value:
			return false

	return true
