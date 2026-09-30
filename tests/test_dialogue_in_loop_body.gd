extends SceneTree
## Headless tests for A DIALOGUE NODE INSIDE A forEach BODY — the one place where a chain
## boundary and a loop iteration overlap.
##
## An array forEach publishes its current element through the loop node's cached_output. The
## three dialogue boundaries — dialogue ENTRY, select_option and advance_dialogue — each clear
## every cached_output there is, because the exec chain that produced them is over. That is true
## of the chain and false of the loop wrapped around it: the iteration is still running, and
## every node after the dialogue still reads the element. Without a restore after each clear the
## element is gone, silently, replaced by the type default:
##
##   ENTRY          the option gates re-evaluate against "" on the very render they were
##                  authored for, so an option gated on the current element never appears
##   select_option  the rest of the iteration's body reads "" instead of the element
##   advance        the same, for a narrative dialogue with no options
##
## MAP loops are immune and are not covered here: loop_key/loop_value are dedicated fields for
## precisely this reason. Array loops are the exposure, and StoryFlowExecutionContext's
## restore_live_loop_outputs is the repair.
##
## TWO ELEMENTS in every scenario, and every assertion names WHICH one it expects. A single
## element cannot tell a surviving stamp from a stale one, and it cannot tell a gate that reads
## the right element from a gate that reads whatever was there last.
##
## Graphs are assembled with tests/data_asset_test_graph.gd. Nothing here is a .sfd test — the
## builders are just this repo's one place that owns the editor's handle formats, and getting a
## handle wrong makes a gate fail closed and a test pass for the wrong reason.
##
## Run from the repository root (import first to build the class cache):
##   godot --headless --import
##   godot --headless --script res://tests/test_dialogue_in_loop_body.gd
## Or: powershell -File tests/run_tests.ps1 -GodotExe <path-to-godot>

# Preloaded by path so parsing never depends on the global class name cache,
# which can be stale or mid-rewrite when the game launches (godotengine/godot#75388).
const ComponentScript = preload("res://addons/storyflow/core/storyflow_component.gd")
const Graph = preload("res://tests/data_asset_test_graph.gd")
const Handles = preload("res://addons/storyflow/core/storyflow_handles.gd")
const ManagerScript = preload("res://addons/storyflow/core/storyflow_manager.gd")
const ProjectScript = preload("res://addons/storyflow/core/storyflow_project.gd")
const Types = preload("res://addons/storyflow/core/storyflow_types.gd")
const VariantScript = preload("res://addons/storyflow/core/storyflow_variant.gd")

var _checks: int = 0
var _failures: int = 0

var _manager: Node = null


func _initialize() -> void:
	await process_frame
	_setup_runtime()

	_test_option_dialogue_in_a_loop_body()
	_test_narrative_dialogue_in_a_loop_body()

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
# 1. An OPTION dialogue in a loop body
# =============================================================================

## THE AUTHORING SHAPE: forEach(items) { dialogue whose options are gated on the element }.
##
## Two options, each gated through an equalString against a different element, so the render is
## asserted in BOTH directions on both iterations — the matching option present AND the other
## one absent. A gate that reads nothing fails closed, so "the right option is missing" and
## "every option is missing" are the same symptom on the visible arm alone; the absent arm is
## what separates a working gate from a gate reading "" against two literals that both miss.
##
## The post-selection read is a separate node in the same body, wired to the same element pin,
## reached through the selected option's exec edge. It has no outgoing edge, which is what tells
## _handle_set_node_end to advance the loop — so one select_option call carries the chain all
## the way through the rest of iteration 1 and into iteration 2's render.
func _test_option_dialogue_in_a_loop_body() -> void:
	print("-- an option dialogue inside a forEach body --")
	var script := Graph.build("scripts/LoopDialogue.sfe", {
		"0": Graph.start(),
		"GA": Graph.node("GA", Types.NodeType.GET_STRING_ARRAY, "getStringArray", {"variable": "v_items", "isGlobal": false}),
		"FE": Graph.node("FE", Types.NodeType.FOR_EACH_STRING_LOOP, "forEachStringLoop", {}),
		"EA": Graph.node("EA", Types.NodeType.EQUAL_STRING, "equalString", {"value2": "alpha"}),
		"EB": Graph.node("EB", Types.NodeType.EQUAL_STRING, "equalString", {"value2": "beta"}),
		"D": Graph.dialogue("D", [{"id": "oa", "text": "for alpha"}, {"id": "ob", "text": "for beta"}]),
		"SEEN": Graph.node("SEEN", Types.NodeType.SET_STRING, "setString", {"variable": "seen", "isGlobal": false}),
		"DONE": Graph.dialogue("DONE"),
	}, [
		Graph.exec("0", "FE"),
		Graph.data_wire("GA", "string-array", "FE", Handles.IN_STRING_ARRAY),
		Graph.edge("FE", Handles.source("FE", Handles.OUT_LOOP_BODY), "D", Handles.target("D")),
		# The gates: the loop element into each comparison's first pin, the literal in node data.
		Graph.data_wire("FE", "string", "EA", Handles.IN_STRING1),
		Graph.data_wire("FE", "string", "EB", Handles.IN_STRING1),
		Graph.data_wire("EA", "boolean", "D", "boolean-oa"),
		Graph.data_wire("EB", "boolean", "D", "boolean-ob"),
		# Either option continues into the same node, which reads the element AFTER the
		# selection's cache clear.
		Graph.edge("D", Handles.source("D", "oa"), "SEEN", Handles.target("SEEN")),
		Graph.edge("D", Handles.source("D", "ob"), "SEEN", Handles.target("SEEN")),
		Graph.data_wire("FE", "string", "SEEN", Handles.IN_STRING),
		Graph.edge("FE", Handles.source("FE", Handles.OUT_LOOP_COMPLETED), "DONE", Handles.target("DONE")),
	], {
		"v_items": Graph.array_var("v_items", "Items", Types.VariableType.STRING, ["alpha", "beta"]),
		"seen": Graph.scalar_var("seen", "Seen", Types.VariableType.STRING, VariantScript.from_string("")),
	})

	var component := _run(script)

	# ITERATION 1 — the render the gate was authored for.
	var first := _visible_options(component)
	_check("iteration 1 renders the option gated on the FIRST element (got %s)" % str(first),
		first == ["oa"])

	component.select_option("oa")
	_check("and a node after the selection still reads that element (got %s)" % _stored_string(component, "seen"),
		_stored_string(component, "seen") == "alpha")

	# ITERATION 2 — the same dialogue node, a different element, a different gate.
	var second := _visible_options(component)
	_check("iteration 2 renders the option gated on the SECOND element (got %s)" % str(second),
		second == ["ob"])

	component.select_option("ob")
	_check("and the post-selection read follows the element too (got %s)" % _stored_string(component, "seen"),
		_stored_string(component, "seen") == "beta")

	# The loop ran to completion rather than stalling on an unselectable render.
	_check("the loop completed and execution left the body", _parked_node_id(component) == "DONE")
	_check("with the loop state torn down", not component._context.get_node_state("FE").loop_initialized)
	_teardown(component)


