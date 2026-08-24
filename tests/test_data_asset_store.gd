extends SceneTree
## Headless tests for the .sfd Data Asset seed store and chain resolver
## (StoryFlowDataAssetStore) plus the importer parse path that feeds it.
##
## FIXTURES: tests/fixtures/engine-contract/data-assets-{seed,resolution,writes}.json are the
## SHARED CROSS-ENGINE goldens, copied verbatim from the editor repo. They are GENERATED from
## the HTML runtime by src/__tests__/runtime/engine-contract-fixtures.test.ts (regenerate with
## REGEN_FIXTURES=1) — never hand-edit them here, and re-copy rather than patch when they move.
## The same four files live in the Unreal and Unity plugin repos; byte drift between the copies
## is the parity failure they exist to prevent.
##
## Every fixture-driven loop is COUNT-GUARDED: a fixture that silently shrinks would otherwise
## turn into a test that silently passes.
##
## Run from the repository root (import first to build the class cache):
##   godot --headless --import
##   godot --headless --script res://tests/test_data_asset_store.gd
## Or: powershell -File tests/run_tests.ps1 -GodotExe <path-to-godot>

const ImporterScript := preload("res://addons/storyflow/editor/storyflow_importer.gd")
const ProjectScript := preload("res://addons/storyflow/core/storyflow_project.gd")
const StoreScript := preload("res://addons/storyflow/core/storyflow_data_asset_store.gd")
const TypesScript := preload("res://addons/storyflow/core/storyflow_types.gd")
const VariantScript := preload("res://addons/storyflow/core/storyflow_variant.gd")

const FIXTURE_DIR := "res://tests/fixtures/engine-contract"

const BASE := "da_0a1b2c3d4e5f60718293a4b5c6d7e8f9"
const CHILD := "da_1b2c3d4e5f60718293a4b5c6d7e8f90a"
const GRANDCHILD := "da_2c3d4e5f60718293a4b5c6d7e8f90a1b"
const V_TAGS := "c58e2f13a0d64c9b871e3f05d2a76b48"
const V_LOOT := "6d0f39a8b21e47c5903af8d61c72e504"
const V_HP := "2e8b6d0a1f4c47d3b95e2a70c6f81d34"

var _checks: int = 0
var _failures: int = 0

var _importer = null


func _initialize() -> void:
	await process_frame
	_importer = ImporterScript.new()

	_test_golden_resolution()
	_test_writes_replay()
	_test_overlay_guards()
	_test_chain_guards()
	_test_seed_build_drops_and_typing()
	_test_decl_matches()

	if _failures == 0:
		print("ALL %d CHECKS PASSED" % _checks)
	else:
		print("%d OF %d CHECKS FAILED" % [_failures, _checks])
	quit(1 if _failures > 0 else 0)


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  PASS: %s" % label)
	else:
		_failures += 1
		print("  FAIL: %s" % label)


# =============================================================================
# Golden resolution
# =============================================================================

## Every record in data-assets-resolution.json, resolved against a seed built through the REAL
## importer parse path with an EMPTY overlay. "resolved": false is the store's "no value"
## (unknown asset, an id no chain level declares, or a category declaration).
func _test_golden_resolution() -> void:
	print("-- golden resolution --")
	var seed := _seed_from_fixture()
	var overlay: Dictionary = {}
	var fixture := _load_fixture("data-assets-resolution.json")
	var records: Array = fixture.get("resolutions", [])

	_check("resolution fixture carries all 44 records (got %d)" % records.size(), records.size() == 44)
	_assert_resolution_table(seed, overlay, records, "seed")


# =============================================================================
# Writes replay
# =============================================================================

## The scripted write sequence from data-assets-writes.json, then the resolution table it
## leaves behind. The saveKey member is Task G3's — nothing here reads it.
func _test_writes_replay() -> void:
	print("-- writes replay --")
	var seed := _seed_from_fixture()
	var overlay: Dictionary = {}
	var fixture := _load_fixture("data-assets-writes.json")
	var writes: Array = fixture.get("writes", [])

	_check("writes fixture carries all 6 writes (got %d)" % writes.size(), writes.size() == 6)
	for entry in writes:
		var asset_id: String = entry.get("assetId", "")
		var variable_id: String = entry.get("variableId", "")
		# Typed from the JSON SHAPE, never from the declaration: typing against the
		# declaration would make the refused write fail for the wrong reason (no
		# declaration, therefore no value, therefore no write) instead of exercising
		# try_set's own chain guard.
		var value = _variant_from_json(entry.get("value"))
		var landed: bool = StoreScript.try_set(seed, overlay, asset_id, variable_id, value)
		var expected: bool = entry.get("expect", "") == "written"
		_check("write %s.%s is %s" % [asset_id, variable_id, entry.get("expect", "")], landed == expected)

	_check("a refused write leaves no empty per-asset table behind", overlay.size() == 3)

	var records: Array = fixture.get("postWriteResolutions", [])
	_check("writes fixture carries all 44 post-write records (got %d)" % records.size(), records.size() == 44)
	_assert_resolution_table(seed, overlay, records, "post-write")


