extends SceneTree
## Headless tests for the UNIFIED v1 save format, its dual-dialect reader, and the sparse
## `dataAssets` key (engine contract 7).
##
## THREE GOLDEN FILES, three different jobs, and none of them is hand-written here:
##   tests/fixtures/engine-contract/data-assets-writes.json  its saveKey member IS the overlay
##       key's shape, generated from the HTML runtime — the proof that all four runtimes persist
##       .sfd session state byte-shape-identically.
##   tests/fixtures/unified-state-v1.json                    a document written by the UNITY
##       plugin. Loading it here is the whole cross-engine claim: a save made in one engine
##       restores in another.
##   tests/fixtures/legacy-save-v1.json                      a real pre-v1.3.0 Godot save,
##       frozen from the writer that no longer exists (see tests/test_save_legacy_shape.gd).
##
## Every fixture-driven loop is COUNT-GUARDED: a fixture that silently shrinks would otherwise
## turn into a test that silently passes.
##
## Run from the repository root (import first to build the class cache):
##   godot --headless --import
##   godot --headless --script res://tests/test_save_unified.gd
## Or: powershell -File tests/run_tests.ps1 -GodotExe <path-to-godot>

const CharacterScript := preload("res://addons/storyflow/core/storyflow_character.gd")
const ComponentScript := preload("res://addons/storyflow/core/storyflow_component.gd")
const Graph := preload("res://tests/data_asset_test_graph.gd")
const ImporterScript := preload("res://addons/storyflow/editor/storyflow_importer.gd")
const ManagerScript := preload("res://addons/storyflow/core/storyflow_manager.gd")
const ProjectScript := preload("res://addons/storyflow/core/storyflow_project.gd")
const SaveScript := preload("res://addons/storyflow/core/storyflow_save_data.gd")
const StoreScript := preload("res://addons/storyflow/core/storyflow_data_asset_store.gd")
const Types := preload("res://addons/storyflow/core/storyflow_types.gd")
const VariantScript := preload("res://addons/storyflow/core/storyflow_variant.gd")

const FIXTURE_DIR := "res://tests/fixtures/engine-contract"
const SAVE_DIR := "user://storyflow_saves/"

const BASE := "da_0a1b2c3d4e5f60718293a4b5c6d7e8f9"
const CHILD := "da_1b2c3d4e5f60718293a4b5c6d7e8f90a"
const GRANDCHILD := "da_2c3d4e5f60718293a4b5c6d7e8f90a1b"
const V_ALIVE := "7f3a1c9e4b2d40518a6f0c3e7d1b5a29"
const V_HP := "2e8b6d0a1f4c47d3b95e2a70c6f81d34"
const V_TAGS := "c58e2f13a0d64c9b871e3f05d2a76b48"
const V_LOOT := "6d0f39a8b21e47c5903af8d61c72e504"
const V_GHOST := "4c9a1e07b38f42d6a1057e2c93bd48f0"

const HERO_PATH := "characters\\hero.json"

var _checks: int = 0
var _failures: int = 0
var _importer = null
var _manager: Node = null


func _initialize() -> void:
	await process_frame
	_importer = ImporterScript.new()
	_setup_runtime()

	_test_unified_document_shape()
	_test_golden_save_key()
	_test_round_trip_and_resave()
	_test_cross_engine_golden()
	_test_legacy_back_compat()
	_test_load_rules()
	_test_in_place_pins()
	_test_character_name_and_image()
	await _test_dialogue_registration_balance()
	_test_set_project_mid_dialogue()
	_test_enum_array_element_tags()

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
# 1. The document
# =============================================================================

## The positive twin of tests/test_save_legacy_shape.gd: every difference that file records as
## ABSENT from the legacy document is asserted PRESENT here.
func _test_unified_document_shape() -> void:
	print("-- the unified v1 document --")
	_manager.reset_all_state()
	_check("save writes a slot", _manager.save_to_slot("unified_shape"))
	var doc := _read_slot("unified_shape")

	_check("version is the STRING \"1\", not an integer", doc.get("version", null) is String and doc["version"] == "1")
	_check("sections are camelCase", doc.has("globalVariables") and doc.has("characters") and doc.has("usedOnceOnlyOptions"))
	_check("the legacy snake_case sections are gone", not doc.has("global_variables") and not doc.has("save_version"))
	_check("the root has exactly the five v1 sections (got %d)" % doc.size(), doc.size() == 5)

	# ALWAYS PRESENT, {} when the session wrote nothing — that is what makes "the key is absent"
	# mean "an older save" rather than "an untouched session".
	_check("dataAssets is present even with an empty overlay", doc.has("dataAssets"))
	_check("and is an empty object, not null", doc.get("dataAssets") is Dictionary and doc["dataAssets"].is_empty())

	var globals: Dictionary = doc.get("globalVariables", {})
	var gold: Dictionary = globals.get("v1", {})
	_check("a record carries its id", gold.get("id", "") == "v1")
	_check("a record carries its name", gold.get("name", "") == "gold")
	_check("a record's type is a NAME, not an integer code", gold.get("type", null) is String and gold["type"] == "Integer")
	_check("a record carries isArray in camelCase", gold.has("isArray") and not gold.has("is_array"))
	_check("a scalar value is BARE, not a {type, value} envelope", not (gold.get("value") is Dictionary))
	_check("and carries the runtime value", int(gold.get("value", -1)) == 0)

	var inventory: Dictionary = globals.get("v6", {})
	_check("an array record flags isArray true", bool(inventory.get("isArray", false)))
	_check("and its value is a bare JSON array", inventory.get("value") is Array)

	var scores: Dictionary = globals.get("v7", {})
	_check("a map record carries keyType/valueType as NAMES",
		scores.get("keyType", "") == "String" and scores.get("valueType", "") == "Integer")
	_check("and its value is an entry list", scores.get("value") is Array)

	var mood: Dictionary = globals.get("v5", {})
	_check("an enum record carries its enumValues list", mood.get("enumValues", []) is Array and mood["enumValues"].size() == 2)

	var hero: Dictionary = doc.get("characters", {}).get(HERO_PATH, {})
	_check("a character record now persists its name", hero.get("name", "") == "Hero")
	_check("a character record now persists its image", hero.get("image", "") == "portraits/hero.png")
	_check("character variables still key by NAME", hero.get("variables", {}).has("affection"))


