extends SceneTree
## Array nodes and long loops held to the StoryFlow Editor's own runtime.
##
##   G1  Set Array Element takes its array over the input edge, as the export writes it, and
##       writes the changed array back to the variable behind that edge.
##   G2  Set Array with nothing wired into its array input keeps the variable's value.
##   G3  A For Each walks the array as it was when the loop began, whatever its body does to it.
##   G4  A long For Each reaches Completed: iterations do not pile up on the call stack.
##   G5  Arrays cross a wire as copies: Set Array, array ops, Run Script parameters and outputs.
##   G6  A walk that runs out of connections leaves the line it started from usable.
##   G7  An exit flow whose route is not connected in the caller stays in the called script.
##   G8  Add To String Array adds the wired value even when it is empty.
##   G10 Run Script and Run Flow report a Start with nothing connected, and a flow that has no
##       entry, with the editor's messages. Only the exact id "start" means the Start flow.
##   G11 A Run Script parameter with nothing wired passes its type's empty value; a map passes nothing.
##   G12 Run Script without a script and Run Flow without a flow only warn, at the nesting limit
##       too; a missing script and a story whose Start has nothing connected are errors.
##   G9  A local and a global that share an id (the export derives ids from names): the node's
##       isGlobal flag alone picks the scope, for reads, writes and the change event.
##
## Graphs are written in the exported JSON dialect and go through the importer.

const Component = preload("res://addons/storyflow/core/storyflow_component.gd")
const Importer = preload("res://addons/storyflow/editor/storyflow_importer.gd")
const Manager = preload("res://addons/storyflow/core/storyflow_manager.gd")

var checks := 0
var failures := 0
var manager: Node
var errors: Array = []