# =============================================================================
# Overlay guards
# =============================================================================

func _test_overlay_guards() -> void:
	print("-- overlay guards --")
	var seed := _seed_from_fixture()
	var overlay: Dictionary = {}

	# Copy-on-read, ARRAYS: mutating a resolved array must not reach the seed.
	var tags := StoreScript.try_resolve(seed, overlay, BASE, V_TAGS)
	tags.get_array().append(VariantScript.from_string("injected"))
	var tags_again := StoreScript.try_resolve(seed, overlay, BASE, V_TAGS)
	_check("copy-on-read: mutating a resolved array does not reach the seed", tags_again.get_array().size() == 2)

	# Copy-on-read, MAPS: the entry list AND its entry variants are detached.
	var loot := StoreScript.try_resolve(seed, overlay, BASE, V_LOOT)
	loot.get_map()["injected"] = VariantScript.from_int(99)
	loot.get_map()["gold"].set_int(4242)
	var loot_again := StoreScript.try_resolve(seed, overlay, BASE, V_LOOT)
	_check("copy-on-read: mutating a resolved map does not reach the seed", loot_again.get_map().size() == 2)
	_check("copy-on-read: mutating a resolved map ENTRY does not reach the seed", loot_again.get_map()["gold"].get_int() == 5)

	# Deep-copy-on-write: mutating the caller's value after the write must not reach the overlay.
	var written := VariantScript.from_array([VariantScript.from_string("a")])
	written.type = TypesScript.VariableType.STRING
	_check("array write lands", StoreScript.try_set(seed, overlay, BASE, V_TAGS, written))
	written.get_array().append(VariantScript.from_string("late"))
	var read_back := StoreScript.try_resolve(seed, overlay, BASE, V_TAGS)
	_check("deep-copy-on-write: mutating the written array afterwards does not reach the overlay", read_back.get_array().size() == 1)

	# Map writes REPLACE the whole value.
	var replacement: Dictionary = {"only": VariantScript.from_int(1)}
	_check("map write lands", StoreScript.try_set(seed, overlay, GRANDCHILD, V_LOOT, VariantScript.from_map(replacement)))
	var loot_after := StoreScript.try_resolve(seed, overlay, GRANDCHILD, V_LOOT)
	_check("a map write replaces the whole value", loot_after.get_map().size() == 1 and loot_after.get_map().has("only"))

	# Unknown asset: refused, and the overlay is untouched.
	var overlay_size := overlay.size()
	_check("a write to an unknown asset is refused", not StoreScript.try_set(seed, overlay, "da_nope", V_HP, VariantScript.from_int(1)))
	_check("a refused write leaves the overlay untouched", overlay.size() == overlay_size and not overlay.has("da_nope"))

	# Undeclared id: refused, and no empty per-asset table is minted.
	_check("a write of an undeclared id is refused", not StoreScript.try_set(seed, overlay, CHILD, "4c9a1e07b38f42d6a1057e2c93bd48f0", VariantScript.from_int(1)))
	_check("a refused write mints no per-asset table", not overlay.has(CHILD))

	# Reset restores seed state.
	StoreScript.reset_overlay(overlay)
	_check("reset clears the overlay", overlay.is_empty())
	var restored := StoreScript.try_resolve(seed, overlay, BASE, V_TAGS)
	_check("reset restores the seed value", restored.get_array().size() == 2)


# =============================================================================
# Chain guards
# =============================================================================