# =============================================================================
# 2. The golden save key
# =============================================================================

## The 6 scripted writes from data-assets-writes.json, then a byte-shape comparison of the
## `dataAssets` subtree against the fixture's saveKey member. Structural for objects (key order
## in a JSON object is not meaningful), ORDER-SENSITIVE for arrays — a map's entry order is
## authored and observable, and the write that produced it wrote gems before gold.
func _test_golden_save_key() -> void:
	print("-- the golden dataAssets save key --")
	_manager.reset_all_state()
	_replay_fixture_writes()

	_check("save writes a slot", _manager.save_to_slot("unified_writes"))
	var doc := _read_slot("unified_writes")
	var fixture := _load_fixture("data-assets-writes.json")
	var expected = fixture.get("saveKey", {})

	_check("the saveKey fixture carries all 3 written assets (got %d)" % expected.size(), expected.size() == 3)
	_check("the saved dataAssets key matches the golden saveKey exactly",
		_json_equal(doc.get("dataAssets", {}), expected))

	# The refused write must not have minted a table on its way past.
	_check("the refused write left no entry in the save",
		not doc.get("dataAssets", {}).get(CHILD, {}).has(V_GHOST))

	# Entry ORDER, asserted directly rather than left to _json_equal's array walk to imply.
	var loot = doc.get("dataAssets", {}).get(GRANDCHILD, {}).get(V_LOOT, [])
	_check("a map is saved as an ordered entry list in the order written",
		loot is Array and loot.size() == 2 and loot[0].get("key", "") == "gems" and loot[1].get("key", "") == "gold")


# =============================================================================
# 3. Round trip + resave stability
# =============================================================================

func _test_round_trip_and_resave() -> void:
	print("-- round trip + resave stability --")
	_manager.reset_all_state()
	_replay_fixture_writes()
	_check("save writes a slot", _manager.save_to_slot("unified_rt"))

	# Drop every session write, then prove it is really gone before loading it back — otherwise
	# a load that did nothing at all would pass the table below.
	_manager.reset_data_assets()
	var seed: Dictionary = _manager.get_data_asset_seed()
	var overlay: Dictionary = _manager.get_data_asset_overlay()
	_check("the overlay is empty before the load", overlay.is_empty())
	_check("and hp reads the seed value again", StoreScript.try_resolve(seed, overlay, CHILD, V_HP).get_int() == 150)

	_check("load reports success", _manager.load_from_slot("unified_rt"))

	var fixture := _load_fixture("data-assets-writes.json")
	var records: Array = fixture.get("postWriteResolutions", [])
	_check("the fixture carries all 44 post-write records (got %d)" % records.size(), records.size() == 44)
	_assert_resolution_table(seed, overlay, records, "after load")

	# TYPE TAGS, asserted on what is IN the overlay rather than on a read-back: an enum written
	# as a plain string and an emptied array that lost its element type both read back fine and
	# only show up in the next save.
	var tags = _overlay_value(overlay, CHILD, V_TAGS)
	_check("a restored array is array-shaped with its element type stamped",
		tags != null and tags.get_array().size() == 3 and tags.type == Types.VariableType.STRING)
	_check("and its elements are typed from the DECLARATION",
		tags != null and tags.get_array()[0].type == Types.VariableType.STRING)
	var loot = _overlay_value(overlay, GRANDCHILD, V_LOOT)
	_check("a restored map keeps the MAP tag", loot != null and loot.type == Types.VariableType.MAP)
	_check("and its integer entry values are INTEGER-typed, not string",
		loot != null and loot.get_map().get("gems", null) != null and loot.get_map()["gems"].type == Types.VariableType.INTEGER)

	# RESAVE STABILITY: a save -> load -> save cycle must be a fixed point. This is what a
	# declaration-typed load buys — a read cannot tell an enum from a string, but the next save
	# can.
	#
	# BYTE-IDENTITY IS THE INSTRUMENT, NOT THE CONTRACT. It is simply the sharpest comparison
	# available here, and it over-pins: it also asserts key ORDER, which the format does not
	# require of anyone (JSON object key order is not meaningful, and this only holds because
	# JSON.stringify sorts). A deliberate change to how keys are ordered is expected to update
	# this assertion; a change to what is IN the document is not.
	_check("resave writes a slot", _manager.save_to_slot("unified_rt2"))
	_check("save -> load -> save is byte-identical",
		_read_slot_text("unified_rt") == _read_slot_text("unified_rt2"))


