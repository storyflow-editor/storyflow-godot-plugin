class_name StoryFlowDataAssetStore
extends RefCounted

# Preloaded by path so parsing never depends on the global class name cache,
# which can be stale or mid-rewrite when the game launches (godotengine/godot#75388).
const StoryFlowLocalization = preload("res://addons/storyflow/core/storyflow_localization.gd")
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
## only way to reach seed storage. And it is not only SEED storage: [method build_seed] shares
## each level's declaration ARRAY by reference with the project's own data_assets table, so a
## caller writing through a declaration corrupts the imported project too, and a game reset
## rebuilds the seed straight back onto the damage. Read declarations, never write to them.
##
## THE SEED STORES VERBATIM BYTES AND THE READ DOOR LOCALIZES, and the REASON changed with
## localization spec §2's amendment of 2026-08-27, which SUPERSEDES engine-contract 2.1's
## literal-value posture: data-assets.json now DOES carry a strings table, and a Data Asset's
## DECLARED string value is a table key like any other artifact's (the importer merges that table
## into the project globals characters.json already feeds). It is still not resolved on the way
## IN, because a bake would freeze the text in whatever language happened to be current at import
## and would destroy the one thing the gate needs - the difference between a value that came from
## the seed and one a script wrote. Resolution happens at [method try_read] / [method read_bound]
## instead.
##
## FOUR DOORS OUT, one walk behind all of them:
##  - [method try_read]   the value with the LOCALIZATION GATE applied: the door every surface
##    that hands a .sfd value to GAME CODE goes through (both host accessors).
##  - [method try_resolve] the CHAIN RULE ALONE, with no string lookup anywhere in it: saves,
##    the fixture harnesses, and any caller that wants the bytes the store actually holds.
##  - [method read_bound]  [method try_read] plus the §6.1 ladder answer: what a bound accessor
##    NODE reads through, since a node's pins can be stale in a way an id cannot.
##  - [method check_bound] the ladder answer alone, no overlay and no copy-out: the write path.
## [method try_read] and [method read_bound] share ONE gate ([method _read_out]) rather than
## carrying a copy each: a rule that held on the host accessors and not at the node arms would be
## a bug no single-surface test could see.

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

## What ONE chain walk found for a bound accessor: either a usable value, or which CHAIN-SIDE
## rung of the degraded ladder (contract section 6) the binding fell off.
##
## Only the two rungs the walk itself can answer are here. The other three ladder reasons —
## no variableId on the node, no pill wired to its dataAsset pin, and an assetId the seed does
## not carry — are GRAPH-side questions the caller settles before there is a chain to walk
## (the last one via [method has_asset], which is what draws the dead-reference line). An
## unknown asset reaching [method read_bound] anyway answers MISSING, because a walk that
## visits no level declares nothing.
enum Binding {
	## The chain declares the id and the declaration still matches the spawn snapshot.
	OK,
	## No level of the chain declares the id.
	MISSING,
	## Declared, but the declaration no longer matches the spawn snapshot (section 6.1).
	CHANGED,
}


## WHAT ANSWERED a resolve - the PROVENANCE of the value, which the localization gate reads and
## nothing else does. THE VOCABULARY LIVES HERE AND ONLY HERE: the gate names these constants, and
## never a string or a bare bool, because "is this a declaration" is a three-way question whose
## two negative answers have different reasons.
##
## THREE VALUES AND NOT TWO. Both an ancestor's DECLARATION and an ancestor's OVERRIDE look simply
## inherited from a descendant, and the reference implementation learned what folding them costs:
## its origin token had one `inherited` value, so its accessor door served the ancestor's
## translation for a text the descendant had deliberately replaced (fixed editor-side at
## b18c4de0). That failure is not a missing translation - it is a WRONG VALUE, and it is invisible
## in the source language.
##
## Recorded WHERE THE WALK ALREADY KNOWS ([method _walk_for_value]'s own branch) and never
## re-derived afterwards: once an overlay entry and an override are both just a StoryFlowVariant
## reference, nothing downstream can tell them apart.
enum Origin {
	## The root-most declaration's own authored value (section 4.3). The ONLY tier that localizes.
	DECLARATION,
	## An `overrides` entry at some chain level. Authored, but NOT keyed - see [method _read_out].
	OVERRIDE,
	## An overlay entry: a write this session made. Live data, never content.
	SESSION_WRITE,
}