func _test_chain_guards() -> void:
	print("-- chain guards --")

	# A 2-node cycle with DIFFERENT values on each side: both directions must terminate AND
	# report the root-most declaration they actually reached, which a walk that stopped at the
	# first level (or never stopped at all) could not do.
	var cyclic := _seed_from_json({
		"a": {
			"id": "a", "parent": "b",
			"variables": [{"id": "x", "name": "x", "type": "integer", "value": 1}],
		},
		"b": {
			"id": "b", "parent": "a",
			"variables": [{"id": "x", "name": "x", "type": "integer", "value": 2}],
		},
	})
	var from_a := StoreScript.try_resolve(cyclic, {}, "a", "x")
	var from_b := StoreScript.try_resolve(cyclic, {}, "b", "x")
	_check("a 2-node cycle terminates from A and reports B's declaration (got %s)" % from_a.get_int(), from_a.get_int() == 2)
	_check("a 2-node cycle terminates from B and reports A's declaration (got %s)" % from_b.get_int(), from_b.get_int() == 1)

	# A 200-level chain: the walk admits MAX_CHAIN_DEPTH ancestors PLUS the starting level, so
	# a declaration on level 64 is reached and one on level 65 is not.
	var deep_raw: Dictionary = {}
	for i in range(200):
		var level: Dictionary = {"id": "L%d" % i, "parent": null if i == 199 else "L%d" % (i + 1), "variables": []}
		if i == 64:
			level["variables"] = [{"id": "v64", "name": "v64", "type": "integer", "value": 64}]
		elif i == 65:
			level["variables"] = [{"id": "v65", "name": "v65", "type": "integer", "value": 65}]
		deep_raw["L%d" % i] = level
	var deep := _seed_from_json(deep_raw)
	var at_64 := StoreScript.try_resolve(deep, {}, "L0", "v64")
	var at_65 := StoreScript.try_resolve(deep, {}, "L0", "v65")
	_check("a declaration on chain level 64 resolves", at_64 != null and at_64.get_int() == 64)
	_check("a declaration on chain level 65 is past the depth cap", at_65 == null)


# =============================================================================
# Seed build: drops and typing
# =============================================================================

func _test_seed_build_drops_and_typing() -> void:
	print("-- seed build drops and typing --")
	var T := TypesScript.VariableType

	var seed := _seed_from_json({
		"base": {
			"id": "base", "parent": null,
			"variables": [
				{"id": "kv", "name": "kv", "type": "map", "keyType": "integer", "valueType": "string",
					"value": [{"key": 1, "value": "one"}]},
				{"id": "ranks", "name": "ranks", "type": "enum", "isArray": true,
					"enumValues": ["Grunt", "Elite"], "value": ["Grunt", "Elite"]},
				{"id": "empty", "name": "empty", "type": "string", "isArray": true, "value": []},
				{"id": "valueless", "name": "valueless", "type": "integer"},
				{"id": "badmap", "name": "badmap", "type": "map", "keyType": "string", "valueType": "integer",
					"value": [{"key": "seeded", "value": 3}]},
				{"id": "lore", "name": "lore", "type": "category"},
				{"id": "future", "name": "future", "type": "widget", "value": "?"},
			],
			"overrides": {},
		},
		"child": {
			"id": "child", "parent": "base",
			"variables": [],
			"overrides": {
				# Typed against the ANCESTOR's declaration: integer KEYS, string VALUES.
				"kv": [{"key": 7, "value": "seven"}],
				# A map override that is not an entry list cannot be read as a map.
				"badmap": "not-an-entry-list",
				# Nothing on the chain declares this id.
				"ghost": 1,
			},
		},
	})

	_check("an orphan override never enters the seed", not seed["child"]["overrides"].has("ghost"))
	_check("an orphan override does not resolve", StoreScript.try_resolve(seed, {}, "child", "ghost") == null)

	_check("a malformed map override never enters the seed", not seed["child"]["overrides"].has("badmap"))
	var badmap := StoreScript.try_resolve(seed, {}, "child", "badmap")
	_check("a dropped map override falls back to the declared value", badmap.get_map().has("seeded"))

	var kv := StoreScript.try_resolve(seed, {}, "child", "kv")
	_check("an inherited map override is typed against the ANCESTOR's keyType", kv.get_map().has(7))
	_check("an inherited map override is typed against the ANCESTOR's valueType", kv.get_map().get(7, null) != null and kv.get_map()[7].get_string() == "seven")

	var ranks := StoreScript.try_resolve(seed, {}, "base", "ranks")
	_check("enum array elements are ENUM-typed, not STRING-typed", ranks.get_array().size() == 2 and ranks.get_array()[0].type == T.ENUM)

	var empty := StoreScript.try_resolve(seed, {}, "base", "empty")
	_check("an empty array keeps its declared type tag", empty.get_array().is_empty() and empty.type == T.STRING)

	var valueless := StoreScript.try_resolve(seed, {}, "base", "valueless")
	_check("a valueless declaration still RESOLVES", valueless != null)
	_check("a valueless declaration resolves to its type default", valueless != null and valueless.type == T.INTEGER and valueless.get_int() == 0)

	# A HAND-ASSEMBLED seed whose declaration carries no value at all. The importer always
	# stamps a type default, so this shape never ships — but the seed is a plain Dictionary any
	# caller can build, and the resolver must not depend on a repair that happens elsewhere.
	# "Does some level declare this id?" and "does that declaration carry a value?" are
	# different questions: keying success on the VALUE reports this as undeclared, the same
	# answer a deleted variable gets, and sends an accessor down the degraded path instead of
	# handing it its type default.
	var bare_seed: Dictionary = {
		"solo": {
			"id": "solo", "parent": "", "overrides": {},
			"variables": [{"id": "v", "name": "v", "type": T.INTEGER, "is_array": false, "value": null}],
		},
	}
	var bare := StoreScript.try_resolve(bare_seed, {}, "solo", "v")
	_check("a declaration with a NULL value still resolves (the found FLAG, not the value)", bare != null and bare.get_int() == 0)

	_check("a category row is dropped at import", StoreScript.find_declaration(seed, "base", "lore").is_empty())
	_check("a category row never resolves", StoreScript.try_resolve(seed, {}, "base", "lore") == null)
	_check("an unknown-type row is dropped at import", StoreScript.find_declaration(seed, "base", "future").is_empty())

	# Root-most declaration ownership, and the name lookup that follows the same rule.
	_check("find_declaration_by_name finds an inherited declaration", StoreScript.find_declaration_by_name(seed, "child", "valueless").get("id", "") == "valueless")
	_check("find_declaration_by_name answers nothing for an unknown name", StoreScript.find_declaration_by_name(seed, "child", "nope").is_empty())
	_check("is_declared_on_chain sees an inherited id", StoreScript.is_declared_on_chain(seed, "child", "kv"))
	_check("is_declared_on_chain refuses an undeclared id", not StoreScript.is_declared_on_chain(seed, "child", "ghost"))