# =============================================================================
# 4. The cross-engine golden
# =============================================================================

## tests/fixtures/unified-state-v1.json was written by the UNITY plugin. Loading it here is the
## shared-format proof: no Godot code produced this file, and every value in it lands.
func _test_cross_engine_golden() -> void:
	print("-- the cross-engine unified-state-v1 golden --")
	_manager.reset_all_state()
	_copy_fixture_to_slot("res://tests/fixtures/unified-state-v1.json", "cross_engine")
	_check("load reports success", _manager.load_from_slot("cross_engine"))

	_check("an Integer lands", _global_int("v1") == 42)
	_check("a String lands", _global_string("v2") == "Ada")
	_check("a Boolean lands", _global_value("v3").get_bool() == true)
	_check("a Float lands", is_equal_approx(_global_value("v4").get_float(), 0.75))
	# The type NAME is what carries this across engines: Unity's Enum = 4 is Godot's STRING = 4.
	# A format keyed on integer codes would have landed "Happy" as a plain string here.
	_check("an Enum lands ENUM-typed, not as a string",
		_global_value("v5").type == Types.VariableType.ENUM and _global_value("v5").get_string() == "Happy")
	var inventory := _global_value("v6")
	_check("an array lands with both elements",
		inventory.get_array().size() == 2 and inventory.get_array()[0].get_string() == "rope")
	var scores := _global_value("v7")
	_check("a map lands as an ordered entry list",
		scores.type == Types.VariableType.MAP and scores.get_map().size() == 2)
	_check("and its integer values are INTEGER-typed",
		scores.get_map().get("alice", null) != null and scores.get_map()["alice"].get_int() == 10)

	var hero: CharacterScript = _manager.get_runtime_character(HERO_PATH)
	_check("a character's saved name lands", hero != null and hero.character_name == "Hero")
	_check("a character's saved image lands", hero != null and hero.image_key == "portraits/hero.png")
	_check("a character variable lands by NAME",
		hero != null and hero.variables["affection"]["value"].get_int() == 7)

	_check("once-only options land", _manager.is_option_used("scriptA:node4:opt1") and _manager.is_option_used("scriptB:node9:opt2"))
	# The golden predates the dataAssets key entirely — an absent key CLEARS, which is seed state.
	_check("a unified save with no dataAssets key leaves the overlay clear", _manager.get_data_asset_overlay().is_empty())


# =============================================================================
# 5. Legacy back-compat
# =============================================================================

func _test_legacy_back_compat() -> void:
	print("-- legacy back-compat --")
	_manager.reset_all_state()
	_copy_fixture_to_slot("res://tests/fixtures/legacy-save-v1.json", "legacy")

	# A session write that must NOT survive: a legacy save carries no .sfd state, and replace
	# semantics mean loading one restores seed state rather than leaving the session's writes on.
	StoreScript.try_set(_manager.get_data_asset_seed(), _manager.get_data_asset_overlay(),
		BASE, V_ALIVE, VariantScript.from_bool(false))
	_check("the pre-load session write is in the overlay", not _manager.get_data_asset_overlay().is_empty())

	_check("the reader reports the legacy dialect",
		SaveScript.load_from_slot("legacy", _manager.get_data_asset_seed()).get("dialect", "") == SaveScript.DIALECT_LEGACY)
	_check("load reports success", _manager.load_from_slot("legacy"))

	_check("a legacy Integer lands", _global_int("g_int") == 42)
	_check("a legacy String lands", _global_string("g_str") == "Ada")
	_check("a legacy Boolean lands", _global_value("g_bool").get_bool() == true)
	_check("a legacy Float lands", is_equal_approx(_global_value("g_float").get_float(), 0.75))
	_check("a legacy Enum lands ENUM-typed", _global_value("g_enum").type == Types.VariableType.ENUM)
	_check("a legacy array lands", _global_value("g_arr").get_array().size() == 2)
	var legacy_map := _global_value("g_map")
	_check("a legacy map lands in authored order",
		legacy_map.get_map().keys() == ["alice", "bob"] and legacy_map.get_map()["bob"].get_int() == 20)
	var hero: CharacterScript = _manager.get_runtime_character(HERO_PATH)
	_check("a legacy character variable lands", hero != null and hero.variables["affection"]["value"].get_int() == 7)
	_check("and its name survives untouched, since a legacy save carries none",
		hero != null and hero.character_name == "Hero")
	_check("legacy once-only options land", _manager.is_option_used("D1-o1") and _manager.is_option_used("D2-o2"))

	_check("loading a legacy save CLEARS the .sfd overlay", _manager.get_data_asset_overlay().is_empty())
	_check("so a .sfd read is back on seed state",
		StoreScript.try_resolve(_manager.get_data_asset_seed(), _manager.get_data_asset_overlay(), BASE, V_ALIVE).get_bool() == true)


