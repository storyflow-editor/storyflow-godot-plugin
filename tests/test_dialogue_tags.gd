extends SceneTree
## Headless tests for dialogue tags (StoryFlow dialogue-tags engine phase 3).
##
## Pins the firing semantics of the dialogue_tag_reached signal against the real
## StoryFlowComponent execution flow, mirroring the editor's HTML runtime:
##   1. Fires when a dialogue node is ENTERED (as it is applied/shown).
##   2. Fires ONLY on a fresh entry — re-rendering the same current line never
##      re-fires (returning from a Set* node, resume/re-render, or a variable-
##      change-driven rebuild); revisiting the node later does.
##   3. One event per tag, in authored (array) order.
##   4. Untagged dialogue fires nothing.
##   5. The payload is the raw tag string, untouched (spaces/unicode preserved).
##   6. Event order: dialogue_updated (state fully applied) is emitted FIRST for
##      a node, THEN its per-tag events, iterating a snapshot of the tag list.
##   7. Re-entrancy: a handler may advance mid-loop — the entered node's full
##      snapshot still fires, no crash, and dialogue_updated(null) is never emitted.
##   8. The importer coerces each tag to a string ([42, true] -> ["42", "true"])
##      and ignores a non-array 'tags' value.
##
## Run from the repository root (import first to build the class cache):
##   godot --headless --import
##   godot --headless --script res://tests/test_dialogue_tags.gd
## Or: powershell -File tests/run_tests.ps1 -GodotExe <path-to-godot>

const ComponentScript := preload("res://addons/storyflow/core/storyflow_component.gd")
const ManagerScript := preload("res://addons/storyflow/core/storyflow_manager.gd")
const ProjectScript := preload("res://addons/storyflow/core/storyflow_project.gd")
const ScriptScript := preload("res://addons/storyflow/core/storyflow_script.gd")
const ImporterScript := preload("res://addons/storyflow/editor/storyflow_importer.gd")
const VariantScript := preload("res://addons/storyflow/core/storyflow_variant.gd")
const Handles := preload("res://addons/storyflow/core/storyflow_handles.gd")
const Types := preload("res://addons/storyflow/core/storyflow_types.gd")

var _checks: int = 0
var _failures: int = 0

## Captured tag emissions (in order), reset per scenario.
var _emitted: Array[String] = []

## Combined event log for ordering/re-entrancy scenarios, reset per scenario.
## Entries: "updated:<node_id>" or "tag:<tag>".
var _events: Array[String] = []

## Set true if a dialogue_updated ever arrives with a null state.
var _null_state_seen: bool = false


func _initialize() -> void:
	await process_frame
	_run_tests()
	if _failures == 0:
		print("ALL %d CHECKS PASSED" % _checks)
	else:
		print("%d OF %d CHECKS FAILED" % [_failures, _checks])
	quit(1 if _failures > 0 else 0)


func _on_tag(tag: String) -> void:
	_emitted.append(tag)


func _on_tag_logged(tag: String) -> void:
	_events.append("tag:%s" % tag)


func _on_updated_logged(state) -> void:
	if state == null:
		_null_state_seen = true
		_events.append("updated:<null>")
	else:
		_events.append("updated:%s" % state.node_id)


## Build a linear script:
##   start(0) -> A(dialogue, tags=[boom, shake it]) -> B(dialogue, no tags)
##            -> C(dialogue, tags=[héllo 世界]) -> end
## Carries a local bool variable so the variable-change refresh path is drivable.
func _make_script() -> StoryFlowScript:
	var s := ScriptScript.new()
	s.script_path = "scripts/Tags.sfe"

	s.variables = {
		"flag": {"id": "flag", "name": "flag", "type": Types.VariableType.BOOLEAN,
			"value": VariantScript.from_bool(false)},
	}

	s.nodes = {
		"0": {"id": "0", "type": Types.NodeType.START, "type_string": "start", "data": {}},
		"A": {"id": "A", "type": Types.NodeType.DIALOGUE, "type_string": "dialogue",
			"data": {"title": "", "text": "A", "tags": ["boom", "shake it"]}},
		"B": {"id": "B", "type": Types.NodeType.DIALOGUE, "type_string": "dialogue",
			"data": {"title": "", "text": "B"}},
		"C": {"id": "C", "type": Types.NodeType.DIALOGUE, "type_string": "dialogue",
			"data": {"title": "", "text": "C", "tags": ["héllo 世界"]}},
		"E": {"id": "E", "type": Types.NodeType.END, "type_string": "end", "data": {}},
	}

	# Flow edges. Dialogue header output uses source(id) with the empty suffix.
	s.connections = [
		_edge("e0", "0", Handles.source("0"), "A", Handles.target("A")),
		_edge("eab", "A", Handles.source("A"), "B", Handles.target("B")),
		_edge("ebc", "B", Handles.source("B"), "C", Handles.target("C")),
		_edge("ece", "C", Handles.source("C"), "E", Handles.target("E")),
	]
	s.build_indices()
	return s