## THE RESOLUTION BUNDLE'S KEYS, and the ONLY sanctioned way to address it - here, at any door,
## and at the fifth door that does not exist yet.
##
## GDScript has no typed record, so [method _walk_for_value]'s answer travels as a Dictionary, and
## a misspelled Dictionary key FAILS SILENTLY IN THE ONE DIRECTION THAT MATTERS: `found["orgin"]`
## evaluates to null, `null == Origin.DECLARATION` is false, and the gate quietly declines to
## localize - the invisible failure class this whole feature exists to prevent, arriving through
## its own front door. An undefined IDENTIFIER fails the PARSER, so addressing the bundle through
## these constants turns that typo into "the plugin does not load" instead of "nobody notices for
## months".
const KEY_HAS_NEAREST := "has_nearest"
const KEY_NEAREST := "nearest"
const KEY_FOUND := "found"
const KEY_DECLARATION := "declaration"
const KEY_ORIGIN := "origin"

## The BOUND wrapper's key holding a whole resolution ([method _bind]'s answer). It spells the
## same word as [constant KEY_FOUND] and means something different - that one is the bundle's own
## "did any level declare this id" FLAG - so the two are named apart even though a literal could
## not tell them apart.
const KEY_BOUND_RESOLUTION := "found"


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
## [code]StoryFlowImporter._coerce_map_key[/code]. An entry with NO KEY is unaddressable and is
## skipped; that part is not a choice.
##
## RECORDED DIVERGENCE, not parity: what happens to an entry whose VALUE does not fit the
## declared valueType is left ENGINE-DEFINED by the contract, and all four runtimes answer
## differently — the HTML reference keeps the raw value, Unreal shape-dispatches, Unity coerces,
## and Godot (here) KEEPS THE KEY with the declared type's default. Do not "fix" this toward
## another engine without changing the contract first; a shipped seed cannot reach it anyway,
## because the collector strips invalid overrides before export.
##
## Note the INTERNAL ASYMMETRY this creates, deliberately: a bad ARRAY element drops the whole
## array ([method type_value] returns null and the override is refused), while a bad MAP ENTRY
## VALUE keeps its key with a default. An array is one value whose shape either fits or does
## not; a map is a keyed collection where one bad entry should not cost the caller the other
## twenty keys it can still address.
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