# =============================================================================
# 6. Load rules for the dataAssets key
# =============================================================================

func _test_load_rules() -> void:
	print("-- dataAssets load rules --")
	var seed: Dictionary = _manager.get_data_asset_seed()
	var overlay: Dictionary = _manager.get_data_asset_overlay()

	# ABSENT key clears.
	_manager.reset_all_state()
	StoreScript.try_set(seed, overlay, BASE, V_ALIVE, VariantScript.from_bool(false))
	_write_slot("rules_absent", {"version": "1", "globalVariables": {}, "characters": {}, "usedOnceOnlyOptions": []})
	_manager.load_from_slot("rules_absent")
	_check("an absent dataAssets key clears the overlay", overlay.is_empty())

	# MALFORMED key clears too — anything that is not an object is not a table.
	StoreScript.try_set(seed, overlay, BASE, V_ALIVE, VariantScript.from_bool(false))
	_write_slot("rules_malformed", {"version": "1", "globalVariables": {}, "dataAssets": "nope"})
	_manager.load_from_slot("rules_malformed")
	_check("a malformed dataAssets key clears the overlay", overlay.is_empty())

	# REPLACE, not merge: the pre-load write is to BASE, the save mentions only CHILD.
	StoreScript.try_set(seed, overlay, BASE, V_ALIVE, VariantScript.from_bool(false))
	_write_slot("rules_replace", {"version": "1", "dataAssets": {CHILD: {V_HP: 11}}})
	_manager.load_from_slot("rules_replace")
	_check("load REPLACES the overlay - the pre-load asset is gone", not overlay.has(BASE))
	_check("and the saved one is there", _overlay_value(overlay, CHILD, V_HP) != null and _overlay_value(overlay, CHILD, V_HP).get_int() == 11)
	_check("an unmentioned variable on a mentioned asset is not carried over", not overlay[CHILD].has(V_ALIVE))

	# DROPS: an assetId this build does not carry (warned), and a variableId no chain level
	# declares (quiet, contract 7's carve-out).
	_write_slot("rules_drops", {"version": "1", "dataAssets": {
		"da_deleted_since_the_save": {V_HP: 1},
		CHILD: {V_HP: 9, V_GHOST: 5},
	}})
	_manager.load_from_slot("rules_drops")
	_check("an asset the seed does not carry is dropped", not overlay.has("da_deleted_since_the_save"))
	_check("a variable no chain level declares is dropped", not overlay[CHILD].has(V_GHOST))
	_check("while its declared sibling survives", _overlay_value(overlay, CHILD, V_HP).get_int() == 9)

	# NO EMPTY INNER TABLES: an asset whose every entry was dropped leaves nothing behind, or it
	# would ride every subsequent save carrying nothing.
	_write_slot("rules_empty", {"version": "1", "dataAssets": {CHILD: {V_GHOST: 5}}})
	_manager.load_from_slot("rules_empty")
	_check("an asset whose every entry was dropped mints no empty table", not overlay.has(CHILD))
	_check("so the overlay is empty, not {asset: {}}", overlay.is_empty())

	# A SECTION OF THE WRONG KIND restores as nothing rather than failing the load. A save file
	# is exactly the input that arrives hand-edited, truncated or half-synced.
	_write_slot("rules_garbage", {"version": "1", "globalVariables": 5, "characters": "no",
		"usedOnceOnlyOptions": {"not": "an array"}, "dataAssets": [1, 2]})
	_check("a document whose every section is the wrong kind still loads", _manager.load_from_slot("rules_garbage"))
	_check("and restores nothing from it", overlay.is_empty() and _manager.get_used_once_only_options().is_empty())

	# UNKNOWN ROOT KEYS are ignored — that is how an older plugin build loads a newer save, and
	# how this one loads whatever the format grows next.
	_write_slot("rules_unknown", {"version": "1", "dataAssets": {CHILD: {V_HP: 3}},
		"somethingFromTheFuture": {"a": 1}, "anotherOne": [1, 2, 3]})
	_check("a save with unknown root keys still loads", _manager.load_from_slot("rules_unknown"))
	_check("and its known sections still land", _overlay_value(overlay, CHILD, V_HP).get_int() == 3)

	# The dialect sniff is STRUCTURAL: a document with camelCase sections is unified no matter
	# what its version field says, and one with global_variables is legacy no matter what.
	_write_slot("rules_sniff", {"save_version": 1, "global_variables": {}, "dataAssets": {CHILD: {V_HP: 77}}})
	var sniffed := SaveScript.load_from_slot("rules_sniff", seed)
	_check("global_variables makes a document LEGACY even carrying a dataAssets key",
		sniffed.get("dialect", "") == SaveScript.DIALECT_LEGACY)
	_check("and the legacy arm reads no .sfd state from it", sniffed.get("data_assets", {}).is_empty())


