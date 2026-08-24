extends SceneTree
## Headless tests for the .sfd Data Asset DEGRADED LADDER (engine contract section 6), driven
## by the shared golden fixture tests/fixtures/engine-contract/data-assets-degraded.json.
##
## FIXTURES: copied verbatim from the editor repo and GENERATED there from the HTML runtime by
## src/__tests__/runtime/engine-contract-fixtures.test.ts (regenerate with REGEN_FIXTURES=1).
## Never hand-edit them here — the same files live in the Unreal and Unity plugin repos, and
## byte drift between the copies is the parity failure they exist to prevent. Every
## fixture-driven loop is COUNT-GUARDED: a fixture that silently shrinks would otherwise turn
## into a test that silently passes.
##
## WHAT IS ACTUALLY DRIVEN. Each of the 20 cases is built as a REAL StoryFlowScript — pill
## node, accessor node, wires — and read through the REAL evaluators, because the ladder's
## first rungs are questions about the GRAPH (is anything on the dataAsset pin? is it a pill?)
## that a store-level test cannot ask at all.
##  - the GET side runs per case against a fresh execution context, read TWICE, asserting the
##    outcome, the warn LATCH and the warn COUNTER delta.
##  - the SET side runs ALL 20 cases as ONE exec chain through the component's real
##    _process_node dispatch, asserting that the single healthy write survives every broken
##    case around it and that nothing else reached the overlay.
##
## WHY THE COUNTER EXISTS. Godot's push_warning cannot be captured from a SceneTree test, so
## the warning TEXT is not assertable here at all. StoryFlowExecutionContext therefore exposes
## both warned_data_asset_nodes (which reasons fired) and data_asset_warnings_emitted (how many
## times) — reading twice and asserting the delta is 1 is what separates a working once-per-node
## latch from one that re-warns on every read.
##
## Run from the repository root (import first to build the class cache):
##   godot --headless --import
##   godot --headless --script res://tests/test_data_asset_degraded.gd
## Or: powershell -File tests/run_tests.ps1 -GodotExe <path-to-godot>

const ComponentScript := preload("res://addons/storyflow/core/storyflow_component.gd")
const ContextScript := preload("res://addons/storyflow/core/storyflow_execution_context.gd")
const EvaluatorScript := preload("res://addons/storyflow/core/storyflow_evaluator.gd")
const Handles := preload("res://addons/storyflow/core/storyflow_handles.gd")
const ImporterScript := preload("res://addons/storyflow/editor/storyflow_importer.gd")
const ManagerScript := preload("res://addons/storyflow/core/storyflow_manager.gd")
const ProjectScript := preload("res://addons/storyflow/core/storyflow_project.gd")
const ScriptScript := preload("res://addons/storyflow/core/storyflow_script.gd")
const StoreScript := preload("res://addons/storyflow/core/storyflow_data_asset_store.gd")
const Types := preload("res://addons/storyflow/core/storyflow_types.gd")
const VariantScript := preload("res://addons/storyflow/core/storyflow_variant.gd")

const FIXTURE_DIR := "res://tests/fixtures/engine-contract"

const CHILD := "da_1b2c3d4e5f60718293a4b5c6d7e8f90a"
const V_HP := "2e8b6d0a1f4c47d3b95e2a70c6f81d34"

## Node ids inside every generated per-case script.
const PILL := "P"
const ACCESSOR := "G"
const CONSUMER := "C"

var _checks: int = 0
var _failures: int = 0

var _importer = null
var _seed: Dictionary = {}


func _initialize() -> void:
	await process_frame
	_importer = ImporterScript.new()
	_seed = _seed_from_fixture()

	var cases := _fixture_cases()
	_check("degraded fixture carries all 20 cases (got %d)" % cases.size(), cases.size() == 20)

	_test_get_side(cases)
	_test_set_side(cases)

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
# The GET side
# =============================================================================

