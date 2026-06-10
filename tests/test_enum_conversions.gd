extends SceneTree
## Headless tests for the intToEnum / stringToEnum conversion nodes.
##
## Covers two bugs:
##   1. The importer's _parse_node_data() whitelist dropped "enumValues",
##      so node-level enum value lists never survived import.
##   2. Enum inputs are pulled through evaluate_string_from_node(), which had
##      no INT_TO_ENUM / STRING_TO_ENUM arms, so the conversions always
##      produced "" (the dedicated evaluate_enum_from_node() had no callers).
##      Editor exports also carry no data on conversion nodes at all - the
##      enum values must be resolved from the downstream node, matching the
##      HTML runtime.
##
## Run from the repository root (import first to build the class cache):
##   godot --headless --import
##   godot --headless --script res://tests/test_enum_conversions.gd
## Or: powershell -File tests/run_tests.ps1 -GodotExe <path-to-godot>

const ImporterScript := preload("res://addons/storyflow/editor/storyflow_importer.gd")
const ManagerScript := preload("res://addons/storyflow/core/storyflow_manager.gd")

const ENUM_VALUES := ["apple", "banana", "cherry"]

var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	await process_frame

	_run_import_tests()
	_run_runtime_tests()

	if _failures == 0:
		print("ALL %d CHECKS PASSED" % _checks)
	else:
		print("%d OF %d CHECKS FAILED" % [_failures, _checks])
	quit(1 if _failures > 0 else 0)


# =============================================================================
# Import Tests (whitelist)
# =============================================================================

func _run_import_tests() -> void:
	var json := _build_script_json(
		{"type": "intToEnum", "data": {"value": 2, "enumValues": ENUM_VALUES}},
		{"id": "var1", "name": "result", "type": "enum", "value": ""}
	)
	# Variable-backed enum nodes carry a denormalized copy of the variable's
	# values in their data in the editor's .sfe format - cover that shape too.
	json["nodes"]["1"]["data"]["enumValues"] = ENUM_VALUES

	var importer := ImporterScript.new()
	var sf_script: StoryFlowScript = importer.import_script(_json_round_trip(json))
	_check("import: script parsed", sf_script != null)
	if sf_script == null:
		return

	var conv_data: Dictionary = sf_script.get_node("2").get("data", {})
	_check("import: intToEnum node keeps enumValues",
		conv_data.get("enumValues", []) == ENUM_VALUES)

	var set_data: Dictionary = sf_script.get_node("1").get("data", {})
	_check("import: setEnum node keeps enumValues",
		set_data.get("enumValues", []) == ENUM_VALUES)


# =============================================================================
# Runtime Tests (end-to-end: import -> run graph -> setEnum result)
# =============================================================================

func _run_runtime_tests() -> void:
	var bare_var := {"id": "var1", "name": "result", "type": "enum", "value": ""}
	var var_with_values := {
		"id": "var1", "name": "result", "type": "enum",
		"value": "apple", "enumValues": ENUM_VALUES,
	}

	# enumValues stored on the conversion node itself (hand-authored JSON).
	_run_case("intToEnum, own enumValues, index 2",
		_build_script_json({"type": "intToEnum", "data": {"value": 2, "enumValues": ENUM_VALUES}}, bare_var),
		"cherry")

	# Editor exports write conversion nodes with no data - the values come
	# from the variable of the downstream setEnum node (HTML runtime parity).
	_run_case("intToEnum, downstream variable enumValues, index 1",
		_build_script_json({"type": "intToEnum", "data": {"value": 1}}, var_with_values),
		"banana")

	# Out-of-range index clamps to the last value.
	_run_case("intToEnum, index clamped",
		_build_script_json({"type": "intToEnum", "data": {"value": 99, "enumValues": ENUM_VALUES}}, bare_var),
		"cherry")

	# stringToEnum passes a matching value through.
	_run_case("stringToEnum, matching value",
		_build_script_json({"type": "stringToEnum", "data": {"value": "banana", "enumValues": ENUM_VALUES}}, bare_var),
		"banana")

	# stringToEnum falls back to the first value when nothing matches.
	_run_case("stringToEnum, no match falls back to first",
		_build_script_json({"type": "stringToEnum", "data": {"value": "durian", "enumValues": ENUM_VALUES}}, bare_var),
		"apple")


## Import the script JSON, run the graph start -> setEnum -> end, and assert
## the value the setEnum node stored into the "result" variable.
func _run_case(case_name: String, script_json: Dictionary, expected: String) -> void:
	var importer := ImporterScript.new()
	var sf_script: StoryFlowScript = importer.import_script(_json_round_trip(script_json))
	_check("%s: script imported" % case_name, sf_script != null)
	if sf_script == null:
		return
	sf_script.script_path = "test"

	var project := StoryFlowProject.new()
	project.scripts["test"] = sf_script

	var mgr: Node = root.get_node_or_null("StoryFlowRuntime")
	if mgr == null:
		mgr = ManagerScript.new()
		mgr.name = "StoryFlowRuntime"
		root.add_child(mgr)
	mgr.set_project(project)

	var component := StoryFlowComponent.new()
	component.trace_enabled = false
	root.add_child(component)

	var captured: Array = []
	component.variable_changed.connect(func(info: StoryFlowVariableChangeInfo) -> void:
		if info.name == "result":
			captured.append(info.value.get_string() if info.value else "")
	)

	component.start_dialogue_with_script("test")

	var got: String = captured.back() if captured.size() > 0 else "<no variable_changed>"
	_check("%s: expected \"%s\", got \"%s\"" % [case_name, expected, got], got == expected)

	root.remove_child(component)
	component.free()


# =============================================================================
# Helpers
# =============================================================================

## Minimal script graph: start(0) -> setEnum(1) -> end(3), with the conversion
## node (2) wired into the setEnum's enum input.
func _build_script_json(conversion_node: Dictionary, variable: Dictionary) -> Dictionary:
	return {
		"nodes": {
			"0": {"type": "start"},
			"1": {"type": "setEnum", "data": {"variable": "var1", "isGlobal": false}},
			"2": conversion_node,
			"3": {"type": "end"},
		},
		"connections": [
			{"id": "c1", "source": "0", "target": "1", "sourceHandle": "source-0-", "targetHandle": "target-1-"},
			{"id": "c2", "source": "2", "target": "1", "sourceHandle": "source-2-enum-2", "targetHandle": "target-1-enum-1"},
			{"id": "c3", "source": "1", "target": "3", "sourceHandle": "source-1-1", "targetHandle": "target-3-"},
		],
		"variables": {"var1": variable},
	}


## Serialize and reparse so fixtures arrive exactly as real JSON files do
## (string keys, numbers as floats, no GDScript-only types).
func _json_round_trip(data: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(data))


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  PASS: %s" % label)
	else:
		_failures += 1
		printerr("  FAIL: %s" % label)