# =============================================================================
# 7. In-place mutation pins
# =============================================================================

## The v1.2.3 lesson, pinned on the load path for BOTH dialects: a running session holds these
## dictionaries BY REFERENCE (the execution context takes them at dialogue start), so a load that
## rebinds one strands every live reference on the pre-load object.
func _test_in_place_pins() -> void:
	print("-- in-place mutation pins --")
	_manager.reset_all_state()

	# The references a dialogue would be holding.
	var globals_ref: Dictionary = _manager.get_global_variables()
	var characters_ref: Dictionary = _manager.get_runtime_characters()
	var overlay_ref: Dictionary = _manager.get_data_asset_overlay()
	var once_only_ref: Dictionary = _manager.get_used_once_only_options()

	_copy_fixture_to_slot("res://tests/fixtures/unified-state-v1.json", "pins_unified")
	_manager.load_from_slot("pins_unified")
	_check("UNIFIED: the pre-load globals reference sees the loaded value",
		globals_ref["v1"]["value"].get_int() == 42)
	_check("UNIFIED: the globals dictionary is the SAME object", _manager.get_global_variables() == globals_ref)
	_check("UNIFIED: the pre-load characters reference sees the loaded character",
		characters_ref[HERO_PATH].variables["affection"]["value"].get_int() == 7)
	_check("UNIFIED: the pre-load once-only reference sees the loaded keys", once_only_ref.has("scriptA:node4:opt1"))

	_write_slot("pins_overlay", {"version": "1", "dataAssets": {CHILD: {V_HP: 21}}})
	_manager.load_from_slot("pins_overlay")
	_check("UNIFIED: the pre-load overlay reference sees the loaded .sfd values",
		_overlay_value(overlay_ref, CHILD, V_HP) != null and _overlay_value(overlay_ref, CHILD, V_HP).get_int() == 21)

	_manager.reset_all_state()
	_copy_fixture_to_slot("res://tests/fixtures/legacy-save-v1.json", "pins_legacy")
	_manager.load_from_slot("pins_legacy")
	_check("LEGACY: the pre-load globals reference sees the loaded value",
		globals_ref["g_int"]["value"].get_int() == 42)
	_check("LEGACY: the globals dictionary is STILL the same object", _manager.get_global_variables() == globals_ref)
	_check("LEGACY: the pre-load characters reference sees the loaded character",
		characters_ref[HERO_PATH].variables["affection"]["value"].get_int() == 7)
	_check("LEGACY: the pre-load once-only reference sees the loaded keys", once_only_ref.has("D1-o1"))

	# The guard that makes the load-side cache question moot: a load is refused outright while
	# any dialogue is registered, and the only path that unregisters one nulls its evaluator
	# first, so no evaluator can be holding a memoized read when a load lands.
	_manager.register_dialogue_start()
	_check("a load is refused while a dialogue is active", not _manager.load_from_slot("pins_legacy"))
	_manager.register_dialogue_end()
	_check("and allowed again once it ends", _manager.load_from_slot("pins_legacy"))


# =============================================================================
# 8. Character name and image
# =============================================================================

## The shipped data loss the unified format fixes: setCharacterVar("Name") and ("Image") mutate
## both fields at story time and the legacy writer persisted neither, so every save silently
## reverted them.
func _test_character_name_and_image() -> void:
	print("-- character name and image round trip --")
	_manager.reset_all_state()
	var hero: CharacterScript = _manager.get_runtime_character(HERO_PATH)
	hero.character_name = "The Warden"
	hero.image_key = "portraits/warden_angry.png"
	_check("save writes a slot", _manager.save_to_slot("char_fields"))

	# Overwrite BOTH in memory, so a load that does nothing cannot pass.
	hero.character_name = "clobbered"
	hero.image_key = "clobbered.png"
	_check("load reports success", _manager.load_from_slot("char_fields"))
	_check("the runtime display name survives the round trip", hero.character_name == "The Warden")
	_check("the runtime portrait survives the round trip", hero.image_key == "portraits/warden_angry.png")
	_check("and the restore reached the LIVE character object, not a copy",
		_manager.get_runtime_character(HERO_PATH).character_name == "The Warden")


# =============================================================================
# 8b. The active-dialogue count that gates every load
# =============================================================================

