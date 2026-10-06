extends SceneTree
## For Each loops held to the StoryFlow Editor's own runtime, with dialogue rollback off and on.
##
##   B1  A loop body that reaches a node with nothing connected after it has finished that
##       iteration: the loop moves on to its next entry and finally takes Completed. That holds
##       for every exec node a body can end on, in array loops and in map loops.
##   B2  A called script that returns through End from inside its own loop leaves that loop: the
##       next call runs it from its first entry. A loop of the caller keeps its place meanwhile.
##   B3  A save made while a called script is paused inside the caller's loop. Saves carry no
##       script position and Load is refused while a dialogue runs, so the walk just carries on.
##   B4  No loop position survives a Load, a reset or a restart of the story.
##   B5  Save and Load right after a choice that ran such a loop.
##
## Graphs are written in the exported JSON dialect and go through the importer, with node ids
## unique across scripts as the exporter guarantees.

const Component = preload("res://addons/storyflow/core/storyflow_component.gd")
const Importer = preload("res://addons/storyflow/editor/storyflow_importer.gd")
const Manager = preload("res://addons/storyflow/core/storyflow_manager.gd")

const SLOT := "loop_parity"
const ARRAY_FAMILIES := {"Bool": "boolean", "Int": "integer", "Float": "float", "String": "string",
	"Image": "image", "Character": "character", "DataAsset": "dataAsset", "Audio": "audio"}

var checks := 0
var failures := 0
var manager: Node
var errors: Array = []