func _initialize() -> void:
	await process_frame
	manager = Manager.new()
	manager.name = "StoryFlowRuntime"
	root.add_child(manager)
	_test_set_array_element()
	_test_set_array_unwired()
	_test_loop_walks_a_copy()
	_test_arrays_cross_as_copies()
	_test_add_wired_empty_string()
	_test_scope_follows_the_flag()
	_test_flow_and_script_entry_errors()
	_test_unwired_parameters()
	_test_diagnostics()
	for rollback in [false, true]:
		for loop_kind in ["array", "map"]:
			_test_long_loop(rollback, loop_kind)
		_test_dead_end_keeps_the_line(rollback)
		_test_exit_flow_route(rollback)
	print("Array node parity: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)


func _expect(label: String, actual, expected) -> void:
	checks += 1
	if actual != expected:
		failures += 1
		printerr("FAIL: %s\n  expected %s\n  got      %s" % [label, expected, actual])


# =============================================================================
# G1. Set Array Element
# =============================================================================

func _test_set_array_element() -> void:
	# main: Set <Type> Array Element(Items, index 1 = inline value) -> Done
	for case in [
			["Bool", "boolean", [false, false, false], true, [false, true, false]],
			["Int", "integer", [1, 2, 3], 99, [1, 99, 3]],
			["Float", "float", [1.5, 2.5, 3.5], 9.5, [1.5, 9.5, 3.5]],
			["String", "string", ["a", "b", "c"], "new", ["a", "new", "c"]],
			["Image", "image", ["a", "b", "c"], "new", ["a", "new", "c"]],
			["Character", "character", ["a", "b", "c"], "new", ["a", "new", "c"]],
			["Audio", "audio", ["a", "b", "c"], "new", ["a", "new", "c"]]]:
		var family: String = case[0]
		var type: String = case[1]
		var main := _script(
			[_node("items", "get%sArray" % family, {"variable": "items"}),
				_node("element", "set%sArrayElement" % family, {"value1": 1, "value2": case[3]}), _line("Done")],
			[_flow("0", "", "element"), _flow("element", "1", "Done"),
				_data("items", type + "-array-", "element", type + "-array-2")],
			[_variable("items", type, case[2], {"isArray": true})])
		var component = _start({"main.json": main})
		_expect("G1 Set %s Array Element writes the inline value at the inline index" % family,
			[_line_id(component), _local(component, "items"), errors], ["Done", case[4], []])
		_dispose(component)

	# The index and the value over their own pins, and an index outside the array.
	for case in [[2, [1, 2, 7]], [5, [1, 2, 3]]]:
		var main := _script(
			[_node("items", "getIntArray", {"variable": "items"}), _node("at", "getInt", {"variable": "at"}),
				_node("seven", "getInt", {"variable": "seven"}),
				_node("element", "setIntArrayElement", {"value1": 0, "value2": 0}), _line("Done")],
			[_flow("0", "", "element"), _flow("element", "1", "Done"),
				_data("items", "integer-array-", "element", "integer-array-2"),
				_data("at", "integer-", "element", "integer-3"), _data("seven", "integer-", "element", "integer-4")],
			[_variable("items", "integer", [1, 2, 3], {"isArray": true}), _variable("at", "integer", case[0]), _variable("seven", "integer", 7)])
		var component = _start({"main.json": main})
		_expect("G1 Set Int Array Element with index %d and value 7 wired in" % case[0],
			[_line_id(component), _local(component, "items"), errors], ["Done", case[1], []])
		_dispose(component)


# =============================================================================
# G2. Set Array with nothing wired
# =============================================================================

func _test_set_array_unwired() -> void:
	# main: Set Int Array(Keep) -> Done, with and without an array wired in.
	for wired in [false, true]:
		var edges := [_flow("0", "", "set"), _flow("set", "1", "Done")]
		if wired:
			edges.append(_data("source", "integer-array-", "set", "integer-array-2"))
		var main := _script(
			[_node("source", "getIntArray", {"variable": "source"}), _node("set", "setIntArray", {"variable": "keep"}), _line("Done")],
			edges, [_variable("keep", "integer", [4, 5], {"isArray": true}), _variable("source", "integer", [1, 2, 3], {"isArray": true})])
		var component = _start({"main.json": main})
		_expect("G2 Set Int Array %s" % ("takes the wired array" if wired else "with nothing wired keeps its value"),
			[_line_id(component), _local(component, "keep"), errors], ["Done", [1, 2, 3] if wired else [4, 5], []])
		_dispose(component)


# =============================================================================
# G3. A For Each walks the array as it was when the loop began
# =============================================================================

func _test_loop_walks_a_copy() -> void:
	# main: For Each(Numbers = 1, 2) -> Add To Array(Log, element) -> change Numbers, Completed -> Done.
	for case in [["Clear Array", _node("change", "clearIntArray"), []], ["Add To Array", _node("change", "addToIntArray", {"value": 9}), [1, 2, 9, 9]]]:
		var main := _script(
			[_node("numbers", "getIntArray", {"variable": "numbers"}), _node("loop", "forEachIntLoop"),
				_node("logArray", "getIntArray", {"variable": "log"}), _node("log", "addToIntArray"), case[1], _line("Done")],
			[_flow("0", "", "loop"), _flow("loop", "loopBody", "log"), _flow("log", "1", "change"), _flow("loop", "completed", "Done"),
				_data("numbers", "integer-array-", "loop", "integer-array-array"),
				_data("logArray", "integer-array-", "log", "integer-array-2"), _data("loop", "integer-element", "log", "integer-3"),
				_data("numbers", "integer-array-", "change", "integer-array-2")],
			[_variable("numbers", "integer", [1, 2], {"isArray": true}), _variable("log", "integer", [], {"isArray": true})])
		var component = _start({"main.json": main})
		_expect("G3 a body that runs %s on the walked array: both elements run and the variable takes the change" % case[0],
			[_line_id(component), _local(component, "log"), _local(component, "numbers"), errors], ["Done", [1, 2], case[2], []])
		_dispose(component)


# =============================================================================
# G4. A long For Each
# =============================================================================

func _test_long_loop(rollback: bool, loop_kind: String) -> void:
	# main: For Each(600 entries) -> Set Int(Last = entry) -> Set Int(Count = Count + 1), Completed -> Done.
	var numbers := []
	var pairs := []
	for i in 600:
		numbers.append(i)
		pairs.append({"key": "k%d" % i, "value": i})
	var is_map := loop_kind == "map"
	var types := {"keyType": "string", "valueType": "integer"}
	var entries := _variable("numbers", "map", pairs, types) if is_map else _variable("numbers", "integer", numbers, {"isArray": true})
	var main := _script(
		[_node("numbers", "getMap", _with({"variable": "numbers"}, types)) if is_map else _node("numbers", "getIntArray", {"variable": "numbers"}),
			_node("loop", "forEachMap", types) if is_map else _node("loop", "forEachIntLoop"),
			_node("last", "setInt", {"variable": "last"}),
			_node("count", "getInt", {"variable": "count"}), _node("plus", "plus", {"value2": 1}), _node("bump", "setInt", {"variable": "count"}),
			_line("Done")],
		[_flow("0", "", "loop"), _flow("loop", "loopBody", "last"), _flow("last", "1", "bump"), _flow("loop", "completed", "Done"),
			_data("numbers", "map-string-integer-", "loop", "map-string-integer-map") if is_map else _data("numbers", "integer-array-", "loop", "integer-array-array"),
			_data("loop", "integer-value" if is_map else "integer-element", "last", "integer-2"),
			_data("count", "integer-", "plus", "integer-1"), _data("plus", "integer-", "bump", "integer-2")],
		[entries, _variable("last", "integer", -1), _variable("count", "integer", 0)])
	var component = _start({"main.json": main}, rollback)
	var active: bool = component.is_dialogue_active()
	_expect("G4 rollback %s: a %s For Each over 600 entries runs every one and takes Completed" % ["on" if rollback else "off", loop_kind],
		[_line_id(component), _local(component, "last") if active else null, _local(component, "count") if active else null, errors],
		["Done", 599, 600, []])
	_dispose(component)


# =============================================================================
# G5. Arrays cross a wire as copies
# =============================================================================

func _test_arrays_cross_as_copies() -> void:
	# main: Set Int Array(Copy = Source) -> Add To Array(Source, 9) -> Done
	var main := _script(
		[_node("source", "getIntArray", {"variable": "source"}), _node("set", "setIntArray", {"variable": "copy"}),
			_node("add", "addToIntArray", {"value": 9}), _line("Done")],
		[_flow("0", "", "set"), _flow("set", "1", "add"), _flow("add", "1", "Done"),
			_data("source", "integer-array-", "set", "integer-array-2"), _data("source", "integer-array-", "add", "integer-array-2")],
		[_variable("copy", "integer", [], {"isArray": true}), _variable("source", "integer", [1, 2, 3], {"isArray": true})])
	var component = _start({"main.json": main})
	_expect("G5 Set Int Array takes a copy: a later change to the source leaves it alone",
		[_line_id(component), _local(component, "copy"), _local(component, "source"), errors], ["Done", [1, 2, 3], [1, 2, 3, 9], []])
	_dispose(component)

	# main: Run Script(sub, Items = Numbers) -> Done. sub: Add To Array(Items, 9) -> End
	main = _script(
		[_node("numbers", "getIntArray", {"variable": "numbers"}),
			_node("call", "runScript", {"script": "sub.json", "scriptInterface": {"parameters": [{"id": "p", "name": "items", "type": "integer", "isArray": true}]}}),
			_line("Done")],
		[_flow("0", "", "call"), _flow("call", "output", "Done"), _data("numbers", "integer-array-", "call", "integer-array-param-p")],
		[_variable("numbers", "integer", [1, 2, 3], {"isArray": true})])
	var sub := _script(
		[_node("items", "getIntArray", {"variable": "items"}), _node("subAdd", "addToIntArray", {"value": 9}), _node("subEnd", "end")],
		[_flow("0", "", "subAdd"), _flow("subAdd", "1", "subEnd"), _data("items", "integer-array-", "subAdd", "integer-array-2")],
		[_variable("items", "integer", [], {"isArray": true, "isInput": true})])
	component = _start({"main.json": main, "sub.json": sub})
	_expect("G5 an array parameter is a copy: the called script cannot change the caller's array",
		[_line_id(component), _local(component, "numbers"), errors], ["Done", [1, 2, 3], []])
	_dispose(component)

	# main: Run Script(sub) -> Add To Array(sub's Result, 9) -> Set Int Array(Copy = sub's Result) -> Done. sub: End
	main = _script(
		[_node("call", "runScript", {"script": "sub.json", "scriptInterface": {"outputs": [{"id": "o", "name": "result", "type": "integer", "isArray": true}]}}),
			_node("add", "addToIntArray", {"value": 9}), _node("set", "setIntArray", {"variable": "copy"}), _line("Done")],
		[_flow("0", "", "call"), _flow("call", "output", "add"), _flow("add", "1", "set"), _flow("set", "1", "Done"),
			_data("call", "integer-array-out-o", "add", "integer-array-2"), _data("call", "integer-array-out-o", "set", "integer-array-2")],
		[_variable("copy", "integer", [], {"isArray": true})])
	sub = _script([_node("subEnd", "end")], [_flow("0", "", "subEnd")], [_variable("result", "integer", [1, 2], {"isArray": true, "isOutput": true})])
	component = _start({"main.json": main, "sub.json": sub})
	_expect("G5 an array op works on a copy of its input: a Run Script output is not changed by it",
		[_line_id(component), _local(component, "copy"), errors], ["Done", [1, 2], []])
	_dispose(component)


# =============================================================================
# G8. Add To String Array with an empty wired value
# =============================================================================

func _test_add_wired_empty_string() -> void:
	# main: Add To String Array(Items, value wired from the empty Blank, inline value "inline") -> Done
	for wired in [true, false]:
		var edges := [_flow("0", "", "add"), _flow("add", "1", "Done"), _data("items", "string-array-", "add", "string-array-2")]
		if wired:
			edges.append(_data("blank", "string-", "add", "string-3"))
		var main := _script(
			[_node("items", "getStringArray", {"variable": "items"}), _node("blank", "getString", {"variable": "blank"}),
				_node("add", "addToStringArray", {"value": "inline"}), _line("Done")],
			edges, [_variable("items", "string", [], {"isArray": true}), _variable("blank", "string", "")])
		var component = _start({"main.json": main})
		_expect("G8 Add To String Array adds %s" % ("the wired value, empty as it is" if wired else "its inline value with nothing wired"),
			[_line_id(component), _local(component, "items"), errors], ["Done", [""] if wired else ["inline"], []])
		_dispose(component)


# =============================================================================
# G9. A local and a global that share an id
# =============================================================================

func _test_scope_follows_the_flag() -> void:
	# main: Set Int(global Shared = 5) -> Set Int(local Shared = 7) -> Set Int(local FromGlobal = global Shared)
	# -> Set Int(local FromLocal = local Shared) -> Add To Array(global List, 1) -> Add To Array(local List, 2) -> Done
	var main := _script(
		[_node("setGlobal", "setInt", {"variable": "var_shared", "isGlobal": true, "value": 5}),
			_node("setLocal", "setInt", {"variable": "var_shared", "value": 7}),
			_node("getGlobal", "getInt", {"variable": "var_shared", "isGlobal": true}), _node("getLocal", "getInt", {"variable": "var_shared"}),
			_node("copyGlobal", "setInt", {"variable": "from_global"}), _node("copyLocal", "setInt", {"variable": "from_local"}),
			_node("listGlobal", "getIntArray", {"variable": "var_list", "isGlobal": true}), _node("listLocal", "getIntArray", {"variable": "var_list"}),
			_node("addGlobal", "addToIntArray", {"value": 1}), _node("addLocal", "addToIntArray", {"value": 2}), _line("Done")],
		[_flow("0", "", "setGlobal"), _flow("setGlobal", "1", "setLocal"), _flow("setLocal", "1", "copyGlobal"), _flow("copyGlobal", "1", "copyLocal"),
			_flow("copyLocal", "1", "addGlobal"), _flow("addGlobal", "1", "addLocal"), _flow("addLocal", "1", "Done"),
			_data("getGlobal", "integer-", "copyGlobal", "integer-2"), _data("getLocal", "integer-", "copyLocal", "integer-2"),
			_data("listGlobal", "integer-array-", "addGlobal", "integer-array-2"), _data("listLocal", "integer-array-", "addLocal", "integer-array-2")],
		[_variable("var_shared", "integer", 0), _variable("var_list", "integer", [], {"isArray": true}),
			_variable("from_global", "integer", 0), _variable("from_local", "integer", 0)])
	var project = Importer.new().import_project_from_json({"version": "1.0", "startupScript": "main.json", "scripts": {"main.json": main},
		"globalVariables": {"var_shared": _variable("var_shared", "integer", 0), "var_list": _variable("var_list", "integer", [], {"isArray": true})}})
	manager.set_project(project)
	var component = Component.new()
	component.trace_enabled = false
	root.add_child(component)
	var changes := []
	component.variable_changed.connect(func(info): changes.append([info.id, info.is_global]))
	component.start_dialogue_with_script("main")
	var globals: Dictionary = manager.get_global_variables()
	_expect("G9 nodes flagged global read and write the global, unflagged ones the local of the same id",
		[globals["var_shared"].value.get_int(), _local(component, "var_shared"), _local(component, "from_global"), _local(component, "from_local"),
			globals["var_list"].value.get_array().size(), _local(component, "var_list")],
		[5, 7, 5, 7, 1, [2]])
	_expect("G9 each change event reports the scope the node named", changes,
		[["var_shared", true], ["var_shared", false], ["from_global", false], ["from_local", false], ["var_list", true], ["var_list", false]])
	_dispose(component)


# =============================================================================
# G10. Entry errors
# =============================================================================

func _test_flow_and_script_entry_errors() -> void:
	# main: line A, Go -> Run Script(hollow). hollow: a Start with nothing connected.
	var main := _script(
		[_node("A", "dialogue", {"text": "A", "choices": [{"id": "go", "text": "go"}]}), _node("call", "runScript", {"script": "hollow.json"})],
		[_flow("0", "", "A"), _flow("A", "go", "call")])
	var component = _start({"main.json": main, "hollow.json": _script([_line("Unreached")], [])})
	component.select_option("go")
	_expect("G10 Run Script into a script whose Start has nothing connected reports it", errors, ["Script's Start node is not connected"])
	_dispose(component)

	# main: line A, Go -> Run Flow. The flow has no Entry Flow node, under an unknown id and under "Start".
	for flow_id in ["side", "Start"]:
		main = _script(
			[_node("A", "dialogue", {"text": "A", "choices": [{"id": "go", "text": "go"}]}), _node("jump", "runFlow", {"flowId": flow_id})],
			[_flow("0", "", "A"), _flow("A", "go", "jump")])
		main["flows"] = [{"id": "side", "name": "Side"}]
		component = _start({"main.json": main})
		component.select_option("go")
		_expect("G10 Run Flow to \"%s\" without an Entry Flow reports the flow as not found" % flow_id,
			[errors, component._context.flow_call_stack.size()], [['Flow "%s" not found' % ("Side" if flow_id == "side" else flow_id)], 0])
		_dispose(component)

	# A script whose Start has nothing connected never walks, so the Run Flow is entered directly.
	main = _script([_node("jump", "runFlow", {"flowId": "start"})], [])
	component = _start({"main.json": main})
	errors = []
	component._process_node(component._context.current_script.get_node("jump"))
	_expect("G10 Run Flow to the Start flow with nothing connected to Start reports it",
		[errors, component._context.flow_call_stack.size()], [["Start node is not connected"], 0])
	_dispose(component)


# =============================================================================
# G11. Run Script parameters with nothing wired
# =============================================================================

func _test_unwired_parameters() -> void:
	# main: Run Script(sub) with every parameter left unwired. sub: line S, its inputs declared non-empty.
	var declared := {"boolean": true, "integer": 7, "float": 1.5, "string": "x", "enum": "x", "image": "x", "audio": "x",
		"character": "x", "dataAsset": "x"}
	var parameters := [{"id": "p_map", "name": "map", "type": "map"}]
	var inputs := [_variable("map", "map", [{"key": "a", "value": 1}], {"keyType": "string", "valueType": "integer", "isInput": true})]
	for type in declared:
		parameters.append({"id": "p_" + type, "name": type, "type": type})
		inputs.append(_variable(type, type, declared[type], {"isInput": true}))
		if type != "enum":
			parameters.append({"id": "pa_" + type, "name": type + "s", "type": type, "isArray": true})
			inputs.append(_variable(type + "s", type, [declared[type]], {"isArray": true, "isInput": true}))
	var main := _script([_node("call", "runScript", {"script": "sub.json", "scriptInterface": {"parameters": parameters}})], [_flow("0", "", "call")])
	var component = _start({"main.json": main, "sub.json": _script([_line("S")], [_flow("0", "", "S")], inputs)})
	var passed := {}
	for type in declared:
		passed[type] = _local(component, type)
	_expect("G11 unwired scalar parameters pass false, 0, 0.0 and empty text", [_line_id(component), passed, errors],
		["S", {"boolean": false, "integer": 0, "float": 0.0, "string": "", "enum": "", "image": "", "audio": "", "character": "", "dataAsset": ""}, []])
	var lists := {}
	var empty_lists := {}
	for type in declared:
		if type != "enum":
			lists[type] = _local(component, type + "s")
			empty_lists[type] = []
	_expect("G11 an unwired array parameter of every type passes an empty array", lists, empty_lists)
	_expect("G11 an unwired map parameter leaves the declared map",
		component._context.local_variables["map"].value.get_map().size(), 1)
	_dispose(component)


# =============================================================================
# G12. Diagnostics
# =============================================================================

func _test_diagnostics() -> void:
	# main: line A, Go -> the node under test.
	for case in [
			["Run Script with no script selected only warns", _node("tail", "runScript"), []],
			["Run Flow with no flow selected only warns", _node("tail", "runFlow"), []],
			["Run Script to a script that does not exist is an error", _node("tail", "runScript", {"script": "missing.json"}), ["Script not found: missing"]]]:
		var main := _script(
			[_node("A", "dialogue", {"text": "A", "choices": [{"id": "go", "text": "go"}]}), case[1]],
			[_flow("0", "", "A"), _flow("A", "go", "tail")])
		var component = _start({"main.json": main})
		component.select_option("go")
		_expect("G12 " + case[0], [_line_id(component), errors], ["A", case[2]])
		_dispose(component)

	var component = _start({"main.json": _script([_line("Unreached")], [])})
	_expect("G12 starting a story whose Start has nothing connected is an error", errors, ["Start node is not connected"])
	_dispose(component)

	# main: line A. Deeper -> Run Script(main), Go -> Run Script with no script. The missing script
	# is looked at before the nesting limit, so at the limit it still only warns.
	var nested := _script(
		[_node("A", "dialogue", {"text": "A", "choices": [{"id": "deeper", "text": "deeper"}, {"id": "go", "text": "go"}]}),
			_node("again", "runScript", {"script": "main.json"}), _node("tail", "runScript")],
		[_flow("0", "", "A"), _flow("A", "deeper", "again"), _flow("A", "go", "tail")])
	component = _start({"main.json": nested})
	for depth in 20:
		component.select_option("deeper")
	component.select_option("go")
	_expect("G12 Run Script with no script selected only warns at the nesting limit too",
		[component._context.call_stack.size(), errors], [20, []])
	_dispose(component)


# =============================================================================
# G6. A walk that runs out of connections leaves its line usable
# =============================================================================

func _test_dead_end_keeps_the_line(rollback: bool) -> void:
	# main: line A -> Set Int(Count = Count + 1) -> tail, with nothing connected after the tail.
	for tail in [
			_node("tail", "switchOnEnum", {"variable": "mode"}), _node("tail", "randomBranch", {"options": [{"id": "only", "weight": 1}]}),
			_node("tail", "runScript", {"script": "empty.json"}), _node("tail", "blockRollback"), _node("tail", "branch", {"value": true}),
			_node("tail", "setBackgroundImage"), _node("tail", "playAudio"), _node("tail", "setInt", {"variable": "other", "value": 1})]:
		var main := _script(
			[_line("A"), _node("count", "getInt", {"variable": "count"}), _node("plus", "plus", {"value2": 1}),
				_node("bump", "setInt", {"variable": "count"}), tail],
			[_flow("0", "", "A"), _flow("A", "", "bump"), _flow("bump", "1", "tail"),
				_data("count", "integer-", "plus", "integer-1"), _data("plus", "integer-", "bump", "integer-2")],
			[_variable("count", "integer", 0), _variable("other", "integer", 0), _variable("mode", "enum", "x", {"enumValues": ["x"]})])
		var component = _start({"main.json": main, "empty.json": _script([_node("emptyEnd", "end")], [_flow("0", "", "emptyEnd")])}, rollback)
		var steps := []
		for step in 2:
			component.advance_dialogue()
			steps.append([_line_id(component), component.is_waiting_for_input(), _local(component, "count")])
		_expect("G6 rollback %s: a walk ending on %s leaves line A accepting input" % ["on" if rollback else "off", tail.type],
			[steps, errors], [[["A", true, 1], ["A", true, 2]], []])
		_dispose(component)


# =============================================================================
# G7. An exit flow whose route is not connected
# =============================================================================

## sub: line S. Leave -> Run Flow(exit flow Out). Go -> For Each(1, 2, 3) -> Add To Array(Log, entry)
## -> Run Flow(Out). Other -> Set Int.
func _exiting_script() -> Dictionary:
	var sub := _script(
		[_node("S", "dialogue", {"text": "S", "choices": [{"id": "leave", "text": "leave"}, {"id": "go", "text": "go"}, {"id": "other", "text": "other"}]}),
			_node("exit", "runFlow", {"flowId": "out"}), _node("loopExit", "runFlow", {"flowId": "out"}),
			_node("numbers", "getIntArray", {"variable": "numbers"}), _node("loop", "forEachIntLoop"),
			_node("logArray", "getIntArray", {"variable": "log"}), _node("log", "addToIntArray"),
			_node("otherSet", "setInt", {"variable": "scratch", "value": 1})],
		[_flow("0", "", "S"), _flow("S", "leave", "exit"), _flow("S", "go", "loop"), _flow("S", "other", "otherSet"),
			_flow("loop", "loopBody", "log"), _flow("log", "1", "loopExit"),
			_data("numbers", "integer-array-", "loop", "integer-array-array"),
			_data("logArray", "integer-array-", "log", "integer-array-2"), _data("loop", "integer-element", "log", "integer-3")],
		[_variable("numbers", "integer", [1, 2, 3], {"isArray": true}), _variable("log", "integer", [], {"isArray": true}), _variable("scratch", "integer", 0)])
	sub["flows"] = [{"id": "out", "name": "Out", "isExit": true}]
	return sub


func _test_exit_flow_route(rollback: bool) -> void:
	# main: Run Script(sub) -> Default, and the exit route -> Route when connected.
	var mode := "on" if rollback else "off"
	for connected in [false, true]:
		var edges := [_flow("0", "", "call"), _flow("call", "output", "Default")]
		if connected:
			edges.append(_flow("call", "exit-out", "Route"))
		var main := _script([_node("call", "runScript", {"script": "sub.json"}), _line("Default"), _line("Route")], edges)
		var component = _start({"main.json": main, "sub.json": _exiting_script()}, rollback)
		component.select_option("leave")
		_expect("G7 rollback %s: an exit flow with its route %s" % [mode, "connected returns through it" if connected else "not connected stays on its line"],
			[_line_id(component), component.is_waiting_for_input(), component._context.call_stack.size(), errors],
			["Route", true, 0, []] if connected else ["S", true, 1, []])
		_dispose(component)

	# Staying leaves the called script as it stands, its loop included: the next chain that runs out
	# of connections carries that loop on to its next entry.
	var stay_main := _script([_node("call", "runScript", {"script": "sub.json"}), _line("Default")], [_flow("0", "", "call"), _flow("call", "output", "Default")])
	var staying = _start({"main.json": stay_main, "sub.json": _exiting_script()}, rollback)
	var steps := []
	for option in ["go", "other"]:
		staying.select_option(option)
		steps.append([_line_id(staying), staying.is_waiting_for_input(), _local(staying, "log")])
	_expect("G7 rollback %s: an exit flow that stays inside a loop body keeps that loop" % mode,
		[steps, errors], [[["S", true, [1]], ["S", true, [1, 2]]], []])
	_dispose(staying)


# =============================================================================
# The exported JSON dialect and the harness
# =============================================================================

func _script(nodes: Array, connections: Array, variables: Array = []) -> Dictionary:
	var by_id := {"0": {"type": "start", "id": "0"}}
	for node in nodes:
		by_id[node.id] = node
	var declared := {}
	for variable in variables:
		declared[variable.id] = variable
	return {"startNode": "0", "nodes": by_id, "connections": connections, "variables": declared}


func _node(id: String, type: String, fields: Dictionary = {}) -> Dictionary:
	var node := {"type": type, "id": id}
	node.merge(fields)
	return node


func _line(id: String) -> Dictionary:
	return _node(id, "dialogue", {"text": id, "choices": []})


func _variable(id: String, type: String, value, extra: Dictionary = {}) -> Dictionary:
	var variable := {"id": id, "name": id, "type": type, "value": value}
	variable.merge(extra)
	return variable


func _with(base: Dictionary, changes: Dictionary) -> Dictionary:
	var result := base.duplicate()
	result.merge(changes, true)
	return result


func _flow(source: String, output: String, target: String) -> Dictionary:
	return _data(source, output, target, "0")


func _data(source: String, output: String, target: String, input: String) -> Dictionary:
	return {"id": "%s-%s-%s-%s" % [source, output, target, input], "source": source, "target": target,
		"sourceHandle": "source-%s-%s" % [source, output], "targetHandle": "target-%s-%s" % [target, input]}


func _start(scripts: Dictionary, rollback: bool = false):
	var project = Importer.new().import_project_from_json({
		"version": "1.0", "startupScript": "main.json",
		"metadata": {"dialogueRollback": {"version": 1, "enabled": rollback, "historyLimit": 100}},
		"scripts": scripts})
	manager.set_project(project)
	var component = Component.new()
	component.trace_enabled = false
	root.add_child(component)
	errors = []
	component.error_occurred.connect(func(message): errors.append(message))
	component.start_dialogue_with_script(project.startup_script)
	return component


func _dispose(component) -> void:
	component.stop_dialogue()
	root.remove_child(component)
	component.free()


func _line_id(component) -> String:
	var dialogue = component.get_current_dialogue()
	return dialogue.node_id if dialogue else ""


## A local variable as plain values: an array as a list, a scalar as itself.
func _local(component, id: String):
	var record: Dictionary = component._context.local_variables[id]
	if not record.get("is_array", false):
		return _plain(record.value)
	var values := []
	for element in record.value.get_array():
		values.append(_plain(element))
	return values


func _plain(value):
	match value.type:
		1: return value.get_bool()
		2: return value.get_int()
		3: return value.get_float()
	return value.get_string()