## THE COUNT MUST BALANCE, because it is what every load is gated on. A component freed
## mid-dialogue - a scene change, a queue_free - used to keep its registration forever, which
## silently disabled .sfd persistence for the rest of the session with no way back short of
## restarting the game. It is also the invariant the loader's no-cache-clear reasoning rests on.
##
## TWO COMPONENTS, because each interesting failure is invisible with one: a LEAKED registration
## hides behind "some dialogue really is running", and a DOUBLE decrement is clamped away by
## register_dialogue_end's maxi(0, ...). With two, each one shows up as the count landing on the
## wrong side of the load guard while the other component's state says otherwise.
func _test_dialogue_registration_balance() -> void:
	print("-- the active-dialogue count balances --")
	_manager.reset_all_state()
	var script := Graph.build("scripts/Idle.sfe", {
		"0": Graph.start(),
		"D": Graph.dialogue("D"),
	}, [Graph.exec("0", "D")])
	_manager.get_project().scripts[script.script_path] = script

	var a := _start_component(script.script_path)
	var b := _start_component(script.script_path)
	_check("two running dialogues refuse a load", not _manager.load_from_slot("unified_shape"))

	# A stops NORMALLY and is only then torn out of the tree. _exit_tree must not decrement a
	# second time: if it did, the count would already be at zero and the load below would be
	# allowed while B is still parked in its dialogue.
	a.stop_dialogue()
	root.remove_child(a)
	a.queue_free()
	_check("a stopped-then-freed component gives its registration back exactly once",
		not _manager.load_from_slot("unified_shape"))

	# B is torn out of the tree MID-DIALOGUE, with no stop_dialogue at all. This is the leak.
	root.remove_child(b)
	b.queue_free()
	_check("a component freed mid-dialogue gives its registration back",
		_manager.load_from_slot("unified_shape"))
	_check("and the manager agrees no dialogue is active", not _manager.is_dialogue_active())

	# The real-world shape, rather than a hand-rolled remove_child: queue_free reaches the same
	# _exit_tree notification one frame later, which is how a scene change actually looks.
	var c := _start_component(script.script_path)
	_check("a fresh dialogue refuses a load again", not _manager.load_from_slot("unified_shape"))
	c.queue_free()
	await process_frame
	_check("and a queue_free'd component releases its registration too",
		_manager.load_from_slot("unified_shape"))

	# RESTART WITHOUT A STOP: nothing requires a host to stop before starting the next script,
	# and a component that took a second registration while still holding the first can never
	# give both back - _end_dialogue_registration is idempotent, so the single release on the
	# eventual stop pays off one acquisition and the count sticks at 1 forever. That disables
	# every later load, which is the witness fix's own failure mode reached through the other
	# door, so the start path releases before it reacquires.
	var d := _start_component(script.script_path)
	d.start_dialogue_with_script(script.script_path)
	_check("a restarted dialogue still refuses a load", not _manager.load_from_slot("unified_shape"))
	d.stop_dialogue()
	_check("ONE stop after a restart clears the count", not _manager.is_dialogue_active())
	_check("and a load succeeds again", _manager.load_from_slot("unified_shape"))
	root.remove_child(d)
	d.queue_free()


## SET_PROJECT IS REACHABLE MID-DIALOGUE - a host swapping projects, and the editor's WebSocket
## sync doing it on every re-import - so _initialize_from_project has to hold the same two
## invariants everything else on this page does.
##
## The globals half is the v1.2.3 stranding bug surviving on the one path nobody walked: that
## line rebound the dictionary a running evaluator was holding by reference, while the .sfd seed
## and overlay beside it were already in-place. Half the session's state stayed whole and half
## of it split in two.
##
## The count half is the other direction: zeroing _active_dialogue_count behind a component that
## is still running would let a load land while a live evaluator holds memoized reads, which is
## exactly the invariant load_from_slot's no-cache-clear reasoning rests on.
func _test_set_project_mid_dialogue() -> void:
	print("-- set_project mid-dialogue --")
	_manager.reset_all_state()
	var script := Graph.build("scripts/Swap.sfe", {
		"0": Graph.start(),
		"D": Graph.dialogue("D"),
	}, [Graph.exec("0", "D")])
	_manager.get_project().scripts[script.script_path] = script

	var component := _start_component(script.script_path)
	# The reference a running evaluator is holding, taken the way it takes it.
	var globals_ref: Dictionary = _manager.get_global_variables()
	var overlay_ref: Dictionary = _manager.get_data_asset_overlay()
	_check("the dialogue is registered before the swap", _manager.is_dialogue_active())

	_manager.set_project(_manager.get_project())

	_check("set_project keeps the globals dictionary IDENTITY", _manager.get_global_variables() == globals_ref)
	_check("and the pre-swap reference still sees the re-initialized values",
		globals_ref.has("v1") and globals_ref["v1"]["value"].get_int() == 0)
	_check("the .sfd overlay keeps its identity too", _manager.get_data_asset_overlay() == overlay_ref)
	# The registration belongs to the component, not to the project.
	_check("the running component's registration SURVIVES the swap", _manager.is_dialogue_active())
	_check("so a load is still refused", not _manager.load_from_slot("unified_shape"))

	component.stop_dialogue()
	_check("and an ordinary stop still releases it", not _manager.is_dialogue_active())
	root.remove_child(component)
	component.queue_free()


func _start_component(script_path: String) -> Node:
	var component := ComponentScript.new()
	component.dialogue_ui_scene = null
	root.add_child(component)
	component.start_dialogue_with_script(script_path)
	return component