func _initialize() -> void:
	await process_frame
	manager = Manager.new()
	manager.name = "StoryFlowRuntime"
	root.add_child(manager)
	for rollback in [false, true]:
		for loop_kind in ["array", "map"]:
			_test_body_ends(rollback, loop_kind)
			_test_unconnected_body(rollback, loop_kind)
			_test_end_inside_own_loop(rollback, loop_kind)
		_test_nested_loops(rollback)
		_test_walk_ends_outside_a_loop(rollback)
		_test_unconnected_option_in_loop_body(rollback)
		_test_line_in_called_script(rollback)
		_test_caller_loop_keeps_its_place(rollback)
		_test_shared_nested_loops_graph(rollback)
		_test_script_calling_itself(rollback)
		_test_save_inside_called_script(rollback)
		_test_load_reset_and_restart(rollback)
		_test_save_and_load_after_loop(rollback)
	manager.delete_save(SLOT)
	print("Loop parity: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)


func _expect(label: String, actual, expected) -> void:
	checks += 1
	if actual != expected:
		failures += 1
		printerr("FAIL: %s\n  expected %s\n  got      %s" % [label, expected, actual])


func _mode(rollback: bool) -> String:
	return "rollback on" if rollback else "rollback off"


# =============================================================================
# B1. A body that ends on a node with nothing connected after it
# =============================================================================

func _test_body_ends(rollback: bool, loop_kind: String) -> void:
	for tail in _tails():
		var component = _start(_tail_story(tail, loop_kind), rollback)
		component.select_option("go")
		_expect("B1 %s, %s loop, body ends on %s: every entry runs and Completed is taken" % [_mode(rollback), loop_kind, tail.name],
			_state(component), {"script": "main", "line": "A", "log": [1, 2], "done": 1, "open_loops": 0, "errors": []})
		_dispose(component)


## Outside a loop the same nodes simply end the walk on their line, as they always did.
func _test_walk_ends_outside_a_loop(rollback: bool) -> void:
	for tail in _tails():
		# main: line A, Go -> tail, Next -> B.
		var main := _script(
			tail.nodes + [_line("A", ["go", "next"]), _line("B"), tail.node],
			tail.edges + [_flow("0", "", "A"), _flow("A", "go", "tail"), _flow("A", "next", "B")],
			tail.variables, tail.flows)
		var component = _start({"main.json": main, "empty.json": _empty()}, rollback)
		component.select_option("go")
		_expect("B1 %s, %s outside a loop: the walk ends on its line" % [_mode(rollback), tail.name],
			_state(component), {"script": "main", "line": "A", "log": [], "done": 0, "open_loops": 0, "errors": []})
		_dispose(component)


## A For Each whose Loop Body output has nothing connected still walks its entries and takes
## Completed.
func _test_unconnected_body(rollback: bool, loop_kind: String) -> void:
	var main := _script(
		_loop_nodes("loop", loop_kind, "entries") + [_line("A", ["go"]), _node("done", "setInt", {"variable": "done", "isGlobal": true, "value": 1})],
		_loop_edges("loop", loop_kind) + [_flow("0", "", "A"), _flow("A", "go", "loop"), _flow("loop", "completed", "done")],
		[_entries("entries", loop_kind, [1, 2])])
	var component = _start({"main.json": main}, rollback)
	component.select_option("go")
	_expect("B1 %s, %s loop with nothing connected to Loop Body: Completed is taken" % [_mode(rollback), loop_kind],
		_state(component), {"script": "main", "line": "A", "log": [], "done": 1, "open_loops": 0, "errors": []})
	_dispose(component)


## An inner loop with nothing connected to Completed hands each finished run back to the outer
## loop. Log shows the order: each outer entry, then the inner entries.
func _test_nested_loops(rollback: bool) -> void:
	for kinds in [["array", "array"], ["array", "map"], ["map", "array"], ["map", "map"]]:
		var outer_kind: String = kinds[0]
		var inner_kind: String = kinds[1]
		var main := _script(
			_loop_nodes("outer", outer_kind, "outerEntries") + _loop_nodes("inner", inner_kind, "innerEntries") + [
				_line("A", ["go"]),
				_node("outerLogArray", "getIntArray", {"variable": "log", "isGlobal": true}), _node("outerLog", "addToIntArray"),
				_node("innerLogArray", "getIntArray", {"variable": "log", "isGlobal": true}), _node("innerLog", "addToIntArray"),
				_node("done", "setInt", {"variable": "done", "isGlobal": true, "value": 1})],
			_loop_edges("outer", outer_kind) + _loop_edges("inner", inner_kind) + [
				_flow("0", "", "A"), _flow("A", "go", "outer"),
				_flow("outer", "loopBody", "outerLog"), _flow("outerLog", "1", "inner"), _flow("outer", "completed", "done"),
				_flow("inner", "loopBody", "innerLog"),
				_data("outerLogArray", "integer-array-", "outerLog", "integer-array-2"), _entry_edge("outer", outer_kind, "outerLog", "integer-3"),
				_data("innerLogArray", "integer-array-", "innerLog", "integer-array-2"), _entry_edge("inner", inner_kind, "innerLog", "integer-3")],
			[_entries("outerEntries", outer_kind, [1, 2]), _entries("innerEntries", inner_kind, [7, 8])])
		var component = _start({"main.json": main}, rollback)
		component.select_option("go")
		_expect("B1 %s, %s loop inside a %s loop, inner Completed unconnected: the outer loop goes on" % [_mode(rollback), inner_kind, outer_kind],
			_state(component), {"script": "main", "line": "A", "log": [1, 7, 8, 2, 7, 8], "done": 1, "open_loops": 0, "errors": []})
		_dispose(component)


## This plugin also runs a line inside a loop body, which the editor's runtime refuses. A choice
## with nothing connected is not a finished iteration: it stays a dead end that keeps the line,
## as it is outside a loop.
func _test_unconnected_option_in_loop_body(rollback: bool) -> void:
	# main: For Each (1, 2) -> Pick (options Take and Stay), Take -> Add To Array(Log, entry), Completed -> Done.
	var main := _script(
		_loop_nodes("loop", "array", "entries") + [
			_line("Pick", ["take", "stay"]),
			_node("logArray", "getIntArray", {"variable": "log", "isGlobal": true}), _node("log", "addToIntArray"),
			_line("Done")],
		_loop_edges("loop", "array") + [
			_flow("0", "", "loop"), _flow("loop", "loopBody", "Pick"), _flow("Pick", "take", "log"), _flow("loop", "completed", "Done"),
			_data("logArray", "integer-array-", "log", "integer-array-2"), _entry_edge("loop", "array", "log", "integer-3")],
		[_entries("entries", "array", [1, 2])])
	var component = _start({"main.json": main}, rollback)
	var steps := []
	for option in ["stay", "take", "stay", "take"]:
		component.select_option(option)
		steps.append([_at(component), _global("log"), component._context.loop_stack.size()])
	_expect("%s: a choice with nothing connected keeps its line inside a loop body" % _mode(rollback), [steps, errors],
		[[[["main", "Pick"], [], 1], [["main", "Pick"], [1], 1], [["main", "Pick"], [1], 1], [["main", "Done"], [1, 2], 0]], []])
	_dispose(component)


## The same line in a script called from a For Each body: the called script's loop finishes
## while the caller's loop is parked, and Next returns into the caller's next entry.
func _test_line_in_called_script(rollback: bool) -> void:
	for tail in _tails():
		if tail.name not in ["Set Int", "Set Background Image", "Play Audio", "Random Branch whose selected output is unconnected",
				"Switch On Enum with no output for the value", "Run Script whose output is unconnected"]:
			continue
		var main := _script(
			_loop_nodes("outer", "array", "outerEntries") + [
				_node("call", "runScript", {"script": "sub.json"}),
				_node("after", "setInt", {"variable": "step", "value": 1})],
			_loop_edges("outer", "array") + [_flow("0", "", "outer"), _flow("outer", "loopBody", "call"), _flow("call", "output", "after")],
			[_entries("outerEntries", "array", [1, 2, 3]), _variable("step", "integer", 0)])
		var scripts := _tail_story(tail, "array", _node("subEnd", "end"))
		scripts["sub.json"] = scripts["main.json"]
		scripts["main.json"] = main
		var component = _start(scripts, rollback)
		var line := {"script": "sub", "line": "A", "done": 1, "open_loops": 0, "errors": []}
		var steps := []
		for option in ["go", "go", "next"]:
			component.select_option(option)
			steps.append(_state(component))
		_expect("B1 %s, line in a script called from a For Each body, body ends on %s" % [_mode(rollback), tail.name], steps,
			[_with(line, {"log": [1, 2]}), _with(line, {"log": [1, 2, 1, 2]}), _with(line, {"log": [1, 2, 1, 2]})])
		_expect("B1 %s, body ends on %s: Next returned into the caller's loop, which called the script again" % [_mode(rollback), tail.name],
			component._context.call_stack.size(), 1)
		_dispose(component)


# =============================================================================
# B2. End inside a called script's own loop
# =============================================================================

func _test_end_inside_own_loop(rollback: bool, loop_kind: String) -> void:
	# main: A -> Run Script(scan) -> B -> Run Script(scan) -> C
	var main := _script(
		[_line("A"), _node("first", "runScript", {"script": "scan.json"}), _line("B"),
			_node("second", "runScript", {"script": "scan.json"}), _line("C")],
		[_flow("0", "", "A"), _flow("A", "", "first"), _flow("first", "output", "B"), _flow("B", "", "second"), _flow("second", "output", "C")])
	var component = _start({"main.json": main, "scan.json": _scan(loop_kind)}, rollback)
	component.advance_dialogue()
	_expect("B2 %s, %s loop: the first call returns from inside its loop" % [_mode(rollback), loop_kind],
		[_at(component), _global("log")], [["main", "B"], [1, 2]])
	component.advance_dialogue()
	_expect("B2 %s, %s loop: the next call runs the loop from its first entry" % [_mode(rollback), loop_kind],
		[_at(component), _global("log"), errors], [["main", "C"], [1, 2, 1, 2], []])
	_dispose(component)


func _test_caller_loop_keeps_its_place(rollback: bool) -> void:
	# main: A -> Run Script(chapter) -> B
	# chapter: For Each (10, 20, 30) -> Add To Array(Log, entry) -> Run Script(scan) -> Set Int, Completed -> End
	var main := _script(
		[_line("A"), _node("call", "runScript", {"script": "chapter.json"}), _line("B")],
		[_flow("0", "", "A"), _flow("A", "", "call"), _flow("call", "output", "B")])
	var chapter := _script(
		_loop_nodes("outer", "array", "tens") + [
			_node("noteArray", "getIntArray", {"variable": "log", "isGlobal": true}), _node("note", "addToIntArray"),
			_node("chapterCall", "runScript", {"script": "scan.json"}),
			_node("chapterAfter", "setInt", {"variable": "chapterStep", "value": 1}),
			_node("chapterEnd", "end")],
		_loop_edges("outer", "array") + [
			_flow("0", "", "outer"), _flow("outer", "loopBody", "note"), _flow("note", "1", "chapterCall"),
			_flow("chapterCall", "output", "chapterAfter"), _flow("outer", "completed", "chapterEnd"),
			_data("noteArray", "integer-array-", "note", "integer-array-2"), _entry_edge("outer", "array", "note", "integer-3")],
		[_entries("tens", "array", [10, 20, 30]), _variable("chapterStep", "integer", 0)])
	var component = _start({"main.json": main, "chapter.json": chapter, "scan.json": _scan("array")}, rollback)
	component.advance_dialogue()
	_expect("B2 %s: a loop parked in the caller keeps its place while each call starts the left loop afresh" % _mode(rollback),
		[_at(component), _global("log"), errors], [["main", "B"], [10, 1, 2, 20, 1, 2, 30, 1, 2], []])
	_dispose(component)

	# What the caller's nodes put out is the caller's too: a line in the called script clears
	# the called script's outputs, not these.
	# main: Add To Array(Log, 5) -> Run Script(sub) -> Set Int Array(Copy = the Add node's result) -> Done
	main = _script(
		[_node("logArray", "getIntArray", {"variable": "log", "isGlobal": true}), _node("add", "addToIntArray", {"value": 5}),
			_node("call", "runScript", {"script": "sub.json"}), _node("copy", "setIntArray", {"variable": "copy", "isGlobal": true}), _line("Done")],
		[_flow("0", "", "add"), _flow("add", "1", "call"), _flow("call", "output", "copy"), _flow("copy", "1", "Done"),
			_data("logArray", "integer-array-", "add", "integer-array-2"), _data("add", "integer-array-", "copy", "integer-array-2")])
	component = _start({"main.json": main, "sub.json": _visit()}, rollback, [_variable("copy", "integer", [], {"isArray": true})])
	component.advance_dialogue()
	_expect("B2 %s: a node output of the caller is still there after a called script paused on a line" % _mode(rollback),
		[_at(component), _global("copy"), errors], [["main", "Done"], [5], []])
	_dispose(component)


## The shared nested-loops conformance graph: an array loop around a map loop around a Run Script
## that pauses on a line, with nothing connected to the inner Completed. The caller's parked
## cursors step through every pair with rollback off as they do with it on.
func _test_shared_nested_loops_graph(rollback: bool) -> void:
	var fixture := "res://tests/fixtures/dialogue-rollback-v1/nested-loops/"
	var scripts := {}
	for file in ["main.json", "sub.json"]:
		scripts[file] = JSON.parse_string(FileAccess.get_file_as_string(fixture + file))
	var component = _start(scripts, rollback)
	var steps := []
	for step in 5:
		var cursors := []
		if not component._context.call_stack.is_empty():
			for frame in component._context.call_stack.back().saved_loop_stack:
				cursors.append(frame.current_index)
		steps.append([_at(component), cursors])
		component.advance_dialogue()
	_expect("B2 %s: the shared nested-loops graph visits every pair and takes Completed" % _mode(rollback), [steps, errors],
		[[[["sub", "Visit"], [0, 0]], [["sub", "Visit"], [0, 1]], [["sub", "Visit"], [1, 0]], [["sub", "Visit"], [1, 1]], [["main", "Done"], []]], []])
	_dispose(component)


func _test_script_calling_itself(rollback: bool) -> void:
	# main: A -> Run Script(walk) -> B
	# walk: For Each (1, 2) -> Add To Array(Log, entry) -> Branch(Inner): false -> Set Bool(Inner = true)
	# -> Run Script(walk) -> Set Int, true -> End. The inner call returns on its first entry, then
	# the outer call on its second.
	var main := _script(
		[_line("A"), _node("call", "runScript", {"script": "walk.json"}), _line("B")],
		[_flow("0", "", "A"), _flow("A", "", "call"), _flow("call", "output", "B")])
	var walk := _script(
		_loop_nodes("walkLoop", "array", "walkEntries") + [
			_node("walkLogArray", "getIntArray", {"variable": "log", "isGlobal": true}), _node("walkLog", "addToIntArray"),
			_node("walkInner", "getBool", {"variable": "inner", "isGlobal": true}),
			_node("walkGate", "branch"),
			_node("walkMark", "setBool", {"variable": "inner", "isGlobal": true, "value": true}),
			_node("walkAgain", "runScript", {"script": "walk.json"}),
			_node("walkAfter", "setInt", {"variable": "walkStep", "value": 1}),
			_node("walkEnd", "end")],
		_loop_edges("walkLoop", "array") + [
			_flow("0", "", "walkLoop"), _flow("walkLoop", "loopBody", "walkLog"), _flow("walkLog", "1", "walkGate"),
			_flow("walkGate", "false", "walkMark"), _flow("walkMark", "1", "walkAgain"), _flow("walkAgain", "output", "walkAfter"),
			_flow("walkGate", "true", "walkEnd"),
			_data("walkInner", "boolean-", "walkGate", "boolean-condition"),
			_data("walkLogArray", "integer-array-", "walkLog", "integer-array-2"), _entry_edge("walkLoop", "array", "walkLog", "integer-3")],
		[_entries("walkEntries", "array", [1, 2]), _variable("walkStep", "integer", 0)])
	var component = _start({"main.json": main, "walk.json": walk}, rollback, [_variable("inner", "boolean", false)])
	component.advance_dialogue()
	_expect("B2 %s: a script that calls itself from inside its loop, the inner End leaves the caller's place alone" % _mode(rollback),
		[_at(component), _global("log"), errors], [["main", "B"], [1, 1, 2], []])
	_dispose(component)


# =============================================================================
# B3. A save made inside a script called from a For Each body
# =============================================================================

func _test_save_inside_called_script(rollback: bool) -> void:
	# main: For Each (1, 2, 3) -> Run Script(sub) -> Set Int(Last = entry), Completed -> Done.
	# sub: Visit -> End.
	var main := _script(
		_loop_nodes("loop", "array", "entries") + [
			_node("call", "runScript", {"script": "sub.json"}),
			_node("after", "setInt", {"variable": "last", "isGlobal": true}),
			_line("Done")],
		_loop_edges("loop", "array") + [
			_flow("0", "", "loop"), _flow("loop", "loopBody", "call"), _flow("loop", "completed", "Done"),
			_flow("call", "output", "after"), _entry_edge("loop", "array", "after", "integer-2")],
		[_entries("entries", "array", [1, 2, 3])])
	var scripts := {"main.json": main, "sub.json": _visit()}
	var globals := [_variable("last", "integer", 0)]

	var component = _start(scripts, rollback, globals)
	var plain := [_position(component)]
	for step in 3:
		component.advance_dialogue()
		plain.append(_position(component))
	_expect("B3 %s: every iteration and Completed play without Save or Load" % _mode(rollback),
		[plain, errors], [[["sub", "Visit", 0], ["sub", "Visit", 1], ["sub", "Visit", 2], ["main", "Done", 3]], []])
	_dispose(component)

	component = _start(scripts, rollback, globals)
	component.advance_dialogue()
	var saved: bool = manager.save_to_slot(SLOT)
	# The plugin's saves hold variables, characters, used options and Data Asset writes, never a
	# script position, and its Load refuses to run while a dialogue is active.
	var loaded: bool = manager.load_from_slot(SLOT)
	var after_load := [_position(component)]
	for step in 2:
		component.advance_dialogue()
		after_load.append(_position(component))
	_expect("B3 %s: Save succeeds and Load is refused while the called script is paused in the caller's loop" % _mode(rollback),
		[saved, loaded], [true, false])
	_expect("B3 %s: the remaining iterations and Completed play after Save and the refused Load" % _mode(rollback),
		[after_load, errors], [[["sub", "Visit", 1], ["sub", "Visit", 2], ["main", "Done", 3]], []])
	_dispose(component)


# =============================================================================
# B4. No loop position survives a Load, a reset or a restart
# =============================================================================

func _test_load_reset_and_restart(rollback: bool) -> void:
	# main: A -> Run Script(chapter) -> B -> Run Script(chapter) -> C
	# chapter: For Each (1, 2, 3) -> Run Script(sub) -> Set Int, Completed -> End. sub: Visit -> End.
	# One Visit line per iteration, so the lines shown count the iterations that ran.
	var chapter := _script(
		_loop_nodes("loop", "array", "entries") + [
			_node("chapterCall", "runScript", {"script": "sub.json"}),
			_node("chapterAfter", "setInt", {"variable": "chapterStep", "value": 1}),
			_node("chapterEnd", "end")],
		_loop_edges("loop", "array") + [
			_flow("0", "", "loop"), _flow("loop", "loopBody", "chapterCall"), _flow("loop", "completed", "chapterEnd"),
			_flow("chapterCall", "output", "chapterAfter")],
		[_entries("entries", "array", [1, 2, 3]), _variable("chapterStep", "integer", 0)])
	var visiting := {"main.json": _story_around(), "chapter.json": chapter, "sub.json": _visit()}

	var component = _start(visiting, rollback)
	var saved: bool = manager.save_to_slot(SLOT)
	component.advance_dialogue()
	component.advance_dialogue()
	var inside := _at(component)
	component.stop_dialogue()
	var loaded: bool = manager.load_from_slot(SLOT)
	component.start_dialogue_with_script("main")
	var restarted := _at(component)
	component.advance_dialogue()
	_expect("B4 %s: Load taken while the loop is parked, its next run plays every iteration" % _mode(rollback),
		[saved, inside, loaded, restarted, _visits(component), _at(component), errors],
		[true, ["sub", "Visit"], true, ["main", "A"], 3, ["main", "B"], []])
	_dispose(component)

	component = _start(visiting, rollback)
	component.advance_dialogue()
	component.advance_dialogue()
	manager.reset_all_state()
	var after_reset := _at(component)
	var remaining := _visits(component)
	var after_first_run := _at(component)
	component.advance_dialogue()
	_expect("B4 %s: a reset from the called script, the loop runs on to its end and its next run plays every iteration" % _mode(rollback),
		[after_reset, remaining, after_first_run, _visits(component), _at(component), errors],
		[["sub", "Visit"], 2, ["main", "B"], 3, ["main", "C"], []])
	_dispose(component)

	component = _start(visiting, rollback)
	component.advance_dialogue()
	component.advance_dialogue()
	component.start_dialogue_with_script("main")
	restarted = _at(component)
	component.advance_dialogue()
	_expect("B4 %s: a restart from the called script, the restarted story plays every iteration" % _mode(rollback),
		[restarted, _visits(component), _at(component), errors], [["main", "A"], 3, ["main", "B"], []])
	_dispose(component)

	# The same Load with the line directly in the loop body, the shape this plugin also runs.
	# pages: For Each (1, 2, 3) -> Page -> Set Int, Completed -> End.
	var pages := _script(
		_loop_nodes("pagesLoop", "array", "pageEntries") + [
			_line("Page"), _node("pageAfter", "setInt", {"variable": "pageStep", "value": 1}), _node("pagesEnd", "end")],
		_loop_edges("pagesLoop", "array") + [
			_flow("0", "", "pagesLoop"), _flow("pagesLoop", "loopBody", "Page"), _flow("Page", "", "pageAfter"),
			_flow("pagesLoop", "completed", "pagesEnd")],
		[_entries("pageEntries", "array", [1, 2, 3]), _variable("pageStep", "integer", 0)])
	component = _start({"main.json": _story_around(), "chapter.json": pages}, rollback)
	saved = manager.save_to_slot(SLOT)
	component.advance_dialogue()
	component.advance_dialogue()
	inside = _at(component)
	component.stop_dialogue()
	loaded = manager.load_from_slot(SLOT)
	component.start_dialogue_with_script("main")
	component.advance_dialogue()
	var shown := 0
	while _at(component) == ["chapter", "Page"] and shown < 10:
		shown += 1
		component.advance_dialogue()
	_expect("B4 %s: Load taken while a loop body is paused on a line, its next run plays every iteration" % _mode(rollback),
		[saved, inside, loaded, shown, _at(component), errors], [true, ["chapter", "Page"], true, 3, ["main", "B"], []])
	_dispose(component)

	# halting: For Each (1, 2, 3) -> Branch(Stop): false -> Set Bool(Stop = true),
	# true -> Set Int(Seen = entry) -> a Random Branch without options, where the walk stops.
	# The second entry leaves the loop mid-way.
	var halting := _script(
		_loop_nodes("haltLoop", "array", "haltEntries") + [
			_node("haltStop", "getBool", {"variable": "stop"}), _node("haltGate", "branch"),
			_node("haltArm", "setBool", {"variable": "stop", "value": true}),
			_node("haltSeen", "setInt", {"variable": "seen", "isGlobal": true}),
			_node("halt", "randomBranch", {"options": []})],
		_loop_edges("haltLoop", "array") + [
			_flow("0", "", "haltLoop"), _flow("haltLoop", "loopBody", "haltGate"), _flow("haltGate", "false", "haltArm"),
			_flow("haltGate", "true", "haltSeen"), _flow("haltSeen", "1", "halt"),
			_data("haltStop", "boolean-", "haltGate", "boolean-condition"), _entry_edge("haltLoop", "array", "haltSeen", "integer-2")],
		[_entries("haltEntries", "array", [1, 2, 3]), _variable("stop", "boolean", false)])
	component = _start({"main.json": _story_around(), "chapter.json": halting}, rollback, [_variable("seen", "integer", 0)])
	saved = manager.save_to_slot(SLOT)
	component.advance_dialogue()
	var stopped := [component._context.current_script.script_path, _global("seen")]
	component.stop_dialogue()
	loaded = manager.load_from_slot(SLOT)
	component.start_dialogue_with_script("main")
	var reloaded := [_at(component), _global("seen")]
	component.advance_dialogue()
	_expect("B4 %s: Load taken after a walk stopped inside the loop body, its next run starts at the first entry" % _mode(rollback),
		[saved, stopped, loaded, reloaded, _global("seen"), errors], [true, ["chapter", 2], true, [["main", "A"], 0], 2, []])
	_dispose(component)


# =============================================================================
# B5. Save and Load right after a choice that ran the loop
# =============================================================================

func _test_save_and_load_after_loop(rollback: bool) -> void:
	for tail in _tails():
		var line := {"script": "main", "line": "A", "done": 1, "open_loops": 0, "errors": []}
		var expected := [_with(line, {"log": [1, 2]}), _with(line, {"log": [1, 2]}), _with(line, {"log": [1, 2, 1, 2]}),
			_with(line, {"line": "B", "log": [1, 2, 1, 2]})]
		# A Block Rollback node is a barrier of its own: Back does not cross the choice that ran it.
		var back: bool = rollback and tail.node.type != "blockRollback"
		_expect("B5 %s, body ends on %s: Go, Go, Next without Save and Load" % [_mode(rollback), tail.name],
			_play(_tail_story(tail, "array"), rollback, false, back), expected)
		_expect("B5 %s, body ends on %s: Go, Save, Load restores the line and carries on the same" % [_mode(rollback), tail.name],
			_play(_tail_story(tail, "array"), rollback, true, back), expected)


## Go, optionally Save and Load, then carry on: Go again, then Next. With `back`, Back from the
## last line has to restore line A as well.
func _play(scripts: Dictionary, rollback: bool, with_save_and_load: bool, back: bool) -> Array:
	var component = _start(scripts, rollback)
	component.select_option("go")
	var steps := [_state(component)]
	if with_save_and_load:
		# Load runs between dialogues only, so the story is stopped for it and started again.
		var saved: bool = manager.save_to_slot(SLOT)
		component.stop_dialogue()
		var loaded: bool = manager.load_from_slot(SLOT)
		component.start_dialogue_with_script("main")
		if not (saved and loaded):
			steps.append({"saved": saved, "loaded": loaded})
	steps.append(_state(component))
	for option in ["go", "next"]:
		component.select_option(option)
		steps.append(_state(component))
	if back:
		var result: Dictionary = component.go_back()
		var restored := _state(component)
		if not result.get("ok", false) or restored.line != "A" or restored.open_loops != 0 or not restored.errors.is_empty():
			steps.append({"back": result, "restored": restored})
	_dispose(component)
	return steps


# =============================================================================
# Stories
# =============================================================================

## The nodes a loop body can end on, each with nothing connected after it.
func _tails() -> Array:
	var tails := [
		_tail("Set Bool", "setBool", {"variable": "scratch", "value": true}, {"variables": [_variable("scratch", "boolean", false)]}),
		_tail("Set Int", "setInt", {"variable": "scratch", "value": 1}, {"variables": [_variable("scratch", "integer", 0)]}),
		_tail("Set Float", "setFloat", {"variable": "scratch", "value": 1.5}, {"variables": [_variable("scratch", "float", 0.0)]}),
		_tail("Set String", "setString", {"variable": "scratch", "value": "text"}, {"variables": [_variable("scratch", "string", "")]}),
		_tail("Set Enum", "setEnum", {"variable": "scratch", "value": "x"}, {"variables": [_variable("scratch", "enum", "x", {"enumValues": ["x"]})]}),
		_tail("Set Image", "setImage", {"variable": "scratch"}, {"variables": [_variable("scratch", "image", "")]}),
		_tail("Set Audio", "setAudio", {"variable": "scratch"}, {"variables": [_variable("scratch", "audio", "")]}),
		_tail("Set Character", "setCharacter", {"variable": "scratch"}, {"variables": [_variable("scratch", "character", "")]}),
		_tail("Set Data Asset", "setDataAssetRef", {"variable": "scratch"}, {"variables": [_variable("scratch", "dataAsset", "")]}),
		_tail("Set Character Variable", "setCharacterVar", {"characterPath": "", "variable": "Score", "variableType": "integer"}),
		_tail("Set Data Asset Variable", "setDataAssetVariable", {"variableId": "score", "variableType": "integer"}),
		_tail("Set Map", "setMap", {"variable": "scratch", "keyType": "string", "valueType": "integer"},
			{"variables": [_variable("scratch", "map", [], {"keyType": "string", "valueType": "integer"})]}),
		_tail("Set Map Value", "setMapValue", {"keyType": "string", "valueType": "integer", "key": "k", "value": 1}),
		_tail("Remove Map Key", "removeMapKey", {"keyType": "string", "valueType": "integer", "key": "k"}),
		_tail("Clear Map", "clearMap", {"keyType": "string", "valueType": "integer"}),
		_tail("Set Background Image", "setBackgroundImage"),
		_tail("Play Audio", "playAudio"),
		_tail("Branch whose taken output is unconnected", "branch", {"value": true}),
		_tail("Random Branch whose selected output is unconnected", "randomBranch", {"options": [{"id": "only", "weight": 1}]}),
		_tail("Random Branch whose weights are all zero", "randomBranch", {"options": [{"id": "only", "weight": 1}]}, {
			"nodes": [_node("zero", "getInt", {"variable": "zero"})],
			"edges": [_data("zero", "integer-", "tail", "integer-only")],
			"variables": [_variable("zero", "integer", 0)]}),
		_tail("Switch On Enum with no output for the value", "switchOnEnum", {"variable": "mode"},
			{"variables": [_variable("mode", "enum", "x", {"enumValues": ["x"]})]}),
		_tail("Block Rollback", "blockRollback"),
		_tail("Run Script whose output is unconnected", "runScript", {"script": "empty.json"}),
		_tail("Run Flow into a flow with nothing after its entry", "runFlow", {"flowId": "side"},
			{"nodes": [_node("sideEntry", "entryFlow", {"flowId": "side"})], "flows": [{"id": "side", "name": "Side"}]}),
		_tail("For Each whose Completed is unconnected", "forEachIntLoop", {}, {
			"nodes": [_node("tailSource", "getIntArray", {"variable": "tailEntries"}), _node("tailStep", "setInt", {"variable": "scratch", "value": 1})],
			"edges": [_data("tailSource", "integer-array-", "tail", "integer-array-array"), _flow("tail", "loopBody", "tailStep")],
			"variables": [_entries("tailEntries", "array", [7, 8]), _variable("scratch", "integer", 0)]}),
		_tail("For Each Map whose Completed is unconnected", "forEachMap", {"keyType": "string", "valueType": "integer"}, {
			"nodes": [_node("tailSource", "getMap", {"variable": "tailEntries", "keyType": "string", "valueType": "integer"}),
				_node("tailStep", "setInt", {"variable": "scratch", "value": 1})],
			"edges": [_data("tailSource", "map-string-integer-", "tail", "map-string-integer-map"), _flow("tail", "loopBody", "tailStep")],
			"variables": [_entries("tailEntries", "map", [7, 8]), _variable("scratch", "integer", 0)]}),
		_tail("For Each over an empty array whose Completed is unconnected", "forEachIntLoop", {}, {
			"nodes": [_node("tailSource", "getIntArray", {"variable": "tailEntries"})],
			"edges": [_data("tailSource", "integer-array-", "tail", "integer-array-array")],
			"variables": [_entries("tailEntries", "array", [])]}),
		_tail("For Each with nothing connected to Loop Body or Completed", "forEachIntLoop", {}, {
			"nodes": [_node("tailSource", "getIntArray", {"variable": "tailEntries"})],
			"edges": [_data("tailSource", "integer-array-", "tail", "integer-array-array")],
			"variables": [_entries("tailEntries", "array", [7, 8])]}),
	]
	for family in ARRAY_FAMILIES:
		var scratch := {"variables": [_variable("scratch", ARRAY_FAMILIES[family], [], {"isArray": true})]}
		tails.append(_tail("Set %s Array" % family, "setDataAssetRefArray" if family == "DataAsset" else "set%sArray" % family, {"variable": "scratch"}, scratch))
		tails.append(_tail("Set %s Array Element" % family, "set%sArrayElement" % family))
		tails.append(_tail("Add To %s Array" % family, "addTo%sArray" % family))
		tails.append(_tail("Remove From %s Array" % family, "removeFrom%sArray" % family))
		tails.append(_tail("Clear %s Array" % family, "clear%sArray" % family))
	return tails


func _tail(name: String, type: String, fields: Dictionary = {}, extra: Dictionary = {}) -> Dictionary:
	var tail := {"name": name, "node": _node("tail", type, fields), "nodes": [], "edges": [], "variables": [], "flows": []}
	tail.merge(extra, true)
	return tail


## main: line A with the options Go and Next.
## Go -> For Each over (1, 2) -> Loop Body -> Add To Array(Log, entry) -> tail,
## Completed -> Set Int(Done = 1). Next -> `next`: line B, or End when the line sits in a
## called script. Run Script tails call `empty`, which is Start -> End.
func _tail_story(tail: Dictionary, loop_kind: String, next: Dictionary = {}) -> Dictionary:
	if next.is_empty():
		next = _line("B")
	var main := _script(
		_loop_nodes("loop", loop_kind, "entries") + tail.nodes + [
			_line("A", ["go", "next"]), next,
			_node("logArray", "getIntArray", {"variable": "log", "isGlobal": true}), _node("log", "addToIntArray"),
			tail.node,
			_node("done", "setInt", {"variable": "done", "isGlobal": true, "value": 1})],
		_loop_edges("loop", loop_kind) + tail.edges + [
			_flow("0", "", "A"), _flow("A", "go", "loop"), _flow("A", "next", next.id),
			_flow("loop", "loopBody", "log"), _flow("log", "1", "tail"), _flow("loop", "completed", "done"),
			_data("logArray", "integer-array-", "log", "integer-array-2"), _entry_edge("loop", loop_kind, "log", "integer-3")],
		tail.variables + [_entries("entries", loop_kind, [1, 2])], tail.flows)
	return {"main.json": main, "empty.json": _empty()}


## empty: Start -> End.
func _empty() -> Dictionary:
	return _script([_node("emptyEnd", "end")], [_flow("0", "", "emptyEnd")])


## scan: For Each over (1, 2, 3) -> Add To Array(Log, entry) -> Branch(Stop): false -> Set Bool(Stop = true),
## true -> End. The first entry arms Stop, the second returns from inside the loop body.
func _scan(loop_kind: String) -> Dictionary:
	return _script(
		_loop_nodes("scanLoop", loop_kind, "scanEntries") + [
			_node("scanLogArray", "getIntArray", {"variable": "log", "isGlobal": true}), _node("scanLog", "addToIntArray"),
			_node("scanStop", "getBool", {"variable": "stop"}), _node("scanGate", "branch"),
			_node("scanArm", "setBool", {"variable": "stop", "value": true}),
			_node("scanEnd", "end")],
		_loop_edges("scanLoop", loop_kind) + [
			_flow("0", "", "scanLoop"), _flow("scanLoop", "loopBody", "scanLog"), _flow("scanLog", "1", "scanGate"),
			_flow("scanGate", "false", "scanArm"), _flow("scanGate", "true", "scanEnd"),
			_data("scanStop", "boolean-", "scanGate", "boolean-condition"),
			_data("scanLogArray", "integer-array-", "scanLog", "integer-array-2"), _entry_edge("scanLoop", loop_kind, "scanLog", "integer-3")],
		[_entries("scanEntries", loop_kind, [1, 2, 3]), _variable("stop", "boolean", false)])


## main: A -> Run Script(chapter) -> B -> Run Script(chapter) -> C.
func _story_around() -> Dictionary:
	return _script(
		[_line("A"), _node("first", "runScript", {"script": "chapter.json"}), _line("B"),
			_node("second", "runScript", {"script": "chapter.json"}), _line("C")],
		[_flow("0", "", "A"), _flow("A", "", "first"), _flow("first", "output", "B"), _flow("B", "", "second"), _flow("second", "output", "C")])


## sub: Visit -> End.
func _visit() -> Dictionary:
	return _script([_line("Visit"), _node("subEnd", "end")], [_flow("0", "", "Visit"), _flow("Visit", "", "subEnd")])


# =============================================================================
# The exported JSON dialect
# =============================================================================

func _script(nodes: Array, connections: Array, variables: Array = [], flows: Array = []) -> Dictionary:
	var by_id := {"0": {"type": "start", "id": "0"}}
	for node in nodes:
		by_id[node.id] = node
	var declared := {}
	for variable in variables:
		declared[variable.id] = variable
	return {"startNode": "0", "nodes": by_id, "connections": connections, "variables": declared, "flows": flows}


func _node(id: String, type: String, fields: Dictionary = {}) -> Dictionary:
	var node := {"type": type, "id": id}
	node.merge(fields)
	return node


func _line(id: String, choices: Array = []) -> Dictionary:
	var listed := []
	for choice in choices:
		listed.append({"id": choice, "text": choice})
	return _node(id, "dialogue", {"text": id, "choices": listed})


func _variable(id: String, type: String, value, extra: Dictionary = {}) -> Dictionary:
	var variable := {"id": id, "name": id, "type": type, "value": value}
	variable.merge(extra)
	return variable


## A For Each named `id` over the local variable `entries`, as an array loop or as a map loop.
func _loop_nodes(id: String, loop_kind: String, entries: String) -> Array:
	if loop_kind == "map":
		return [_node(id + "Source", "getMap", {"variable": entries, "keyType": "string", "valueType": "integer"}),
			_node(id, "forEachMap", {"keyType": "string", "valueType": "integer"})]
	return [_node(id + "Source", "getIntArray", {"variable": entries}), _node(id, "forEachIntLoop")]


func _loop_edges(id: String, loop_kind: String) -> Array:
	if loop_kind == "map":
		return [_data(id + "Source", "map-string-integer-", id, "map-string-integer-map")]
	return [_data(id + "Source", "integer-array-", id, "integer-array-array")]


## The integers a loop walks: array elements, or the values of a string-keyed map.
func _entries(id: String, loop_kind: String, values: Array) -> Dictionary:
	if loop_kind == "map":
		var pairs := []
		for value in values:
			pairs.append({"key": "k%d" % value, "value": value})
		return _variable(id, "map", pairs, {"keyType": "string", "valueType": "integer"})
	return _variable(id, "integer", values, {"isArray": true})


## The loop's current entry into an integer pin.
func _entry_edge(id: String, loop_kind: String, target: String, input: String) -> Dictionary:
	return _data(id, "integer-value" if loop_kind == "map" else "integer-element", target, input)


## A flow edge out of the output `output` ("" for Start and for a line's own output).
func _flow(source: String, output: String, target: String) -> Dictionary:
	return _data(source, output, target, "0")


func _data(source: String, output: String, target: String, input: String) -> Dictionary:
	return {"id": "%s-%s-%s-%s" % [source, output, target, input], "source": source, "target": target,
		"sourceHandle": "source-%s-%s" % [source, output], "targetHandle": "target-%s-%s" % [target, input]}


func _with(base: Dictionary, changes: Dictionary) -> Dictionary:
	var result := base.duplicate()
	result.merge(changes, true)
	return result


# =============================================================================
# Harness
# =============================================================================

## Import the story, with the globals Log and Done every story shares, and start it.
func _start(scripts: Dictionary, rollback: bool, globals: Array = []):
	var declared := {}
	for variable in [_variable("log", "integer", [], {"isArray": true}), _variable("done", "integer", 0)] + globals:
		declared[variable.id] = variable
	var project = Importer.new().import_project_from_json({
		"version": "1.0", "startupScript": "main.json",
		"metadata": {"dialogueRollback": {"version": 1, "enabled": rollback, "historyLimit": 100}},
		"globalVariables": declared, "scripts": scripts})
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


func _global(id: String):
	var record: Dictionary = manager.get_global_variables()[id]
	if not record.get("is_array", false):
		return record.value.get_int()
	var values := []
	for element in record.value.get_array():
		values.append(element.get_int())
	return values


## The script the walk stands in and the line on screen.
func _at(component) -> Array:
	var script = component._context.current_script
	var dialogue = component.get_current_dialogue()
	return [script.script_path if script else "", dialogue.node_id if dialogue else ""]


func _position(component) -> Array:
	return _at(component) + [_global("last")]


func _state(component) -> Dictionary:
	var at := _at(component)
	return {"script": at[0], "line": at[1], "log": _global("log"), "done": _global("done"),
		"open_loops": component._context.loop_stack.size(), "errors": errors.duplicate()}


## Advances through the Visit lines and returns how many were shown before the story left `sub`.
func _visits(component) -> int:
	var shown := 0
	while _at(component) == ["sub", "Visit"] and shown < 10:
		shown += 1
		component.advance_dialogue()
	return shown