# =============================================================================
# 2. A NARRATIVE dialogue in a loop body
# =============================================================================

## THE THIRD BOUNDARY. advance_dialogue clears the same caches select_option does, and a
## narrative beat per element is as ordinary an authoring shape as a gated choice — so the same
## exposure exists on a dialogue with no options at all, where there is nothing to gate and the
## only symptom is the body reading "" after the advance.
func _test_narrative_dialogue_in_a_loop_body() -> void:
	print("-- a narrative dialogue inside a forEach body --")
	var script := Graph.build("scripts/LoopNarrative.sfe", {
		"0": Graph.start(),
		"GA": Graph.node("GA", Types.NodeType.GET_STRING_ARRAY, "getStringArray", {"variable": "v_items", "isGlobal": false}),
		"FE": Graph.node("FE", Types.NodeType.FOR_EACH_STRING_LOOP, "forEachStringLoop", {}),
		"ND": Graph.dialogue("ND"),
		"SEEN": Graph.node("SEEN", Types.NodeType.SET_STRING, "setString", {"variable": "seen", "isGlobal": false}),
		"DONE": Graph.dialogue("DONE"),
	}, [
		Graph.exec("0", "FE"),
		Graph.data_wire("GA", "string-array", "FE", Handles.IN_STRING_ARRAY),
		Graph.edge("FE", Handles.source("FE", Handles.OUT_LOOP_BODY), "ND", Handles.target("ND")),
		# The header edge, which is what makes the beat advanceable at all.
		Graph.exec("ND", "SEEN"),
		Graph.data_wire("FE", "string", "SEEN", Handles.IN_STRING),
		Graph.edge("FE", Handles.source("FE", Handles.OUT_LOOP_COMPLETED), "DONE", Handles.target("DONE")),
	], {
		"v_items": Graph.array_var("v_items", "Items", Types.VariableType.STRING, ["one", "two"]),
		"seen": Graph.scalar_var("seen", "Seen", Types.VariableType.STRING, VariantScript.from_string("")),
	})

	var component := _run(script)
	_check("the beat parks on the dialogue inside the body", _parked_node_id(component) == "ND")

	component.advance_dialogue()
	_check("advancing keeps the first element available to the rest of the body (got %s)" % _stored_string(component, "seen"),
		_stored_string(component, "seen") == "one")

	component.advance_dialogue()
	_check("and the second iteration reads its own element (got %s)" % _stored_string(component, "seen"),
		_stored_string(component, "seen") == "two")

	_check("the loop completed after both elements", _parked_node_id(component) == "DONE")
	_teardown(component)


# =============================================================================
# Harness
# =============================================================================

func _setup_runtime() -> void:
	_manager = ManagerScript.new()
	_manager.name = "StoryFlowRuntime"
	root.add_child(_manager)
	_manager.set_project(ProjectScript.new())


## Register the script on the shared project and run it. One manager for the whole file — a
## second node named StoryFlowRuntime would shadow it.
func _run(script: StoryFlowScript) -> StoryFlowComponent:
	_manager.get_project().scripts[script.script_path] = script
	var component := ComponentScript.new()
	component.dialogue_ui_scene = null
	root.add_child(component)
	component.start_dialogue_with_script(script.script_path)
	return component


func _teardown(component: StoryFlowComponent) -> void:
	component.stop_dialogue()
	root.remove_child(component)
	component.queue_free()


# =============================================================================
# Assertion helpers
# =============================================================================

## The ids of the options the CURRENT render actually offers. _build_dialogue_state has already
## dropped the ones whose gate answered false, so this is the gate's verdict.
func _visible_options(component: StoryFlowComponent) -> Array:
	var state = component._context.current_dialogue_state
	if state == null:
		return []
	var ids: Array = []
	for option in state.options:
		ids.append(option.id)
	return ids


func _parked_node_id(component: StoryFlowComponent) -> String:
	var state = component._context.current_dialogue_state
	return state.node_id if state != null else ""


## A local variable's STORED string, bypassing get_string_variable's own strings-table
## resolution on the way out.
func _stored_string(component: StoryFlowComponent, variable_id: String) -> String:
	var variable = component._context.local_variables.get(variable_id, {})
	var value = variable.get("value", null)
	return value.get_string() if value is VariantScript else ""