# =============================================================================
# 9. Enum ARRAY element tags through save/load
# =============================================================================

## The seed fixtures carry no enum-typed ARRAY declaration, so nothing else in the suite can pin
## element tags for one. This builds a seed that does.
##
## The write goes in STRING-tagged on purpose — that is what an untyped caller produces — so what
## comes back ENUM-tagged can only have been typed by the DECLARATION on the way out of the save.
func _test_enum_array_element_tags() -> void:
	print("-- enum array element tags survive save/load --")
	var project = ProjectScript.new()
	project.data_assets = _importer._parse_data_assets({
		"da_enum": {
			"id": "da_enum", "name": "EnumHolder", "parent": null,
			"variables": [
				{"id": "ranks", "name": "ranks", "type": "enum", "isArray": true,
					"enumValues": ["Grunt", "Elite"], "value": ["Grunt"]},
				{"id": "blank", "name": "blank", "type": "enum", "isArray": true,
					"enumValues": ["Grunt", "Elite"], "value": []},
			],
			"overrides": {},
		},
	})
	_manager.set_project(project)
	var seed: Dictionary = _manager.get_data_asset_seed()
	var overlay: Dictionary = _manager.get_data_asset_overlay()

	var untagged := VariantScript.new()
	untagged.set_array([VariantScript.from_string("Elite"), VariantScript.from_string("Grunt")])
	_check("the STRING-tagged write lands", StoreScript.try_set(seed, overlay, "da_enum", "ranks", untagged))
	var emptied := VariantScript.new()
	emptied.set_array([])
	_check("the empty write lands", StoreScript.try_set(seed, overlay, "da_enum", "blank", emptied))

	_check("save writes a slot", _manager.save_to_slot("enum_arrays"))
	var doc := _read_slot("enum_arrays")
	_check("an EMPTIED array still saves as [], not as a scalar - the declaration decided",
		doc.get("dataAssets", {}).get("da_enum", {}).get("blank", null) is Array)

	_manager.reset_data_assets()
	_check("load reports success", _manager.load_from_slot("enum_arrays"))
	var ranks = _overlay_value(overlay, "da_enum", "ranks")
	_check("the restored array is ENUM-tagged", ranks != null and ranks.type == Types.VariableType.ENUM)
	_check("and so is every ELEMENT, from the declaration rather than from the save",
		ranks != null and ranks.get_array().size() == 2
		and ranks.get_array()[0].type == Types.VariableType.ENUM
		and ranks.get_array()[0].get_string() == "Elite")
	var blank = _overlay_value(overlay, "da_enum", "blank")
	_check("an emptied array comes back array-shaped and ENUM-tagged, with nothing to infer from",
		blank != null and blank.get_array().is_empty() and blank.type == Types.VariableType.ENUM)


# =============================================================================
# Runtime setup
# =============================================================================

func _setup_runtime() -> void:
	var T := Types.VariableType
	var project = ProjectScript.new()
	project.data_assets = _importer._parse_data_assets(_load_fixture("data-assets-seed.json").get("dataAssets", {}))

	# v1..v7 are the ids the CROSS-ENGINE golden carries; g_* are the ids the frozen LEGACY save
	# carries. Every default here differs from the value in the file that restores it, so a load
	# that did nothing could not pass.
	project.global_variables = {
		"v1": _var("v1", "gold", T.INTEGER, VariantScript.from_int(0)),
		"v2": _var("v2", "playerName", T.STRING, VariantScript.from_string("")),
		"v3": _var("v3", "metKing", T.BOOLEAN, VariantScript.from_bool(false)),
		"v4": _var("v4", "accuracy", T.FLOAT, VariantScript.from_float(0.0)),
		"v5": _enum_var("v5", "mood", VariantScript.from_enum("Sad")),
		"v6": _array_var("v6", "inventory", T.STRING, []),
		"v7": _map_var("v7", "scores", T.STRING, T.INTEGER),
		"g_int": _var("g_int", "legacyGold", T.INTEGER, VariantScript.from_int(0)),
		"g_str": _var("g_str", "legacyName", T.STRING, VariantScript.from_string("")),
		"g_bool": _var("g_bool", "legacyMet", T.BOOLEAN, VariantScript.from_bool(false)),
		"g_float": _var("g_float", "legacyAccuracy", T.FLOAT, VariantScript.from_float(0.0)),
		"g_enum": _enum_var("g_enum", "legacyMood", VariantScript.from_enum("Sad")),
		"g_arr": _array_var("g_arr", "legacyInventory", T.STRING, []),
		"g_empty": _array_var("g_empty", "legacySpent", T.STRING, []),
		"g_map": _map_var("g_map", "legacyScores", T.STRING, T.INTEGER),
	}

	var hero = CharacterScript.new()
	hero.character_name = "Hero"
	hero.image_key = "portraits/hero.png"
	hero.character_path = HERO_PATH
	hero.variables = {"affection": {"name": "affection", "type": T.INTEGER, "value": VariantScript.from_int(0)}}
	project.characters = {HERO_PATH: hero}

	_manager = ManagerScript.new()
	_manager.name = "StoryFlowRuntime"
	root.add_child(_manager)
	_manager.set_project(project)