# =============================================================================
# The snapshot match rule
# =============================================================================

## The 10 golden pairs mirrored from the editor repo's
## src/__tests__/runtime/data-asset-nodes.test.ts (the editor's matchesSnapshot / the HTML
## runtime's declMatches go through the same table), plus the two rows only a typed engine can
## fail: a wire type the shared table does not know, and a CASE VARIANT of one it does.
func _test_decl_matches() -> void:
	print("-- declMatches golden pairs --")
	var T := TypesScript.VariableType
	var rows: Array = [
		["identical scalar", _decl(T.STRING), "string", false, "", "", true],
		["type moved", _decl(T.INTEGER), "string", false, "", "", false],
		["identical array", _decl(T.STRING, true), "string", true, "", "", true],
		["scalar binding over an array declaration", _decl(T.STRING, true), "string", false, "", "", false],
		["array binding over a scalar declaration", _decl(T.STRING), "string", true, "", "", false],
		["isArray false vs absent are the same thing", _decl(T.STRING, false), "string", false, "", "", true],
		["identical map", _decl(T.MAP, false, T.STRING, T.INTEGER), "map", false, "string", "integer", true],
		["map value type moved", _decl(T.MAP, false, T.STRING, T.STRING), "map", false, "string", "integer", false],
		["map key type moved", _decl(T.MAP, false, T.INTEGER, T.INTEGER), "map", false, "string", "integer", false],
		["K/V ignored off a non-map binding", _decl(T.STRING, false, T.INTEGER), "string", false, "string", "", true],
		["an unknown wire type never matches", _decl(T.STRING), "widget", false, "", "", false],
		["a CASE VARIANT of a known wire type never matches", _decl(T.BOOLEAN), "Boolean", false, "", "", false],
	]

	_check("declMatches table carries all 12 rows (got %d)" % rows.size(), rows.size() == 12)
	for row in rows:
		var verdict: bool = StoreScript.decl_matches(row[1], row[2], row[3], row[4], row[5])
		_check("declMatches: %s" % row[0], verdict == row[6])

	_check("declMatches refuses an empty declaration", not StoreScript.decl_matches({}, "string", false, "", ""))


func _decl(type, is_array: bool = false, key_type = TypesScript.VariableType.NONE, value_type = TypesScript.VariableType.NONE) -> Dictionary:
	return {"id": "d", "name": "d", "type": type, "is_array": is_array, "key_type": key_type, "value_type": value_type}


# =============================================================================
# Fixture + seed helpers
# =============================================================================

func _load_fixture(file_name: String) -> Dictionary:
	var path := FIXTURE_DIR.path_join(file_name)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		printerr("  SETUP FAILURE: cannot read %s" % path)
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}


