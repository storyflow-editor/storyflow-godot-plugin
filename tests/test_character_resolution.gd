extends SceneTree
## Headless tests for the P4 id-first character resolution on the NODE lanes (characters
## engine contract §3/§4): the speaker, the char-var evaluators (scalar, array and map), the
## setCharacterVar handler and the array write-back, all through the ONE resolution point
## (StoryFlowCharacter.resolve_character_key / resolve_character_ref) with the context-owned
## warn latch.
##
## FIXTURES: the DECOY PAIR from tests/character_test_fixtures.gd - same variable names,
## different values on every arm - and every id-bound node here carries the OTHER character's
## path in its path field, so a resolution that ignores the id answers a WRONG VALUE instead
## of a coincidentally right one. Every fixture-driven loop is COUNT-GUARDED.
##
## Run from the repository root (import first to build the class cache):
##   godot --headless --import
##   godot --headless --script res://tests/test_character_resolution.gd
## Or: powershell -File tests/run_tests.ps1 -GodotExe <path-to-godot>

const CharacterScript := preload("res://addons/storyflow/core/storyflow_character.gd")
const ComponentScript := preload("res://addons/storyflow/core/storyflow_component.gd")
const FX := preload("res://tests/character_test_fixtures.gd")
const Graph := preload("res://tests/data_asset_test_graph.gd")
const Handles := preload("res://addons/storyflow/core/storyflow_handles.gd")
const ImporterScript := preload("res://addons/storyflow/editor/storyflow_importer.gd")
const ManagerScript := preload("res://addons/storyflow/core/storyflow_manager.gd")
const Types := preload("res://addons/storyflow/core/storyflow_types.gd")
const VariantScript := preload("res://addons/storyflow/core/storyflow_variant.gd")

var _checks: int = 0
var _failures: int = 0
var _temp_root: String = ""
var _manager: Node = null