## The NAMES of every variable the asset's chain DECLARES — the Get Variable Names node's whole
## answer (engine contract 11.1), mirroring the reference implementation's `variableNames` over
## its `eachDeclaration` walk. Derived from THE SAME [method _walk_chain] every resolver door
## uses — never a second walk that could disagree with what an accessor then resolves.
##
## ORDER is the editor's: chain ROOT-first, each level's variables in file order.
## [method _walk_chain] visits LEAF -> ROOT, so the collected levels are iterated BACKWARDS
## below — the arrangement IS the mechanism: both claim dictionaries are plain FIRST-WINS, and
## only that reversal makes "first" mean ROOT-MOST — for ids the slot that survives, for names
## the position that does. Reverse the loop and the length and the names stay right while
## PRECEDENCE silently flips to leaf-most, which no size or membership assert can see.
##
## FIRST-WINS on the id: a descendant re-declaring an inherited id adds nothing, the same rule
## [method find_declaration] follows by letting a later (root-er) hit overwrite an earlier one.
##
## DEDUPED BY NAME on top of the dedupe by id: two levels can declare the same display NAME
## under different ids (nothing in the seed forbids it), and a by-name getter can only ever
## reach one of them — [method find_declaration_by_name]'s root-most one — so the list states
## it once, at the root-most position. Empty names are skipped, never listed as blanks.
##
## DECLARATIONS ONLY. `overrides` are never visited: an override re-states a value for a
## variable the chain already declares, so it can neither add a name nor duplicate one. The
## case that PROVES the rule is an ORPHAN override (an id nothing on the chain declares):
## [method build_seed] drops those at import, but the seed is a plain Dictionary any caller can
## assemble, and this walk must not depend on a repair that happens somewhere else.
##
## The reference's categories-claim-their-slot rule has nothing to claim here: the importer
## drops `category` rows before the seed exists (see _parse_data_asset_variable's contract
## sanction), so this engine's resolver never sees one — and the list agrees with the resolver,
## which is the point. The consequence is real but pre-existing and sanctioned: a descendant
## re-declaring an ancestor category's id WOULD list (and resolve) here where the editor hides
## it behind the claimed slot — the same divergence the accessors already carry.
##
## EVERY degraded path answers an EMPTY list: an empty or unknown asset id walks no levels, and
## an empty seed (a context never handed a store) is just the unknown-asset case.
static func variable_names(seed: Dictionary, asset_id: String) -> Array[String]:
	var levels: Array = []
	var collect := func(level: Dictionary) -> bool:
		levels.append(level)
		return true
	_walk_chain(seed, asset_id, collect)

	var names: Array[String] = []
	var claimed_ids: Dictionary = {}
	var claimed_names: Dictionary = {}
	for i in range(levels.size() - 1, -1, -1):
		var variables = levels[i].get("variables", [])
		if not variables is Array:
			continue
		for declaration in variables:
			if not declaration is Dictionary:
				continue
			# str() here, beside the deliberately-uncoerced name below: the id is a claim
			# KEY only, never listed - coercion is safe where nothing reaches the output.
			var declaration_id := str(declaration.get("id", ""))
			if claimed_ids.has(declaration_id):
				continue
			claimed_ids[declaration_id] = true
			# Type-checked, not str()-coerced: the importer stores names as Strings, and
			# str() on an arbitrary hand-assembled value is exactly the 4.6.1 divergence
			# class the parity notes warn about. DELIBERATELY STRICTER than the reference,
			# not just safer: its variableNames does String(decl.name) and would list a
			# coerced "42" where this lists nothing - unreachable through the real pipeline
			# in both engines (the schema types names as strings), so not a parity bug.
			var name = declaration.get("name", "")
			if not name is String or name.is_empty() or claimed_names.has(name):
				continue
			claimed_names[name] = true
			names.append(name)
	return names


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
##
## THIS IS THE CHAIN RULE AND NOTHING MORE: no string-table lookup anywhere in it. Game-facing
## reads go through [method try_read], which layers the localization gate on top. Saves and the
## fixture harnesses want THIS one - a persisted overlay entry must be the bytes the game wrote,
## and a golden fixture pins the store's own answer, not the current language's.
static func try_resolve(seed: Dictionary, overlay: Dictionary, asset_id: String, variable_id: String) -> StoryFlowVariant:
	var found := _walk_for_value(seed, overlay, asset_id, variable_id)
	if not found[KEY_FOUND]:
		return null
	return _copy_out(found)