## Every case's read, against a FRESH execution context so the warn counter delta belongs to
## that case alone. Read TWICE on purpose: once proves the value, twice proves the latch.
func _test_get_side(cases: Array) -> void:
	print("-- degraded ladder: reads --")
	var covered := 0
	for entry in cases:
		var case_name: String = entry.get("case", "")
		var accessor: Dictionary = entry.get("accessor", {})
		var expectation: Dictionary = entry.get("get", {})

		var script := _build_read_script(entry)
		var context := ContextScript.new()
		context.current_script = script
		# The store handoff a real dialogue gets at start_dialogue_with_script. The overlay
		# stays empty: every expected value here is a seed value or a type default.
		context.data_asset_seed = _seed
		context.data_asset_overlay = {}
		var evaluator := EvaluatorScript.new()
		evaluator.initialize(context, {}, {}, "en", {})

		var first = _read_accessor(evaluator, accessor)
		var warned_after_first: int = context.data_asset_warnings_emitted
		var second = _read_accessor(evaluator, accessor)

		var expected = expectation.get("value")
		_check("%s: get answers %s" % [case_name, JSON.stringify(expected)], _value_matches(accessor, first, expected))
		_check("%s: the second read answers the same thing" % case_name, _value_matches(accessor, second, expected))

		var warns_once: bool = entry.get("warnOnce", false)
		if warns_once:
			var reason: String = entry.get("set", {}).get("reason", "")
			_check("%s: warns once, and only once, across two reads" % case_name,
				warned_after_first == 1 and context.data_asset_warnings_emitted == 1)
			_check("%s: the latch names the '%s' rung" % [case_name, reason],
				context.warned_data_asset_nodes.has("%s|%s" % [ACCESSOR, reason]))
		else:
			_check("%s: a healthy read warns about nothing" % case_name,
				context.data_asset_warnings_emitted == 0)
		covered += 1

	_check("every one of the 20 cases was read (got %d)" % covered, covered == 20)

	# Re-arming (contract section 6: latches reset on a game restart). reset() rebinds the
	# store references to fresh empties, so re-arming is asserted on the LATCH itself.
	var rearm_case := _find_case(cases, "dead-reference")
	var rearm_script := _build_read_script(rearm_case)
	var rearm_context := ContextScript.new()
	rearm_context.current_script = rearm_script
	rearm_context.data_asset_seed = _seed
	rearm_context.data_asset_overlay = {}
	var rearm_evaluator := EvaluatorScript.new()
	rearm_evaluator.initialize(rearm_context, {}, {}, "en", {})
	_read_accessor(rearm_evaluator, rearm_case.get("accessor", {}))
	_read_accessor(rearm_evaluator, rearm_case.get("accessor", {}))
	_check("latched once before the reset", rearm_context.data_asset_warnings_emitted == 1)
	rearm_context.reset()
	_check("reset drops the latch", rearm_context.warned_data_asset_nodes.is_empty() and rearm_context.data_asset_warnings_emitted == 0)
	rearm_context.current_script = rearm_script
	rearm_context.data_asset_seed = _seed
	rearm_context.data_asset_overlay = {}
	_read_accessor(rearm_evaluator, rearm_case.get("accessor", {}))
	_check("the warning re-arms for the next run", rearm_context.data_asset_warnings_emitted == 1)


# =============================================================================
# The SET side
# =============================================================================

## All 20 Set nodes on ONE exec chain, through the component's real dispatch table. The point
## is the survival property: the single healthy write must land regardless of the 19 broken
## accessors it is chained between, and none of those 19 may leave anything in the overlay.
func _test_set_side(cases: Array) -> void:
	print("-- degraded ladder: writes --")

	var project := ProjectScript.new()
	project.data_assets = _raw_data_assets()
	project.scripts["scripts/Degraded.sfe"] = _build_write_chain_script(cases)

	var manager := ManagerScript.new()
	manager.name = "StoryFlowRuntime"
	root.add_child(manager)
	manager.set_project(project)

	var component := ComponentScript.new()
	component.dialogue_ui_scene = null
	root.add_child(component)
	component.start_dialogue_with_script("scripts/Degraded.sfe")

	var overlay: Dictionary = manager.get_data_asset_overlay()
	_check("only the healthy write reached the overlay (1 asset table, got %d)" % overlay.size(), overlay.size() == 1)
	_check("and it landed on the asset the healthy pill names", overlay.has(CHILD))
	var child_table: Dictionary = overlay.get(CHILD, {})
	_check("with exactly one entry (got %d)" % child_table.size(), child_table.size() == 1)
	var written = child_table.get(V_HP, null)
	_check("carrying the fixture's written value 42", written != null and written.get_int() == 42)

	# 18 of the 20 cases carry warnOnce; the other two are the healthy control and the
	# value-pin refusal, whose warning is deliberately NOT latched (contract section 6, last
	# row). One warning per broken node, and the counter is what proves the "once".
	var expected_latched := 0
	for entry in cases:
		if entry.get("warnOnce", false):
			expected_latched += 1
	_check("18 of the 20 cases latch a ladder warning (fixture says %d)" % expected_latched, expected_latched == 18)
	_check("the chain latched exactly one warning per broken Set (got %d)" % component._context.data_asset_warnings_emitted,
		component._context.data_asset_warnings_emitted == expected_latched)

	component.stop_dialogue()
	component.queue_free()
	manager.queue_free()