## A seed built from the shared golden seed fixture through the REAL importer parse path.
func _seed_from_fixture() -> Dictionary:
	var fixture := _load_fixture("data-assets-seed.json")
	return _seed_from_json(fixture.get("dataAssets", {}))


## A seed built from a raw data-assets.json "dataAssets" table, through the real importer parse
## helper and the real two-pass build. Everything the runtime does, minus the file on disk.
func _seed_from_json(raw: Dictionary) -> Dictionary:
	var project = ProjectScript.new()
	project.data_assets = _importer._parse_data_assets(raw)
	var seed: Dictionary = {}
	StoreScript.build_seed(project, seed)
	return seed


## Resolve and compare one fixture table, count-guarded by the caller.
func _assert_resolution_table(seed: Dictionary, overlay: Dictionary, records: Array, label: String) -> void:
	var mismatches := 0
	for record in records:
		var asset_id: String = record.get("assetId", "")
		var variable_id: String = record.get("variableId", "")
		var resolved = StoreScript.try_resolve(seed, overlay, asset_id, variable_id)
		if not record.get("resolved", false):
			if resolved != null:
				mismatches += 1
				printerr("    %s: %s.%s resolved but should not have" % [label, asset_id, record.get("variableName", variable_id)])
			continue
		if resolved == null:
			mismatches += 1
			printerr("    %s: %s.%s did not resolve" % [label, asset_id, record.get("variableName", variable_id)])
			continue
		var declaration := StoreScript.find_declaration(seed, asset_id, variable_id)
		var actual = _to_json(resolved, bool(declaration.get("is_array", false)))
		if not _json_equal(actual, record.get("value")):
			mismatches += 1
			printerr("    %s: %s.%s expected %s got %s" % [label, asset_id, record.get("variableName", variable_id), record.get("value"), actual])
	_check("%s: all %d resolution records match the fixture (%d mismatches)" % [label, records.size(), mismatches], mismatches == 0)


# =============================================================================
# JSON <-> variant helpers
# =============================================================================

## A resolved variant back as plain JSON, so it can be compared with the fixture's raw value.
## The DECLARATION says whether the variant is array-shaped: an empty array and an empty scalar
## are indistinguishable from the variant alone, and the seed is schema-authoritative.
func _to_json(variant, is_array: bool):
	if variant == null:
		return null
	if variant.type == TypesScript.VariableType.MAP:
		var entries: Array = []
		var map: Dictionary = variant.get_map()
		for key in map:
			entries.append({"key": key, "value": _scalar_to_json(map[key])})
		return entries
	if is_array:
		var elements: Array = []
		for element in variant.get_array():
			elements.append(_scalar_to_json(element))
		return elements
	return _scalar_to_json(variant)


func _scalar_to_json(variant):
	if variant == null:
		return null
	match variant.type:
		TypesScript.VariableType.BOOLEAN:
			return variant.get_bool()
		TypesScript.VariableType.INTEGER:
			return variant.get_int()
		TypesScript.VariableType.FLOAT:
			return variant.get_float()
		TypesScript.VariableType.STRING, TypesScript.VariableType.ENUM:
			return variant.get_string()
		_:
			return null


## A variant typed from the JSON SHAPE alone — the write path's input, with no declaration
## consulted, so try_set's own guards are what decide whether a write lands.
func _variant_from_json(raw):
	if raw == null:
		return null
	if raw is bool:
		return VariantScript.from_bool(raw)
	if raw is int:
		return VariantScript.from_int(raw)
	if raw is float:
		return VariantScript.from_float(raw)
	if raw is String:
		return VariantScript.from_string(raw)
	if raw is Array:
		if raw.size() > 0 and raw[0] is Dictionary and raw[0].has("key"):
			var entries: Dictionary = {}
			for entry in raw:
				entries[entry["key"]] = _variant_from_json(entry.get("value"))
			return VariantScript.from_map(entries)
		var elements: Array = []
		for element in raw:
			elements.append(_variant_from_json(element))
		var variant = VariantScript.new()
		variant.set_array(elements)
		return variant
	return null


func _json_equal(a, b) -> bool:
	if a is Array and b is Array:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not _json_equal(a[i], b[i]):
				return false
		return true
	if a is Dictionary and b is Dictionary:
		if a.size() != b.size():
			return false
		for key in a:
			if not b.has(key):
				return false
			if not _json_equal(a[key], b[key]):
				return false
		return true
	if (a is bool) != (b is bool):
		return false
	if (a is int or a is float) and (b is int or b is float):
		return is_equal_approx(float(a), float(b))
	return a == b