## THE READ DOOR: [method try_resolve] plus the localization gate, and the function every surface
## that hands a .sfd value to GAME CODE calls. The host accessors call it directly; the node arms
## reach the same gate through [method read_bound], which needs the section 6.1 ladder answer too.
##
## [param locale] is StoryFlowLocalization.reading_locale's bundle; an EMPTY Dictionary means
## "nothing to look anything up in" and every value passes through verbatim, which is what a
## hand-built store in a test wants.
##
## Localization spec §2's amendment of 2026-08-27 - which SUPERSEDES engine-contract 2.1's "a .sfd
## value is a literal, never look it up" - makes a Data Asset's DECLARED string values
## player-facing prose, shipped as stable table keys in data-assets.json's own strings block and
## resolved through the very ladder every other artifact's strings already use.
##
## WHAT LOCALIZES, and the three rules re-derivable wrongly (the vendored package's
## manifest.localization.dataAssets spells all of them out):
##
##  - ONLY A DECLARATION. [constant Origin.OVERRIDE] and [constant Origin.SESSION_WRITE] are
##    handed back verbatim. An override is AUTHORED but UNKEYED: a .sfd id carries no per-asset
##    segment, so a declaration and a descendant's override of it would collide on one
##    `<variableId>.value`, and the exporter therefore keys declarations only. Localizing an
##    override does not MISS - it serves the ANCESTOR's translation for a text the descendant
##    deliberately replaced.
##  - A WRITTEN VALUE NEVER LOCALIZES, including after a save/load, because the save carries the
##    overlay and a restored write was never content. The gate is WHERE THE VALUE CAME FROM and
##    never whether it LOOKS like a key: a write that happened to equal a key would otherwise be
##    translated into a string the game has since redefined, and that failure is invisible in the
##    source language.
##  - STRING-TYPED PROSE ONLY, decided by the DECLARED type - see [method _localize_declared].
##
## THE ID IS BUILT FROM THE VARIABLE ALONE (`<variableId>.value`, `.value.<index>`,
## `.value.<mapKey>`) and it is THE EXPORTER that built it; nothing here re-derives one, this
## resolves the bytes the seed carries. That is the deliberate CONTRAST with a character value's
## `<characterId>.<variableId>.value`, and the reason every level of a chain may carry keyed
## strings: it is the VARIABLE that is unique, not the asset.
##
## RESOLUTION IS AT THIS DOOR, never baked, so a mid-session set_language lands on the very next
## .sfd read - the same read-time posture this engine already has for every other string it holds
## (StoryFlowManager.set_language's "what moves, and when").
static func try_read(seed: Dictionary, overlay: Dictionary, locale: Dictionary, asset_id: String, variable_id: String) -> StoryFlowVariant:
	var found := _walk_for_value(seed, overlay, asset_id, variable_id)
	if not found[KEY_FOUND]:
		return null
	return _read_out(found, locale)


## ONE WALK for a bound accessor's read: resolve the value AND settle which chain-side rung
## (if any) the binding is on. Answers { "status": Binding, "value": StoryFlowVariant or null },
## with a value only on [constant Binding.OK].
##
## The pair this replaces — [method find_declaration] for the ladder, then [method try_resolve]
## for the value — walked the same chain TWICE on every read, and option conditions re-resolve
## on every render. Splitting them also let the two disagree in principle (decl_matches checked
## against one walk's declaration, the value taken from another's), which is a class of bug
## this shape cannot have.
##
## The DECLARATION deliberately does not come back out. Past an OK result the caller's own
## snapshot ([param wire_type] / [param is_array] / [param key_type] / [param value_type]) IS
## the chain's declared shape, so it already holds everything a declaration would tell it — and
## a declaration is a live reference into seed AND project storage (see this class's header).
##
## [method try_resolve] stays as the NO-SNAPSHOT variant rather than routing through here: the
## host API and any caller holding an id it trusts have no pins to check, and would have to
## invent a snapshot just to be told it matches. Both share the one walk and the one
## [method _copy_out], so there is nothing left for them to disagree about.
## UNKNOWN ASSET ANSWERS MISSING, not a dead reference: a walk that visits no level declares
## nothing, and this function has no way to tell "asset deleted" from "variable deleted" apart.
## The DEAD-REFERENCE rung is the caller's, drawn with [method has_asset] BEFORE calling here —
## and an empty store (a reset execution context hands out `{}`) lands on that same rung, so the
## ladder's deadref check fires before read_bound is ever reached.
##
## THE LOCALIZATION GATE RUNS HERE TOO, through the same [method _read_out] the host door uses:
## this is a GAME-FACING read, and a rule that held on one surface and not the other is a bug no
## single-surface test could see. [param locale] is StoryFlowLocalization.reading_locale's bundle.
static func read_bound(seed: Dictionary, overlay: Dictionary, locale: Dictionary, asset_id: String, variable_id: String, wire_type: String, is_array: bool, key_type: String, value_type: String) -> Dictionary:
	var bound := _bind(seed, overlay, asset_id, variable_id, wire_type, is_array, key_type, value_type)
	if bound["status"] != Binding.OK:
		return {"status": bound["status"], "value": null}
	return {"status": Binding.OK, "value": _read_out(bound[KEY_BOUND_RESOLUTION], locale)}