func _edge(id: String, src: String, src_handle: String, tgt: String, tgt_handle: String) -> Dictionary:
	return {
		"id": id, "source": src, "target": tgt,
		"source_handle": src_handle, "target_handle": tgt_handle,
	}


func _make_component() -> ComponentScript:
	var comp := ComponentScript.new()
	# Disable the default dialogue UI scene so the test needs no display server.
	comp.dialogue_ui_scene = null
	root.add_child(comp)
	comp.dialogue_tag_reached.connect(_on_tag)
	return comp


func _run_tests() -> void:
	var project := ProjectScript.new()
	project.scripts["scripts/Tags.sfe"] = _make_script()

	var mgr := ManagerScript.new()
	mgr.name = "StoryFlowRuntime"
	root.add_child(mgr)
	mgr.set_project(project)

	# --- Scenario 1: fresh entry into A fires both tags in order (rules 1,3,5) ---
	_emitted = []
	var comp := _make_component()
	comp.start_dialogue_with_script("scripts/Tags.sfe")
	# Execution runs to the first dialogue (A) synchronously and waits for input.
	_check_array("A fires [boom, shake it] in order on entry", _emitted, ["boom", "shake it"])

	# --- Scenario 2: advancing to B (untagged) fires nothing (rule 4) ---
	_emitted = []
	comp.advance_dialogue()
	_check_array("untagged B fires no tags", _emitted, [])

	# --- Scenario 3: advancing to C fires the unicode/space tag verbatim (rule 5) ---
	_emitted = []
	comp.advance_dialogue()
	_check_array("C fires the raw unicode tag untouched", _emitted, ["héllo 世界"])

	_teardown(comp)

	# --- Scenario 4: revisiting the same node LATER fires again (rule 2, part b) --
	# Fresh run: A fires, then a second fresh run of the same script fires A again.
	_emitted = []
	var comp2 := _make_component()
	comp2.start_dialogue_with_script("scripts/Tags.sfe")
	_check_array("first run of A fires its tags", _emitted, ["boom", "shake it"])
	comp2.stop_dialogue()
	_emitted = []
	comp2.start_dialogue_with_script("scripts/Tags.sfe")
	_check_array("re-entering A on a new run fires its tags again", _emitted, ["boom", "shake it"])
	_teardown(comp2)

	# --- Scenario 5: refresh of the current line does NOT re-fire (rule 2, part a) -
	# resume_dialogue re-broadcasts the CURRENT state without a fresh entry.
	_emitted = []
	var comp3 := _make_component()
	comp3.start_dialogue_with_script("scripts/Tags.sfe")
	# A's tags fired on entry; clear and force a re-broadcast of the same line.
	_emitted = []
	comp3.pause_dialogue()
	comp3.resume_dialogue()
	_check_array("resume (re-render) of A does NOT re-fire tags", _emitted, [])
	_teardown(comp3)

	# --- Scenario 6: variable-change refresh while parked on a tagged line (rule 2) -
	# Setting a variable while waiting on A re-interpolates + re-broadcasts the same
	# line via _rebuild_and_emit_dialogue, which is NOT a fresh entry -> no tags.
	_emitted = []
	var comp4 := _make_component()
	comp4.start_dialogue_with_script("scripts/Tags.sfe")
	# A's tags fired on entry; clear and drive the variable_changed -> rebuild path.
	_emitted = []
	comp4.set_bool_variable("flag", true)
	_check_array("variable-change rebuild of A does NOT re-fire tags", _emitted, [])
	_teardown(comp4)

	# --- Scenario 7: ordering — dialogue_updated for a node precedes its tags (rule 6) -
	_events = []
	_null_state_seen = false
	var comp5 := _make_component()
	comp5.dialogue_updated.connect(_on_updated_logged)
	comp5.dialogue_tag_reached.connect(_on_tag_logged)
	comp5.start_dialogue_with_script("scripts/Tags.sfe")
	_check_array(
		"A: dialogue_updated arrives BEFORE its tag events",
		_events,
		["updated:A", "tag:boom", "tag:shake it"]
	)
	comp5.dialogue_updated.disconnect(_on_updated_logged)
	comp5.dialogue_tag_reached.disconnect(_on_tag_logged)
	_teardown(comp5)

	# --- Scenario 8: re-entrancy — handler advances on the first tag (rule 7) -------
	# The handler advances the dialogue when it sees "boom". Contract: the ENTERED
	# node's full snapshot ([boom, shake it]) still fires, no crash, and no
	# dialogue_updated(null) is ever emitted. Interleaving with B's update is
	# accepted; we assert only the invariants that must hold.
	_events = []
	_null_state_seen = false
	var comp6 := _make_component()
	comp6.dialogue_updated.connect(_on_updated_logged)
	comp6.dialogue_tag_reached.connect(_on_tag_logged)
	var advancer := func(tag: String) -> void:
		if tag == "boom":
			comp6.advance_dialogue()
	comp6.dialogue_tag_reached.connect(advancer)
	comp6.start_dialogue_with_script("scripts/Tags.sfe")
	# Full snapshot of A fired despite the mid-loop advance.
	_check_contains("re-entrancy: A's 'boom' tag fired", _events, "tag:boom")
	_check_contains("re-entrancy: A's 'shake it' tag still fired after mid-loop advance",
		_events, "tag:shake it")
	# The advance transitioned to B (untagged) and broadcast its update.
	_check_contains("re-entrancy: B's update was broadcast after the advance",
		_events, "updated:B")
	_check_bool("re-entrancy: no dialogue_updated(null) was ever emitted", not _null_state_seen)
	comp6.dialogue_tag_reached.disconnect(advancer)
	comp6.dialogue_updated.disconnect(_on_updated_logged)
	comp6.dialogue_tag_reached.disconnect(_on_tag_logged)
	_teardown(comp6)

	# --- Scenario 9: importer coercion + non-array guard (rule 8) -------------------
	# The importer coerces every tag entry to a string and drops a non-array value.
	var importer := ImporterScript.new()
	var coerced := importer._parse_node_data("dialogue",
		{"data": {"text": "X", "tags": [42, true, "raw"]}})
	_check_array("importer coerces [42, true, raw] to strings",
		coerced.get("tags", []), ["42", "true", "raw"])
	var non_array := importer._parse_node_data("dialogue",
		{"data": {"text": "X", "tags": 7}})
	_check_bool("importer drops a non-array 'tags' value", not non_array.has("tags"))
	var missing := importer._parse_node_data("dialogue", {"data": {"text": "X"}})
	_check_bool("importer omits 'tags' when the key is absent", not missing.has("tags"))

	root.remove_child(mgr)
	mgr.free()


func _teardown(comp: ComponentScript) -> void:
	if comp.dialogue_tag_reached.is_connected(_on_tag):
		comp.dialogue_tag_reached.disconnect(_on_tag)
	root.remove_child(comp)
	comp.free()


func _check_array(label: String, got: Array, expected: Array) -> void:
	_checks += 1
	if got == expected:
		print("  PASS: %s" % label)
	else:
		_failures += 1
		printerr("  FAIL: %s: expected %s got %s" % [label, str(expected), str(got)])


func _check_contains(label: String, got: Array, needle) -> void:
	_checks += 1
	if got.has(needle):
		print("  PASS: %s" % label)
	else:
		_failures += 1
		printerr("  FAIL: %s: expected %s to contain %s" % [label, str(got), str(needle)])


func _check_bool(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("  PASS: %s" % label)
	else:
		_failures += 1
		printerr("  FAIL: %s" % label)