func _initialize() -> void:
	await process_frame
	_temp_root = OS.get_user_data_dir().path_join("sf_character_resolution_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(_temp_root)
	_manager = ManagerScript.new()
	_manager.name = "StoryFlowRuntime"
	get_root().add_child(_manager)

	_test_speaker_id_first()
	_test_per_arm_reads_id_bound()
	_test_per_arm_writes_id_bound_and_signal()
	_test_wired_override_wins()
	_test_dangling_warns_once_and_rearms()
	_test_unloaded_producer_falls_back_to_path()
	_test_id_and_path_reach_one_record()
	_test_pre_p4_full_run_sweep()

	_rm_rf(_temp_root)

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
		printerr("  FAIL: %s" % label)


# =============================================================================
# 1. Speaker id-first, with a deliberately WRONG path field
# =============================================================================

## A dialogue whose characterRefId names alice while its path field names BOB - the id must
## win, visibly: the speaker name, the {Character.cf_name} alias and a {Character.X} custom
## read all answer alice's values. Everything goes through the REAL wire (write_build +
## import), so the node-field carry and the resolution are exercised together.
func _test_speaker_id_first() -> void:
	print("-- speaker id-first --")
	_import_and_install("speaker", FX.index_text_valid(), {
		"0": {"type": "start"},
		"1": {"type": "dialogue", "text": "{Character.cf_name} trusts {Character.Trust}",
			"character": FX.BOB_KEY, "characterRefId": FX.ALICE_ID},
	}, [
		FX.wire_edge("0", "source-0-", "1", "target-1-"),
	])

	var component := _start("Main")
	var state = component._context.current_dialogue_state
	_check("the dialogue rendered", state != null and state.character != null)
	if state != null and state.character != null:
		_check("the id wins over the wrong path field (speaker is alice, got '%s')" % state.character.name,
			state.character.name == "char.alice.name")
		_check("{Character.cf_name} resolves through the first-tier alias (got '%s')" % state.text,
			state.text == "char.alice.name trusts 3")
	_check("no node-lane warning was emitted (got %d)" % component._context.character_id_warnings_emitted,
		component._context.character_id_warnings_emitted == 0)
	_check("no host-lane warning was emitted (got %d)" % _manager.character_id_access_warnings_emitted,
		_manager.character_id_access_warnings_emitted == 0)
	# Inheritance 1: the resolved key is byte-identical to its own normalization.
	_check("the record key is a normalize_path fixed point",
		CharacterScript.normalize_path(FX.ALICE_KEY) == FX.ALICE_KEY)
	_teardown(component)


# =============================================================================
# 2. Per-arm READS, id-bound, decoy paths
# =============================================================================

## One graph, five arms - boolean, integer, string, string array and map - every getter
## bound to alice by id while its path field names BOB. A resolution that ignores the id
## reads bob's values (false / 9 / Doctor / [bones] / 9), so every assertion is a decoy trap.
func _test_per_arm_reads_id_bound() -> void:
	print("-- per-arm reads, id-bound --")
	_import_and_install("reads", FX.index_text_valid())

	var decoy := {"characterPath": FX.BOB_KEY, "characterId": FX.ALICE_ID}
	var script := Graph.build("scripts/Reads.sfe", {
		"0": Graph.start(),
		"GB": _gcv("GB", _merge(decoy, {"variableName": "Brave", "variableType": "boolean"})),
		"GI": _gcv("GI", _merge(decoy, {"variableName": "Trust", "variableType": "integer"})),
		"GS": _gcv("GS", _merge(decoy, {"variableName": "Title", "variableType": "string"})),
		"GA": _gcv("GA", _merge(decoy, {"variableName": "Inventory", "variableType": "string", "isArray": true})),
		"GM": _gcv("GM", _merge(decoy, {"variableName": "Prices", "variableType": "map", "keyType": "string", "valueType": "integer"})),
		"GMV": Graph.node("GMV", Types.NodeType.GET_MAP_VALUE, "getMapValue",
			{"keyType": "string", "valueType": "integer", "key": "ale"}),
		"SB": Graph.node("SB", Types.NodeType.SET_BOOL, "setBool", {"variable": "got_bool", "isGlobal": false}),
		"SI": Graph.node("SI", Types.NodeType.SET_INT, "setInt", {"variable": "got_int", "isGlobal": false}),
		"SS": Graph.node("SS", Types.NodeType.SET_STRING, "setString", {"variable": "got_title", "isGlobal": false}),
		"SA": Graph.node("SA", Types.NodeType.SET_STRING_ARRAY, "setStringArray", {"variable": "got_inv", "isGlobal": false}),
		"SM": Graph.node("SM", Types.NodeType.SET_INT, "setInt", {"variable": "got_ale", "isGlobal": false}),
		"D": Graph.dialogue("D"),
	}, [
		Graph.exec("0", "SB"), Graph.exec_flow("SB", "SI"), Graph.exec_flow("SI", "SS"),
		Graph.exec_flow("SS", "SA"), Graph.exec_flow("SA", "SM"), Graph.exec_flow("SM", "D"),
		Graph.data_wire("GB", "boolean", "SB", Handles.IN_BOOLEAN),
		Graph.data_wire("GI", "integer", "SI", Handles.IN_INTEGER),
		Graph.data_wire("GS", "string", "SS", Handles.IN_STRING),
		Graph.data_wire("GA", "string-array", "SA", Handles.IN_STRING_ARRAY),
		Graph.map_wire("GM", "GMV", "string", "integer", "1"),
		Graph.data_wire("GMV", "integer", "SM", Handles.IN_INTEGER),
	], {
		"got_bool": Graph.scalar_var("got_bool", "got_bool", Types.VariableType.BOOLEAN, VariantScript.from_bool(false)),
		"got_int": Graph.scalar_var("got_int", "got_int", Types.VariableType.INTEGER, VariantScript.from_int(-1)),
		"got_title": Graph.scalar_var("got_title", "got_title", Types.VariableType.STRING, VariantScript.from_string("")),
		"got_inv": Graph.array_var("got_inv", "got_inv", Types.VariableType.STRING, []),
		"got_ale": Graph.scalar_var("got_ale", "got_ale", Types.VariableType.INTEGER, VariantScript.from_int(-1)),
	})

	var component := _run(script)
	_check("boolean read follows the id (alice true, got %s)" % component.get_bool_variable("got_bool"),
		component.get_bool_variable("got_bool") == true)
	_check("integer read follows the id (alice 3, got %d)" % component.get_int_variable("got_int"),
		component.get_int_variable("got_int") == 3)
	_check("string read follows the id (alice Captain, got '%s')" % _stored_string(component, "got_title"),
		_stored_string(component, "got_title") == "Captain")
	var inv := _stored_strings(component, "got_inv")
	_check("array read follows the id (alice [sword, rope], got %s)" % str(inv),
		inv == ["sword", "rope"])
	_check("map read follows the id (alice ale=3, got %d)" % component.get_int_variable("got_ale"),
		component.get_int_variable("got_ale") == 3)
	_check("no warnings on clean id reads (got %d)" % component._context.character_id_warnings_emitted,
		component._context.character_id_warnings_emitted == 0)
	_teardown(component)


# =============================================================================
# 3. Per-arm WRITES, id-bound, decoy paths + the signal pin
# =============================================================================

## Every write arm - boolean, string, array and map (integer rides in the sweep) - id-bound
## to alice with bob's path in the path field: the write must land on ALICE's record and bob
## must stay byte-untouched. The signal pin rides here: every NODE write emits
## character_variable_changed with the RESOLVED KEY as its character_path, and nothing else
## emits (the public-set half of A2(b) is pinned in the host-surface file).
func _test_per_arm_writes_id_bound_and_signal() -> void:
	print("-- per-arm writes, id-bound + signal --")
	_import_and_install("writes", FX.index_text_valid())

	var decoy := {"characterPath": FX.BOB_KEY, "characterId": FX.ALICE_ID}
	var inline_inventory := VariantScript.new()
	inline_inventory.set_array([VariantScript.from_string("lamp")])
	var script := Graph.build("scripts/Writes.sfe", {
		"0": Graph.start(),
		"W1": _scv("W1", _merge(decoy, {"variableName": "Brave", "variableType": "boolean", "value": VariantScript.from_bool(false)})),
		"W2": _scv("W2", _merge(decoy, {"variableName": "Title", "variableType": "string", "value": VariantScript.from_string("Admiral")})),
		"W3": _scv("W3", _merge(decoy, {"variableName": "Inventory", "variableType": "string", "isArray": true, "value": inline_inventory})),
		"W4": _scv("W4", _merge(decoy, {"variableName": "Prices", "variableType": "map", "keyType": "string", "valueType": "integer"})),
		"GSRC": Graph.node("GSRC", Types.NodeType.GET_MAP, "getMap", {"variable": "src_map", "isGlobal": false, "keyType": "string", "valueType": "integer"}),
		"D": Graph.dialogue("D"),
	}, [
		Graph.exec("0", "W1"), Graph.exec_flow("W1", "W2"), Graph.exec_flow("W2", "W3"),
		Graph.exec_flow("W3", "W4"), Graph.exec_flow("W4", "D"),
		Graph.map_wire("GSRC", "W4", "string", "integer", "input"),
	], {
		"src_map": Graph.map_var("src_map", "src_map", {"ale": VariantScript.from_int(42)}),
	})

	var emissions: Array = []
	var component := _make_component()
	component.character_variable_changed.connect(func(path, vname, _value): emissions.append([path, vname]))
	_manager.get_project().scripts[script.script_path] = script
	component.start_dialogue_with_script(script.script_path)

	var alice = _manager.get_runtime_characters()[FX.ALICE_KEY]
	var bob = _manager.get_runtime_characters()[FX.BOB_KEY]
	_check("boolean write lands on alice (got %s)" % str(_var_of(alice, "Brave").get_bool(true)),
		_var_of(alice, "Brave").get_bool(true) == false)
	_check("string write lands on alice (got '%s')" % _var_of(alice, "Title").get_string(),
		_var_of(alice, "Title").get_string() == "Admiral")
	var inv := _strings_of(_var_of(alice, "Inventory").get_array())
	_check("array write lands on alice (got %s)" % str(inv), inv == ["lamp"])
	var prices: Dictionary = _var_of(alice, "Prices").get_map()
	_check("map write lands on alice (ale=42, got %s)" % str(prices.get("ale")),
		prices.has("ale") and prices["ale"].get_int(-1) == 42)

	# Bob - the decoy - is byte-untouched on every arm his path field was dangled into.
	_check("bob's Title is untouched", _var_of(bob, "Title").get_string() == "Doctor")
	_check("bob's Inventory is untouched", _strings_of(_var_of(bob, "Inventory").get_array()) == ["bones"])
	_check("bob's Prices are untouched", _var_of(bob, "Prices").get_map()["ale"].get_int(-1) == 9)
	_check("bob's Brave is untouched", _var_of(bob, "Brave").get_bool(true) == false)

	# The signal: one emission per landed node write, each carrying the RESOLVED key.
	_check("four node writes emitted four signals (got %d)" % emissions.size(), emissions.size() == 4)
	var key_carrying := 0
	for emission in emissions:
		if emission[0] == FX.ALICE_KEY:
			key_carrying += 1
	_check("every signal carries the resolved record key as character_path (got %d of %d)" % [key_carrying, emissions.size()],
		key_carrying == emissions.size())
	_check("no warnings on clean id writes (got %d)" % component._context.character_id_warnings_emitted,
		component._context.character_id_warnings_emitted == 0)
	_teardown(component)


# =============================================================================
# 4. The wired override wins - including a wired id
# =============================================================================

## The wired character input is evaluated FIRST and wins outright: a DANGLING inline id
## under a healthy wire resolves the wire and warns NOTHING. And a wired value that is
## itself an id enters the same latched lane and resolves through the bridge.
func _test_wired_override_wins() -> void:
	print("-- wired override wins --")
	_import_and_install("wired", FX.index_text_valid())

	var script := Graph.build("scripts/Wired.sfe", {
		"0": Graph.start(),
		"GP": Graph.node("GP", Types.NodeType.GET_STRING, "getString", {"variable": "who_path", "isGlobal": false}),
		"GID": Graph.node("GID", Types.NodeType.GET_STRING, "getString", {"variable": "who_id", "isGlobal": false}),
		# Dangling inline id + bob decoy path, but the WIRE names alice by path.
		"G1": _gcv("G1", {"characterPath": FX.BOB_KEY, "characterId": FX.DANGLING_ID,
			"variableName": "Trust", "variableType": "integer"}),
		# No inline fields at all; the WIRE hands over alice's ID.
		"G2": _gcv("G2", {"characterPath": "", "variableName": "Trust", "variableType": "integer"}),
		"S1": Graph.node("S1", Types.NodeType.SET_INT, "setInt", {"variable": "via_path", "isGlobal": false}),
		"S2": Graph.node("S2", Types.NodeType.SET_INT, "setInt", {"variable": "via_id", "isGlobal": false}),
		"D": Graph.dialogue("D"),
	}, [
		Graph.exec("0", "S1"), Graph.exec_flow("S1", "S2"), Graph.exec_flow("S2", "D"),
		Graph.data_wire("GP", "string", "G1", Handles.IN_CHARACTER_INPUT),
		Graph.data_wire("GID", "string", "G2", Handles.IN_CHARACTER_INPUT),
		Graph.data_wire("G1", "integer", "S1", Handles.IN_INTEGER),
		Graph.data_wire("G2", "integer", "S2", Handles.IN_INTEGER),
	], {
		"who_path": Graph.scalar_var("who_path", "who_path", Types.VariableType.STRING, VariantScript.from_string(FX.ALICE_KEY)),
		"who_id": Graph.scalar_var("who_id", "who_id", Types.VariableType.STRING, VariantScript.from_string(FX.ALICE_ID)),
		"via_path": Graph.scalar_var("via_path", "via_path", Types.VariableType.INTEGER, VariantScript.from_int(-1)),
		"via_id": Graph.scalar_var("via_id", "via_id", Types.VariableType.INTEGER, VariantScript.from_int(-1)),
	})

	var component := _run(script)
	_check("a wired PATH beats a dangling inline id (alice 3, got %d)" % component.get_int_variable("via_path"),
		component.get_int_variable("via_path") == 3)
	_check("a wired ID resolves through the bridge (alice 3, got %d)" % component.get_int_variable("via_id"),
		component.get_int_variable("via_id") == 3)
	_check("wired-over-dangling never warns (got %d)" % component._context.character_id_warnings_emitted,
		component._context.character_id_warnings_emitted == 0)
	_teardown(component)


# =============================================================================
# 5. Dangling: warn-once per run, re-armed per owner
# =============================================================================

## TWO getters on the same dangling id warn ONCE (the id|reason latch), the read still
## answers its silent default, and a fresh run re-arms - the context owns the node-lane
## latch, so a new execution context warns again.
func _test_dangling_warns_once_and_rearms() -> void:
	print("-- dangling warn-once + re-arm --")
	_import_and_install("dangling", FX.index_text_valid())

	var dangle := {"characterPath": "", "characterId": FX.DANGLING_ID,
		"variableName": "Trust", "variableType": "integer"}
	var script := Graph.build("scripts/Dangling.sfe", {
		"0": Graph.start(),
		"G1": _gcv("G1", dangle),
		"G2": _gcv("G2", dangle),
		"S1": Graph.node("S1", Types.NodeType.SET_INT, "setInt", {"variable": "a", "isGlobal": false}),
		"S2": Graph.node("S2", Types.NodeType.SET_INT, "setInt", {"variable": "b", "isGlobal": false}),
		"D": Graph.dialogue("D"),
	}, [
		Graph.exec("0", "S1"), Graph.exec_flow("S1", "S2"), Graph.exec_flow("S2", "D"),
		Graph.data_wire("G1", "integer", "S1", Handles.IN_INTEGER),
		Graph.data_wire("G2", "integer", "S2", Handles.IN_INTEGER),
	], {
		"a": Graph.scalar_var("a", "a", Types.VariableType.INTEGER, VariantScript.from_int(-1)),
		"b": Graph.scalar_var("b", "b", Types.VariableType.INTEGER, VariantScript.from_int(-1)),
	})

	var component := _run(script)
	_check("a dangling id reads the silent default (got %d)" % component.get_int_variable("a"),
		component.get_int_variable("a") == 0)
	_check("two getters on one dangling id warn ONCE (got %d)" % component._context.character_id_warnings_emitted,
		component._context.character_id_warnings_emitted == 1)
	_check("under the id|dangling key",
		component._context.warned_character_ids.has("%s|dangling" % FX.DANGLING_ID))
	_teardown(component)

	# A fresh run re-arms: the latch is per-context, per-run.
	var second := _run(script)
	_check("a fresh run warns once again (got %d)" % second._context.character_id_warnings_emitted,
		second._context.character_id_warnings_emitted == 1)
	_teardown(second)


# =============================================================================
# 6. THE UNLOADED PRODUCER PIN (inheritance 5)
# =============================================================================

## A GHOST index entry through a REAL import - the index names a record characters.json
## never carried. An id-bound read falls back to its PATH field with exactly one unloaded
## warn. This is the unloaded rung's only producer: this engine's save load MERGES values
## onto declared records and never removes a character, so a load cannot manufacture it.
func _test_unloaded_producer_falls_back_to_path() -> void:
	print("-- unloaded producer (ghost index entry) --")
	_import_and_install("ghost", FX.index_text_with_ghost())
	_check("the REAL import carried the ghost entry (got '%s')" % _manager.get_character_id_bridge().get(FX.GHOST_ID, ""),
		_manager.get_character_id_bridge().get(FX.GHOST_ID, "") == FX.GHOST_KEY)
	_check("and its record is genuinely unloaded",
		not _manager.get_runtime_characters().has(FX.GHOST_KEY))

	var ghost := {"characterPath": FX.ALICE_KEY, "characterId": FX.GHOST_ID,
		"variableName": "Trust", "variableType": "integer"}
	var script := Graph.build("scripts/Ghost.sfe", {
		"0": Graph.start(),
		"G1": _gcv("G1", ghost),
		"G2": _gcv("G2", ghost),
		"S1": Graph.node("S1", Types.NodeType.SET_INT, "setInt", {"variable": "a", "isGlobal": false}),
		"S2": Graph.node("S2", Types.NodeType.SET_INT, "setInt", {"variable": "b", "isGlobal": false}),
		"D": Graph.dialogue("D"),
	}, [
		Graph.exec("0", "S1"), Graph.exec_flow("S1", "S2"), Graph.exec_flow("S2", "D"),
		Graph.data_wire("G1", "integer", "S1", Handles.IN_INTEGER),
		Graph.data_wire("G2", "integer", "S2", Handles.IN_INTEGER),
	], {
		"a": Graph.scalar_var("a", "a", Types.VariableType.INTEGER, VariantScript.from_int(-1)),
		"b": Graph.scalar_var("b", "b", Types.VariableType.INTEGER, VariantScript.from_int(-1)),
	})

	var component := _run(script)
	_check("an unloaded id falls back to the PATH field (alice 3, got %d)" % component.get_int_variable("a"),
		component.get_int_variable("a") == 3)
	_check("with exactly one unloaded warn (got %d)" % component._context.character_id_warnings_emitted,
		component._context.character_id_warnings_emitted == 1)
	_check("under the id|unloaded key",
		component._context.warned_character_ids.has("%s|unloaded" % FX.GHOST_ID))
	_teardown(component)


# =============================================================================
# 7. Id and path reach ONE record
# =============================================================================

## One state by construction: the bridge resolves to the very key the path lane normalizes
## to, so both routes hit the SAME StoryFlowCharacter object - asserted on the object
## identity directly, then behaviorally: an id-bound write is visible to a path-bound read.
func _test_id_and_path_reach_one_record() -> void:
	print("-- id and path reach one record --")
	_import_and_install("onerecord", FX.index_text_valid())

	var resolved := CharacterScript.resolve_character_key(
		_manager.get_character_id_bridge(), _manager.get_runtime_characters(), FX.ALICE_ID, null)
	_check("the resolver answers the record key verbatim (got '%s')" % resolved, resolved == FX.ALICE_KEY)
	_check("which is a normalize_path fixed point (inheritance 1)",
		CharacterScript.normalize_path(resolved) == resolved)
	_check("and both routes hit the SAME object",
		_manager.get_runtime_characters()[resolved] == _manager.get_runtime_character(FX.ALICE_KEY))

	var script := Graph.build("scripts/OneRecord.sfe", {
		"0": Graph.start(),
		# Write by ID (decoy path on board), read back by PATH.
		"W": _scv("W", {"characterPath": FX.BOB_KEY, "characterId": FX.ALICE_ID,
			"variableName": "Trust", "variableType": "integer", "value": VariantScript.from_int(21)}),
		"G": _gcv("G", {"characterPath": FX.ALICE_KEY, "variableName": "Trust", "variableType": "integer"}),
		"S": Graph.node("S", Types.NodeType.SET_INT, "setInt", {"variable": "readback", "isGlobal": false}),
		"D": Graph.dialogue("D"),
	}, [
		Graph.exec("0", "W"), Graph.exec_flow("W", "S"), Graph.exec_flow("S", "D"),
		Graph.data_wire("G", "integer", "S", Handles.IN_INTEGER),
	], {
		"readback": Graph.scalar_var("readback", "readback", Types.VariableType.INTEGER, VariantScript.from_int(-1)),
	})
	var component := _run(script)
	_check("an id-bound write is visible to a path-bound read (got %d)" % component.get_int_variable("readback"),
		component.get_int_variable("readback") == 21)
	_teardown(component)


# =============================================================================
# 8. THE PRE-P4 FULL-RUN SWEEP
# =============================================================================

## A complete scripted run over a NO-INDEX build - speaker, advance, inline write, wired
## read-into-write, an option gated on a char-var boolean, a post-option write, end - all
## through the REAL import, with authored (unnormalized) path spellings. Every value is
## pinned and BOTH warn counters stay 0: pre-P4 projects run byte-identically.
func _test_pre_p4_full_run_sweep() -> void:
	print("-- pre-P4 full-run sweep --")
	_import_and_install("prep4", null, {
		"0": {"type": "start"},
		"1": {"type": "dialogue", "text": "Hello {Character.Name}", "character": "Cast/Alice.sfc"},
		"2": {"type": "setCharacterVar", "characterPath": "Cast/Alice.sfc",
			"variable": "Trust", "variableType": "integer", "value": 5},
		"3": {"type": "getCharacterVar", "characterPath": "cast/alice.sfc",
			"variable": "Trust", "variableType": "integer"},
		"4": {"type": "setCharacterVar", "characterPath": "Cast/Bob.sfc",
			"variable": "Trust", "variableType": "integer"},
		"5": {"type": "dialogue", "text": "choose",
			"options": [{"id": "oa", "text": "brave"}, {"id": "ob", "text": "meek"}]},
		"6": {"type": "getCharacterVar", "characterPath": "cast/alice.sfc",
			"variable": "Brave", "variableType": "boolean"},
		"7": {"type": "setCharacterVar", "characterPath": "cast/alice.sfc",
			"variable": "Title", "variableType": "string", "value": "Veteran"},
		"8": {"type": "dialogue", "text": "done"},
	}, [
		FX.wire_edge("0", "source-0-", "1", "target-1-"),
		FX.wire_edge("1", "source-1-", "2", "target-2-"),
		FX.wire_edge("2", "source-2-1", "4", "target-4-"),
		FX.wire_edge("3", "source-3-integer-", "4", "target-4-integer-input"),
		FX.wire_edge("4", "source-4-1", "5", "target-5-"),
		FX.wire_edge("6", "source-6-boolean-", "5", "target-5-boolean-oa"),
		FX.wire_edge("5", "source-5-oa", "7", "target-7-"),
		FX.wire_edge("7", "source-7-1", "8", "target-8-"),
	])
	_check("a no-index build leaves the bridge empty", _manager.get_character_id_bridge().is_empty())

	var component := _start("Main")
	var state = component._context.current_dialogue_state
	_check("the speaker resolves by authored path spelling", state != null and state.character != null
		and state.character.name == "char.alice.name")
	_check("and interpolates (got '%s')" % (state.text if state else ""),
		state != null and state.text == "Hello char.alice.name")

	component.advance_dialogue()
	var alice = _manager.get_runtime_characters()[FX.ALICE_KEY]
	var bob = _manager.get_runtime_characters()[FX.BOB_KEY]
	_check("the inline write landed (alice Trust 5, got %d)" % _var_of(alice, "Trust").get_int(-1),
		_var_of(alice, "Trust").get_int(-1) == 5)
	_check("the wired read-into-write landed (bob Trust 5, got %d)" % _var_of(bob, "Trust").get_int(-1),
		_var_of(bob, "Trust").get_int(-1) == 5)

	var options := _visible_options(component)
	_check("the char-var gated option renders beside the ungated one (got %s)" % str(options),
		options == ["oa", "ob"])
	component.select_option("oa")
	_check("the post-option write landed (alice Title Veteran, got '%s')" % _var_of(alice, "Title").get_string(),
		_var_of(alice, "Title").get_string() == "Veteran")
	var final_state = component._context.current_dialogue_state
	_check("the run reached the end beat", final_state != null and final_state.text == "done")

	_check("the node-lane counter stayed 0 (got %d)" % component._context.character_id_warnings_emitted,
		component._context.character_id_warnings_emitted == 0)
	_check("the host-lane counter stayed 0 (got %d)" % _manager.character_id_access_warnings_emitted,
		_manager.character_id_access_warnings_emitted == 0)
	_teardown(component)


# =============================================================================
# Helpers
# =============================================================================

func _gcv(id: String, data: Dictionary) -> Dictionary:
	return Graph.node(id, Types.NodeType.GET_CHARACTER_VAR, "getCharacterVar", data.duplicate())


func _scv(id: String, data: Dictionary) -> Dictionary:
	return Graph.node(id, Types.NodeType.SET_CHARACTER_VAR, "setCharacterVar", data.duplicate())


func _merge(a: Dictionary, b: Dictionary) -> Dictionary:
	var merged := a.duplicate()
	merged.merge(b, true)
	return merged


## Import the decoy build through the REAL disk arm and install it on the manager.
func _import_and_install(label: String, index_text, script_nodes: Dictionary = {"0": {"type": "start"}}, connections: Array = []) -> void:
	var build := _temp("%s/build" % label)
	var out := _temp("%s/out" % label)
	FX.write_build(build, index_text, script_nodes, connections)
	var project = ImporterScript.new().import_project(build, out)
	_check("[setup] %s: import returned a project" % label, project != null)
	if project != null:
		_manager.set_project(project)


func _make_component() -> StoryFlowComponent:
	var component := ComponentScript.new()
	component.dialogue_ui_scene = null
	get_root().add_child(component)
	return component


func _start(script_path: String) -> StoryFlowComponent:
	var component := _make_component()
	component.start_dialogue_with_script(script_path)
	return component


## Register a hand-built script on the imported project and run it.
func _run(script: StoryFlowScript) -> StoryFlowComponent:
	_manager.get_project().scripts[script.script_path] = script
	return _start(script.script_path)


func _teardown(component: StoryFlowComponent) -> void:
	component.stop_dialogue()
	get_root().remove_child(component)
	component.queue_free()


func _var_of(character, variable_name: String) -> StoryFlowVariant:
	var value = character.variables.get(variable_name, {}).get("value")
	return value if value is VariantScript else VariantScript.new()


func _strings_of(elements: Array) -> Array:
	var out: Array = []
	for element in elements:
		if element is VariantScript:
			out.append(element.get_string())
	return out


func _stored_string(component: StoryFlowComponent, variable_id: String) -> String:
	var variable = component._context.local_variables.get(variable_id, {})
	var value = variable.get("value", null)
	return value.get_string() if value is VariantScript else ""


func _stored_strings(component: StoryFlowComponent, variable_id: String) -> Array:
	var variable = component._context.local_variables.get(variable_id, {})
	var value = variable.get("value", null)
	return _strings_of(value.get_array()) if value is VariantScript else []


func _visible_options(component: StoryFlowComponent) -> Array:
	var state = component._context.current_dialogue_state
	if state == null:
		return []
	var ids: Array = []
	for option in state.options:
		ids.append(option.id)
	return ids


func _temp(relative: String) -> String:
	var path := _temp_root.path_join(relative)
	DirAccess.make_dir_recursive_absolute(path)
	return path


static func _rm_rf(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name != "." and name != "..":
			var child := path.path_join(name)
			if dir.current_is_dir():
				_rm_rf(child)
			else:
				DirAccess.remove_absolute(child)
		name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)