## [method read_bound] taking the accessor's four spawn-snapshot pins as ONE Dictionary
## — `{ "wire_type", "is_array", "key_type", "value_type" }` — instead of four positional
## arguments in a row, which read as an unlabelled soup at every call site and let a
## key/value swap through silently. The node arms build the snapshot once per access with
## [method StoryFlowEvaluator.data_asset_pins] and pass it around.
static func read_bound_with_pins(seed: Dictionary, overlay: Dictionary, locale: Dictionary, asset_id: String, variable_id: String, pins: Dictionary) -> Dictionary:
	return read_bound(seed, overlay, locale, asset_id, variable_id, \
		str(pins.get("wire_type", "")), bool(pins.get("is_array", false)), \
		str(pins.get("key_type", "")), str(pins.get("value_type", "")))


## [method read_bound_with_pins]'s WRITE-side twin: the same one walk and the same rungs in
## the same order, but no value handed out.
##
## A Set node asks "is this binding still live?", never "what does it hold?" — the value it is
## about to overwrite is of no interest to it, and reading one would deep-copy the current
## array or map entry list just to drop it. Sharing [method _bind] is what keeps this honest:
## the MISSING / CHANGED decision is made in exactly one place, so a Set can never accept a
## binding its Get twin degrades (or the reverse), which is the failure the contract's
## one-ladder-for-both rule exists to prevent.
static func check_bound(seed: Dictionary, overlay: Dictionary, asset_id: String, variable_id: String, pins: Dictionary) -> Binding:
	var bound := _bind(seed, overlay, asset_id, variable_id, \
		str(pins.get("wire_type", "")), bool(pins.get("is_array", false)), \
		str(pins.get("key_type", "")), str(pins.get("value_type", "")))
	return bound["status"]


## THE rung decision behind [method read_bound] and [method check_bound]: one chain walk, then
## the section 6.1 snapshot match. Answers { "status": Binding, [constant KEY_BOUND_RESOLUTION]:
## the whole resolution }.
static func _bind(seed: Dictionary, overlay: Dictionary, asset_id: String, variable_id: String, wire_type: String, is_array: bool, key_type: String, value_type: String) -> Dictionary:
	var found := _walk_for_value(seed, overlay, asset_id, variable_id)
	if not found[KEY_FOUND]:
		return {"status": Binding.MISSING, KEY_BOUND_RESOLUTION: found}
	# Section 6.1: the declaration moved under a live node. Treated as MISSING by every caller,
	# never coerced — within the string family a value carries no evidence of its declared
	# type, which is exactly why the check is on the DECLARATION.
	if not decl_matches(found[KEY_DECLARATION], wire_type, is_array, key_type, value_type):
		return {"status": Binding.CHANGED, KEY_BOUND_RESOLUTION: found}
	return {"status": Binding.OK, KEY_BOUND_RESOLUTION: found}


## The value a completed walk hands OUT: the nearest overlay-or-override hit, else the
## root-most declaration's own value, ALWAYS duplicated (contract section 3).
##
## A declaration carrying no value at all copies out as its TYPE DEFAULT rather than as
## nothing. Nothing [method build_seed] produces has that shape — the importer stamps a default
## — but the seed is a plain Dictionary any caller can assemble, and this walk should not
## depend on a repair that happens somewhere else.
static func _copy_out(found: Dictionary) -> StoryFlowVariant:
	if found[KEY_HAS_NEAREST]:
		var nearest: StoryFlowVariant = found[KEY_NEAREST]
		return nearest.duplicate_variant()
	var declaration: Dictionary = found[KEY_DECLARATION]
	var declared_value = declaration.get("value", null)
	if declared_value is StoryFlowVariant:
		return declared_value.duplicate_variant()
	return type_default(declaration)