# =============================================================================
# Graph construction
# =============================================================================

## The per-case READ graph: the accessor, whatever is (or is not) on its dataAsset pin, and a
## consumer node for the container reads, which are pulled through an input edge rather than
## from the node directly.
func _build_read_script(entry: Dictionary) -> StoryFlowScript:
	var accessor: Dictionary = entry.get("accessor", {})
	var script := ScriptScript.new()
	script.script_path = "scripts/Read.sfe"
	script.nodes = {
		ACCESSOR: _node(ACCESSOR, Types.NodeType.GET_DATA_ASSET_VARIABLE, "getDataAssetVariable", accessor.duplicate()),
		CONSUMER: _node(CONSUMER, Types.NodeType.ARRAY_LENGTH_STRING, "arrayLength", {
			"keyType": str(accessor.get("keyType", "")),
			"valueType": str(accessor.get("valueType", "")),
		}),
	}
	script.connections = []
	_wire_pill(script, entry, ACCESSOR)
	# The container consumer's input edge. Harmless for scalar cases — nothing reads it.
	if bool(accessor.get("isArray", false)):
		var array_suffix: String = "%s-array" % str(accessor.get("variableType", ""))
		script.connections.append(_edge("c", ACCESSOR, "source-%s-%s-" % [ACCESSOR, array_suffix], CONSUMER, Handles.target(CONSUMER, array_suffix)))
	elif str(accessor.get("variableType", "")) == "map":
		var map_suffix := Handles.in_map(str(accessor.get("keyType", "")), str(accessor.get("valueType", "")), "1")
		script.connections.append(_edge("c", ACCESSOR, "source-%s-map-%s-%s" % [ACCESSOR, str(accessor.get("keyType", "")), str(accessor.get("valueType", ""))], CONSUMER, Handles.target(CONSUMER, map_suffix)))
	script.build_indices()
	return script


## All 20 Set nodes chained exec-out to exec-in, parked on a dialogue node at the end so the
## execution context stays alive for the assertions.
func _build_write_chain_script(cases: Array) -> StoryFlowScript:
	var script := ScriptScript.new()
	script.script_path = "scripts/Degraded.sfe"
	# The two value sources every wired value pin in the fixture needs. Local script
	# variables, so the Set nodes read a real evaluated value rather than a literal.
	script.variables = {
		"v_int": {"id": "v_int", "name": "n", "type": Types.VariableType.INTEGER, "value": VariantScript.from_int(42)},
		"v_str": {"id": "v_str", "name": "s", "type": Types.VariableType.STRING, "value": VariantScript.from_string("x")},
	}
	script.nodes = {
		"0": _node("0", Types.NodeType.START, "start", {}),
		"VI": _node("VI", Types.NodeType.GET_INT, "getInt", {"variable": "v_int", "isGlobal": false}),
		"VS": _node("VS", Types.NodeType.GET_STRING, "getString", {"variable": "v_str", "isGlobal": false}),
		"D": _node("D", Types.NodeType.DIALOGUE, "dialogue", {"title": "", "text": "done"}),
	}
	script.connections = []

	var previous_handle := Handles.source("0")
	for index in cases.size():
		var entry: Dictionary = cases[index]
		var accessor: Dictionary = entry.get("accessor", {})
		var setter_id := "S%d" % index
		script.nodes[setter_id] = _node(setter_id, Types.NodeType.SET_DATA_ASSET_VARIABLE, "setDataAssetVariable", accessor.duplicate())
		script.connections.append(_edge("x%d" % index, "", previous_handle, setter_id, Handles.target(setter_id)))
		_wire_pill(script, entry, setter_id)
		if entry.get("setValuePinWired", false):
			var variable_type := str(accessor.get("variableType", ""))
			var source_id := "VS" if variable_type == "string" else "VI"
			var source_handle := "source-%s-%s-" % [source_id, variable_type]
			script.connections.append(_edge("v%d" % index, source_id, source_handle, setter_id, Handles.target(setter_id, Handles.in_data_asset_value(variable_type, false))))
		previous_handle = Handles.source(setter_id, Handles.OUT_FLOW)

	script.connections.append(_edge("done", "", previous_handle, "D", Handles.target("D")))
	# The connection helper needs a real source id for the exec edges it just built.
	for connection in script.connections:
		if connection["source"].is_empty():
			connection["source"] = Handles.parse(connection["source_handle"]).get("node_id", "")
	script.build_indices()
	return script