func _var(id: String, name: String, type: Types.VariableType, value) -> Dictionary:
	return {"id": id, "name": name, "type": type, "is_array": false, "value": value}


func _enum_var(id: String, name: String, value) -> Dictionary:
	var v := _var(id, name, Types.VariableType.ENUM, value)
	v["enum_values"] = ["Happy", "Sad"]
	return v


func _array_var(id: String, name: String, type: Types.VariableType, values: Array) -> Dictionary:
	var elements: Array = []
	for value in values:
		elements.append(VariantScript.from_string(str(value)))
	var variant := VariantScript.new()
	variant.set_array(elements)
	variant.type = type
	var v := _var(id, name, type, variant)
	v["is_array"] = true
	return v


func _map_var(id: String, name: String, key_type: Types.VariableType, value_type: Types.VariableType) -> Dictionary:
	var v := _var(id, name, Types.VariableType.MAP, VariantScript.from_map({}))
	v["key_type"] = key_type
	v["value_type"] = value_type
	return v


## The 6 scripted writes, typed from the JSON SHAPE rather than from the declaration — the same
## rule tests/test_data_asset_store.gd's replay uses, so the refused write is refused by try_set's
## own chain guard and not by a missing declaration upstream of it.
func _replay_fixture_writes() -> void:
	var fixture := _load_fixture("data-assets-writes.json")
	var writes: Array = fixture.get("writes", [])
	_check("the writes fixture carries all 6 writes (got %d)" % writes.size(), writes.size() == 6)
	for entry in writes:
		StoreScript.try_set(_manager.get_data_asset_seed(), _manager.get_data_asset_overlay(),
			entry.get("assetId", ""), entry.get("variableId", ""), _variant_from_json(entry.get("value")))


# =============================================================================
# Slot + fixture helpers
# =============================================================================

func _read_slot_text(slot_name: String) -> String:
	var file := FileAccess.open(SAVE_DIR + slot_name + ".json", FileAccess.READ)
	if file == null:
		printerr("  SETUP FAILURE: cannot read slot %s" % slot_name)
		return ""
	var text := file.get_as_text()
	file.close()
	return text


func _read_slot(slot_name: String) -> Dictionary:
	var parsed = JSON.parse_string(_read_slot_text(slot_name))
	return parsed if parsed is Dictionary else {}


func _write_slot(slot_name: String, doc: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	var file := FileAccess.open(SAVE_DIR + slot_name + ".json", FileAccess.WRITE)
	file.store_string(JSON.stringify(doc, "\t"))
	file.close()


func _copy_fixture_to_slot(fixture_path: String, slot_name: String) -> void:
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	var src := FileAccess.open(fixture_path, FileAccess.READ)
	if src == null:
		printerr("  SETUP FAILURE: cannot read %s" % fixture_path)
		return
	var text := src.get_as_text()
	src.close()
	var dst := FileAccess.open(SAVE_DIR + slot_name + ".json", FileAccess.WRITE)
	dst.store_string(text)
	dst.close()


func _load_fixture(file_name: String) -> Dictionary:
	var file := FileAccess.open(FIXTURE_DIR.path_join(file_name), FileAccess.READ)
	if file == null:
		printerr("  SETUP FAILURE: cannot read %s" % file_name)
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}


# =============================================================================
# Assertion helpers
# =============================================================================

func _global_value(var_id: String) -> VariantScript:
	var value = _manager.get_global_variable(var_id).get("value", null)
	return value if value is VariantScript else VariantScript.new()


func _global_int(var_id: String) -> int:
	return _global_value(var_id).get_int(-1)


func _global_string(var_id: String) -> String:
	return _global_value(var_id).get_string("<missing>")


## The raw overlay entry, or null. Deliberately not a resolve: these assertions are about what
## the LOAD stored, tag and all, not about what a read would make of it.
func _overlay_value(overlay: Dictionary, asset_id: String, variable_id: String):
	var table = overlay.get(asset_id, null)
	if not table is Dictionary:
		return null
	return table.get(variable_id, null)


## Resolve and compare one fixture resolution table, count-guarded by the caller.
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


## A resolved variant back as plain JSON. The DECLARATION says whether it is array-shaped: an
## empty array and an empty scalar are indistinguishable from the variant alone.
func _to_json(variant, is_array: bool):
	if variant == null:
		return null
	if variant.type == Types.VariableType.MAP:
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
		Types.VariableType.BOOLEAN: return variant.get_bool()
		Types.VariableType.INTEGER: return variant.get_int()
		Types.VariableType.FLOAT: return variant.get_float()
		Types.VariableType.STRING, Types.VariableType.ENUM: return variant.get_string()
		_: return null


## A variant typed from the JSON SHAPE alone, with no declaration consulted.
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


## Structural for objects (JSON object key order is not meaningful), ORDER-SENSITIVE for arrays
## (a map's entry order is authored and observable).
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