## THE ONE LOCALIZATION GATE this plugin has for .sfd values, and the tail of every game-facing
## read: [method _copy_out] plus the decision of whether the value is CONTENT. [method try_read]
## (the host accessors) and [method read_bound] (the node arms and the degraded ladder) both end
## here, so the rule cannot hold at one surface and not the other.
##
## IT SITS BESIDE THE SHARED STRING LADDER, NOT INSIDE IT. StoryFlowLocalization.look_up is one
## ladder with three delegating doors and no .sfd knowledge; folding a value-provenance question
## into it would put a .sfd-only concern in every dialogue lookup. This is the second shared
## function, it gates on PROVENANCE, and it calls that ladder for the string tier alone.
##
## GATED ON PROVENANCE, NEVER ON THE VALUE'S SHAPE. Every rule behind that sentence is written out
## on [method try_read]; this is only where it is enforced. An empty [param locale] is "no project
## to look anything up in" - a hand-built store in a test - and passes everything through.
static func _read_out(found: Dictionary, locale: Dictionary) -> StoryFlowVariant:
	var value := _copy_out(found)
	if found[KEY_ORIGIN] == Origin.DECLARATION and not locale.is_empty():
		_localize_declared(found[KEY_DECLARATION], locale, value)
	return value


## A DECLARED value with its string-table keys resolved, IN PLACE on the copy the read is about
## to hand out.
##
## THE TYPE GATE IS THE EXPORTER'S, transcribed (json-export-strategy.ts's keying pass): a string
## SCALAR, the ELEMENTS of a string array, and the VALUES of a map whose valueType is string.
## Everything else - enum, image, audio, character, and every number and boolean - passes through
## untouched even when its value is a string, and a map's KEYS are identifiers that never resolve
## whatever their keyType is. A gate that drifted from the exporter's would look up an id nothing
## keyed, or hand back a key.
##
## The IMAGE / AUDIO / CHARACTER types are the reason this reads `declaration["type"]` and not the
## variant's tag: [method storage_type] flattens all three to STRING storage, so by the time a
## value exists there is nothing left to tell them apart from prose - which is the same reason the
## section 6.1 snapshot check is on the declaration.
##
## "an absent valueType is a string map" arrives here ALREADY SETTLED: the importer defaults both
## map sides to "string" (_parse_data_asset_variable), so a missing token never reaches this test
## as NONE.
static func _localize_declared(declaration: Dictionary, locale: Dictionary, value: StoryFlowVariant) -> void:
	var declared_type: StoryFlowTypes.VariableType = declaration.get("type", StoryFlowTypes.VariableType.NONE)

	if declared_type == StoryFlowTypes.VariableType.MAP:
		if declaration.get("value_type", StoryFlowTypes.VariableType.NONE) != StoryFlowTypes.VariableType.STRING:
			return
		var entries: Dictionary = value.get_map()
		for key in entries:
			_localize_string(locale, entries[key])
		return

	if declared_type != StoryFlowTypes.VariableType.STRING:
		return

	if bool(declaration.get("is_array", false)):
		for element in value.get_array():
			_localize_string(locale, element)
		return

	_localize_string(locale, value)