## Whatever the case says sits on the accessor's dataAsset pin: a bound pill, an unbound pill,
## a node that is not a pill at all, or nothing.
func _wire_pill(script: StoryFlowScript, entry: Dictionary, target_id: String) -> void:
	if not entry.get("pillWired", false):
		return
	var pill_id := "%s_%s" % [PILL, target_id]
	if entry.get("pillIsRefNode", false):
		script.nodes[pill_id] = _node(pill_id, Types.NodeType.GET_DATA_ASSET, "getDataAsset", {"assetId": str(entry.get("pillAssetId", ""))})
	else:
		# A node that is NOT a getDataAsset pill, carrying an assetId anyway — the arm must
		# refuse to read data off it rather than trusting whatever is on the far end.
		script.nodes[pill_id] = _node(pill_id, Types.NodeType.GET_INT, "getInt", {"assetId": str(entry.get("pillAssetId", ""))})
	script.connections.append(_edge("p_%s" % target_id, pill_id, "source-%s-dataAsset-" % pill_id, target_id, Handles.target(target_id, Handles.IN_DATA_ASSET)))


func _node(id: String, node_type: Types.NodeType, type_string: String, data: Dictionary) -> Dictionary:
	return {"id": id, "type": node_type, "type_string": type_string, "data": data}


func _edge(id: String, source: String, source_handle: String, target: String, target_handle: String) -> Dictionary:
	return {"id": id, "source": source, "target": target, "source_handle": source_handle, "target_handle": target_handle}


# =============================================================================
# Reads + comparisons
# =============================================================================

## Read the accessor the way a real graph would: the typed evaluator its variableType selects,
## and for containers the input-edge readers a consumer node uses.
func _read_accessor(evaluator, accessor: Dictionary):
	var variable_type := str(accessor.get("variableType", ""))
	if variable_type == "map":
		var map_result: Dictionary = evaluator.resolve_map_input(_map_consumer(accessor), "1")
		var map = map_result.get("map")
		return map if map is Dictionary else {}
	if bool(accessor.get("isArray", false)):
		return evaluator.evaluate_string_array_input(CONSUMER, "%s-array" % variable_type)
	match variable_type:
		"boolean":
			return evaluator.evaluate_boolean_from_node(ACCESSOR, "")
		"integer":
			return evaluator.evaluate_integer_from_node(ACCESSOR, "")
		"float":
			return evaluator.evaluate_float_from_node(ACCESSOR, "")
		_:
			# string / enum / image / character / audio all read through the string evaluator.
			return evaluator.evaluate_string_from_node(ACCESSOR, "")


func _map_consumer(accessor: Dictionary) -> Dictionary:
	return _node(CONSUMER, Types.NodeType.MAP_SIZE, "mapSize", {
		"keyType": str(accessor.get("keyType", "")),
		"valueType": str(accessor.get("valueType", "")),
	})


## Compare a read against the fixture's expected JSON value. Containers are compared by SIZE:
## every container expectation in this fixture is the empty default, and an empty entry list
## and an empty array are the only two shapes it can take.
func _value_matches(accessor: Dictionary, actual, expected) -> bool:
	var variable_type := str(accessor.get("variableType", ""))
	if variable_type == "map":
		return actual is Dictionary and actual.size() == (expected as Array).size()
	if bool(accessor.get("isArray", false)):
		return actual is Array and actual.size() == (expected as Array).size()
	match variable_type:
		"boolean":
			return actual == bool(expected)
		"integer":
			return actual == int(expected)
		"float":
			# JSON cannot express 0.0 distinctly (contract section 9.1), so the fixture
			# carries float defaults as 0 and typed harnesses coerce.
			return is_equal_approx(actual, float(expected))
		_:
			return actual == str(expected)


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


func _fixture_cases() -> Array:
	return _load_fixture("data-assets-degraded.json").get("cases", [])


func _find_case(cases: Array, case_name: String) -> Dictionary:
	for entry in cases:
		if entry.get("case", "") == case_name:
			return entry
	return {}


## The raw seed table, parsed through the REAL importer helper — the same path a shipped game
## takes, so the declarations the ladder matches against are the ones the importer produces.
func _raw_data_assets() -> Dictionary:
	return _importer._parse_data_assets(_load_fixture("data-assets-seed.json").get("dataAssets", {}))


func _seed_from_fixture() -> Dictionary:
	var project = ProjectScript.new()
	project.data_assets = _raw_data_assets()
	var seed: Dictionary = {}
	StoreScript.build_seed(project, seed)
	return seed
