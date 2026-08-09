extends SceneTree
## Headless test: reset_all_state must restore state IN PLACE, never rebind.
##
## A running dialogue's evaluator receives the manager's global-variables
## dictionary BY REFERENCE at dialogue start. reset_global_variables therefore
## must clear-and-refill that same dictionary: rebinding it to a fresh copy
## strands every live reference on the pre-reset object, splitting reads and
## writes into two divergent stores for the rest of the session. The example
## project triggers this in practice - its main menu node fires a "Reset Game"
## tag mid-dialogue on every return to the menu.
##
## Run from the repository root (import first to build the class cache):
##   godot --headless --import
##   godot --headless --script res://tests/test_reset_in_place.gd

const ManagerScript := preload("res://addons/storyflow/core/storyflow_manager.gd")
const ProjectScript := preload("res://addons/storyflow/core/storyflow_project.gd")
const VariantScript := preload("res://addons/storyflow/core/storyflow_variant.gd")
const Types := preload("res://addons/storyflow/core/storyflow_types.gd")

var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	await process_frame
	_run_tests()
	if _failures == 0:
		print("ALL %d CHECKS PASSED" % _checks)
	else:
		print("%d OF %d CHECKS FAILED" % [_failures, _checks])
	quit(1 if _failures > 0 else 0)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("  PASS: %s" % message)
	else:
		_failures += 1
		printerr("  FAIL: %s" % message)


func _run_tests() -> void:
	var mgr: Node = ManagerScript.new()
	mgr.name = "StoryFlowRuntime"
	get_root().add_child(mgr)

	var project = ProjectScript.new()
	project.global_variables = {
		"var_hp": {"id": "var_hp", "name": "EquippedDamage", "type": Types.VariableType.INTEGER,
			"value": VariantScript.from_int(0)},
	}
	mgr.set_project(project)

	# Simulate a dialogue-session consumer holding the dictionary by reference
	# (what the evaluator receives at dialogue start).
	var session_view: Dictionary = mgr.get_global_variables()
	_check(session_view.has("var_hp"), "session view sees the global")

	# A mid-session reset (the menu's Reset Game) ...
	mgr.reset_all_state()

	# ... must keep the SAME dictionary object alive:
	_check(mgr.get_global_variables() is Dictionary and session_view.has("var_hp"),
		"session view still has entries after reset")
	var same_store := true
	mgr.set_global_variable("var_hp", VariantScript.from_int(15))
	var seen_by_session: int = -1
	if session_view.has("var_hp"):
		var v = session_view["var_hp"].get("value")
		if v is VariantScript:
			seen_by_session = v.get_int(-1)
	same_store = seen_by_session == 15
	_check(same_store, "write AFTER reset is visible through the pre-reset reference (got %d)" % seen_by_session)

	# And the reset itself restored the authored default first:
	mgr.reset_all_state()
	var restored = mgr.get_global_variable("var_hp").get("value")
	_check(restored is VariantScript and restored.get_int(-1) == 0, "reset restores the authored default value")