## One string through the shared ladder, left alone when it is not prose.
##
## NO CURRENT SCRIPT IS PASSED, deliberately: a .sfd id is keyed by data-assets.json, which the
## importer merges into the PROJECT globals, so handing the ladder a script could only let a
## script's own table shadow a .sfd id - and which script happens to be running would then decide
## what an item is called. Reusing StoryFlowLocalization.look_up rather than reaching into
## global_strings directly is what keeps the overlay tier and the source-language fall-through
## identical here to everywhere else; a second, simpler lookup would be the fourth ladder and
## would drift.
##
## PROSE means non-blank AFTER TRIMMING, exactly as the editor's keying pass decides it: a
## whitespace-only value keys nothing there, so looking one up here would probe an id no
## translator can reach. A miss answers null and the value is left as it is, which is the raw
## fallback tier and is why an unkeyed literal survives this untouched.
static func _localize_string(locale: Dictionary, value) -> void:
	if not value is StoryFlowVariant:
		return
	var key: String = value.get_string("")
	if key.strip_edges().is_empty():
		return
	var resolved = StoryFlowLocalization.look_up(
		locale.get("localization"), null, locale.get("global_strings", {}),
		key, str(locale.get("fallback_language", "")))
	if resolved != null:
		value.set_string(str(resolved))


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
##
## THE THREE ANSWERS TRAVEL AS ONE RESOLUTION Dictionary and every consumer takes it WHOLE
## ([method _copy_out] and [method _read_out] both do), rather than as values a later door could
## re-assemble from a different walk: an [enum Origin] paired with somebody else's declaration is
## exactly the mis-gate the enum exists to prevent, and GDScript has no type that would catch it.
##  - [constant KEY_HAS_NEAREST] / [constant KEY_NEAREST]: the FIRST overlay-or-override hit,
##    leaf -> root.
##  - [constant KEY_FOUND] / [constant KEY_DECLARATION]: whether any level declared the id, and
##    the ROOT-MOST declaration.
##  - [constant KEY_ORIGIN]: WHICH tier the nearest hit came from, recorded at the branch that
##    already knows. DECLARATION when there is no nearest hit at all, which is the one tier the
##    localization gate treats as content.
##
## ADDRESS IT THROUGH THOSE CONSTANTS AND NEVER THROUGH A STRING LITERAL - at every door here and
## at the fifth door that does not exist yet, which is where the typo lands. The constants' own
## doc says what a misspelled literal costs, and it is not a crash.
static func _walk_for_value(seed: Dictionary, overlay: Dictionary, asset_id: String, variable_id: String) -> Dictionary:
	var acc := {KEY_HAS_NEAREST: false, KEY_NEAREST: null, KEY_FOUND: false, KEY_DECLARATION: {}, KEY_ORIGIN: Origin.DECLARATION}
	if variable_id.is_empty():
		return acc

	var visit := func(level: Dictionary) -> bool:
		if not acc[KEY_HAS_NEAREST]:
			var level_id: String = str(level.get("id", ""))
			var level_overlay = overlay.get(level_id, null)
			if level_overlay is Dictionary and level_overlay.has(variable_id):
				acc[KEY_NEAREST] = level_overlay[variable_id]
				acc[KEY_HAS_NEAREST] = true
				acc[KEY_ORIGIN] = Origin.SESSION_WRITE
			else:
				var overrides = level.get("overrides", {})
				if overrides is Dictionary and overrides.has(variable_id):
					acc[KEY_NEAREST] = overrides[variable_id]
					acc[KEY_HAS_NEAREST] = true
					acc[KEY_ORIGIN] = Origin.OVERRIDE
		var declaration := _find_declared_on_level(level, variable_id)
		if not declaration.is_empty():
			acc[KEY_DECLARATION] = declaration
			acc[KEY_FOUND] = true
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
##
## THE CALLER ALSO OWNS CACHE INVALIDATION. A successful write here invalidates NOTHING — this
## file knows about a seed and an overlay and has never heard of an evaluator. Node-graph
## writers clear through the component (see _handle_set_data_asset_var's rationale for why the
## accessor's own memo carve-out is not enough: a memoized boolean PARENT above an accessor
## keeps answering the pre-write value). ANY NEW CALLER — the host accessors, a save load — must
## do the same, or option conditions go stale for the rest of the session.
static func try_set(seed: Dictionary, overlay: Dictionary, asset_id: String, variable_id: String, value: StoryFlowVariant, revision: Array = []) -> bool:
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
	if not revision.is_empty():
		revision[0] += 1
	return true


## Drop every session write (game restart / new game). Cleared IN PLACE — never rebound,
## because the manager hands this same dictionary to every running dialogue. The seed is
## untouched.
static func reset_overlay(overlay: Dictionary, revision: Array = []) -> void:
	overlay.clear()
	if not revision.is_empty():
		revision[0] += 1


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
