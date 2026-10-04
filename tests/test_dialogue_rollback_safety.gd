extends SceneTree

const Component = preload("res://addons/storyflow/core/storyflow_component.gd")
const Importer = preload("res://addons/storyflow/editor/storyflow_importer.gd")
const Manager = preload("res://addons/storyflow/core/storyflow_manager.gd")
const Value = preload("res://addons/storyflow/core/storyflow_variant.gd")
const Graph = preload("res://tests/data_asset_test_graph.gd")
const Types = preload("res://addons/storyflow/core/storyflow_types.gd")
const Character = preload("res://addons/storyflow/core/storyflow_character.gd")
const Store = preload("res://addons/storyflow/core/storyflow_data_asset_store.gd")
const Snapshot = preload("res://addons/storyflow/core/storyflow_execution_snapshot.gd")
const Lipsync = preload("res://addons/storyflow/lipsync/storyflow_lipsync.gd")
const FIXTURES := "res://tests/fixtures/dialogue-rollback-v1/"
var checks := 0
var failures := 0
var manager: Node

class RefusingComponent extends Component:
	var refuse_prepare := false
	var refuse_commit := false
	var refuse_recovery := false
	func _rollback_prepare_state(data: Dictionary, recovery: bool) -> Dictionary:
		return {} if refuse_prepare else super._rollback_prepare_state(data, recovery)
	func _rollback_commit_state(prepared: Dictionary, recovery: bool) -> bool:
		var committed := super._rollback_commit_state(prepared, recovery)
		if refuse_commit and not recovery:
			return false
		return committed and not (recovery and refuse_recovery)

func _initialize() -> void:
	await process_frame
	manager = Manager.new()
	manager.name = "StoryFlowRuntime"
	root.add_child(manager)
	_test_availability_observer_mutation()
	_test_container_declaration_reentry()
	_test_reset_locals_invalidation()
	_test_disabled_and_rng()
	_test_ownership()
	_test_reentrant_manager_operations()
	_test_reentrant_lifecycle()
	_test_reenter_tree()
	_test_caller_memo_after_callee_write()
	_test_graph_barrier_callbacks()
	_test_character_write_after_invalidation()
	_test_capture_and_restore_events()
	_test_limits_and_detachment()
	_test_snapshot_work_budget()
	_test_recovery()
	_test_localization_and_owned_stores()
	_test_recursive_activations()
	_test_owned_graph_writes()
	_test_random_float_and_branch()
	_test_payload_retention()
	await _test_audio_completion_and_recovery()
	_test_restored_listener_restart()
	await _test_missing_media()
	await create_timer(0.25).timeout
	print("Dialogue rollback safety: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("FAIL: ", label)

func project_for(name: String = "same-node"):
	return Importer.new().import_project(FIXTURES + name, "user://rollback_safety/" + name)

func start(project, component = null, before_start: Callable = Callable()):
	manager.set_project(project)
	if component == null:
		component = Component.new()
	component.trace_enabled = false
	root.add_child(component)
	if before_start.is_valid():
		before_start.call(component)
	component.start_dialogue_with_script(project.startup_script)
	return component

func dispose(component) -> void:
	component.stop_dialogue()
	component.free()

func global_value(name: String):
	for record in manager.get_global_variables().values():
		if record.name == name:
			return record.value
	return null

func _test_disabled_and_rng() -> void:
	var project = project_for()
	project.dialogue_rollback.enabled = false
	var component = start(project)
	component.select_option("again")
	check("disabled creates no controller, history, RNG or owner registration", component._rollback == null and component._context.rollback_rng == null and manager._rollback_owners.is_empty())
	check("disabled public result", component.go_back() == {"ok": false, "reason": "disabled"})
	dispose(component)
	project.dialogue_rollback.enabled = true
	seed(9876)
	var expected := randi()
	seed(9876)
	component = start(project)
	check("enabled private RNG initialization does not consume global RNG", randi() == expected)
	component._rollback.rng_state = 1
	check("unsigned xorshift golden sequence", [component._rollback.next_uint(), component._rollback.next_uint(), component._rollback.next_uint()] == [270369, 67634689, 2647435461])
	component._rollback.rng_state = 0
	check("zero random seed normalizes to one", component._rollback.next_uint() == 270369)
	dispose(component)

func _test_ownership() -> void:
	var project = project_for()
	var first = start(project)
	first.select_option("again")
	project.dialogue_rollback.enabled = false
	var second := Component.new()
	second.trace_enabled = false
	root.add_child(second)
	second.start_dialogue_with_script(project.startup_script)
	check("disabled second component also invalidates shared history", first.get_rollback_availability().reason == "multipleSessions" and not first.can_go_back())
	dispose(second)
	first.select_option("again")
	check("remaining owner resumes at a fresh baseline", not first.can_go_back())
	first.select_option("again")
	check("remaining owner can collect new history", first.can_go_back())
	first.set_int_variable("Visits", 50)
	check("component host setter invalidates history", not first.can_go_back() and global_value("Visits").get_int() == 50)
	first.select_option("again")
	check("host write cannot recover its previous line", not first.can_go_back())
	first.select_option("again")
	check("host write post-boundary baseline restores", first.go_back().ok and global_value("Visits").get_int() == 51)
	check("failed active Load preserves history state", not manager.load_from_slot("missing_rollback_test") and first.get_current_dialogue().node_id == "A")
	first.select_option("again")
	check("save does not clear history", manager.save_to_slot("rollback_safety") and first.can_go_back())
	manager.delete_save("rollback_safety")
	manager.reset_all_state()
	check("new game clears history", not first.can_go_back())
	dispose(first)
	check("all owners released", manager._active_dialogue_count == 0 and manager._rollback_owners.is_empty())

func _test_reentrant_manager_operations() -> void:
	for content in [false, true]:
		var project = project_for()
		var component = start(project)
		component.select_option("again")
		var restarted := [false]
		component.rollback_availability_changed.connect(func(availability):
			if not availability.canGoBack and not restarted[0]:
				restarted[0] = true
				component.stop_dialogue()
				component.start_dialogue_with_script(project.startup_script))
		if content:
			manager.set_project(project)
		else:
			var id: String = manager.get_global_variables().keys()[0]
			manager.set_global_variable(id, Value.from_int(40))
		check("reentrant operation retains one registered replacement", restarted[0] and manager._active_dialogue_count == 1 and manager._rollback_owners.size() == 1 and manager._rollback_owners[0] == component._rollback)
		component.select_option("again")
		check("replacement never retains pre-operation history", not component.can_go_back())
		component.select_option("again")
		if content:
			check("content replacement permanently disables this active session", component.get_rollback_availability().reason == "contentChanged")
		else:
			check("host restart restores only post-write value", component.go_back().ok and global_value("Visits").get_int() == 41)
		dispose(component)

func _test_reentrant_lifecycle() -> void:
	for restart in [false, true]:
		var project = project_for()
		var first = start(project)
		var second := Component.new()
		second.trace_enabled = false
		root.add_child(second)
		second.start_dialogue_with_script(project.startup_script)
		var replaced := [false]
		first.rollback_availability_changed.connect(func(availability):
			if availability.reason == "empty" and not replaced[0]:
				replaced[0] = true
				second.start_dialogue_with_script(project.startup_script))
		if restart:
			second.start_dialogue_with_script(project.startup_script)
		else:
			second.stop_dialogue()
		check("teardown callbacks cannot hide or unregister replacement", replaced[0] and second.is_dialogue_active() and second._dialogue_ui_instance.visible and manager._active_dialogue_count == 2 and manager._rollback_owners.size() == 2)
		dispose(first)
		dispose(second)

func _test_capture_and_restore_events() -> void:
	var project = project_for("purchase")
	var component = start(project, null, func(owner):
		owner.dialogue_updated.connect(func(state):
			if state.node_id == "A": owner.select_option("buy")))
	check("reentrant initial entry captures only latest eligible line", component.get_current_dialogue().node_id == "B" and not component.can_go_back())
	dispose(component)

	project = project_for()
	project.scripts[project.startup_script].nodes["A"].data.tags = ["host-write"]
	component = start(project, null, func(owner):
		owner.dialogue_tag_reached.connect(func(_tag): owner.set_int_variable("Visits", 70)))
	check("host setter inside story tag remains external", not component.can_go_back() and component._rollback.history.is_empty())
	dispose(component)
	component = start(project_for())
	component.select_option("again")
	component.select_option("again")
	var normal := [0]
	var restored := [0]
	var nested := []
	component.dialogue_updated.connect(func(_state): normal[0] += 1)
	component.variable_changed.connect(func(_state): normal[0] += 1)
	component.dialogue_tag_reached.connect(func(_tag): normal[0] += 1)
	component.dialogue_restored.connect(func(_state):
		restored[0] += 1
		nested.append(component.go_back()))
	var history_size: int = component._rollback.history.size()
	component.pause_dialogue()
	component.resume_dialogue()
	check("redraw does not add an interaction", component._rollback.history.size() == history_size)
	normal[0] = 0
	check("Back succeeds through dedicated notification", component.go_back().ok and normal[0] == 0 and restored[0] == 1)
	check("double Back is gated during restored listeners", nested == [{"ok": false, "reason": "busy"}] and global_value("Visits").get_int() == 1)
	check("Back marks the fully revealed presentation", component.get_current_dialogue().get("is_restored") == true)
	component._rebuild_and_emit_dialogue()
	check("redraw preserves restored presentation identity", component.get_current_dialogue().get("is_restored") == true)
	component.select_option("again")
	check("fresh same-node entry clears restored presentation identity", component.get_current_dialogue().get("is_restored") == false)
	dispose(component)

func _test_limits_and_detachment() -> void:
	var interned_clone := Snapshot.new()
	var interned = interned_clone.copy({&"owned": &"value"})
	check("native interned text normalizes to bounded detached strings", interned_clone.failure.is_empty() and interned == {"owned": "value"} and typeof(interned.keys()[0]) == TYPE_STRING and typeof(interned.owned) == TYPE_STRING)
	var large_name := StringName("n".repeat(9 * 1024 * 1024))
	var interned_value_clone := Snapshot.new()
	interned_value_clone.copy(large_name)
	check("interned text values obey the retained payload budget", interned_value_clone.failure == "budget")
	var interned_key_clone := Snapshot.new()
	interned_key_clone.copy({large_name: 1})
	check("interned text keys obey the retained payload budget", interned_key_clone.failure == "budget")
	var project = project_for()
	project.dialogue_rollback.historyLimit = 2
	var component = start(project)
	for i in 8: component.select_option("again")
	check("history count retains baseline plus configured previous entries", component._rollback.history.size() == 3 and component.get_rollback_availability().steps == 2)
	check("first retained Back value", component.go_back().ok and global_value("Visits").get_int() == 7)
	check("second retained Back value", component.go_back().ok and global_value("Visits").get_int() == 6)
	check("evicted history unavailable", not component.can_go_back())
	dispose(component)
	project = project_for("purchase")
	component = start(project)
	var globals_identity: Dictionary = manager.get_global_variables()
	var overlay_identity: Dictionary = manager.get_data_asset_overlay()
	global_value("Counts").get_map().axe.set_int(999)
	component.select_option("buy")
	check("capture detached nested map variants", component.go_back().ok and global_value("Counts").get_map().axe.get_int() == 1)
	check("restore preserves shared store identities", is_same(globals_identity, manager.get_global_variables()) and is_same(overlay_identity, manager.get_data_asset_overlay()))
	dispose(component)
	component = start(project_for())
	manager.get_global_variables().large = Graph.scalar_var("large", "Large", Types.VariableType.STRING, Value.from_string("x".repeat(9 * 1024 * 1024)))
	component.select_option("again")
	check("oversized entry is refused without interrupting playback", component.get_rollback_availability().reason == "budget" and component.get_current_dialogue().node_id == "A" and component._rollback.history.is_empty())
	manager.get_global_variables().erase("large")
	component.select_option("again")
	check("capture resumes after budget barrier", not component.can_go_back() and component._rollback.history.size() == 1)
	manager.get_global_variables().bad = {"value": Node.new()}
	component.select_option("again")
	check("outside-owned object invalidates instead of entering snapshot", component.get_rollback_availability().reason == "unsupportedState")
	manager.get_global_variables().bad.value.free()
	manager.get_global_variables().erase("bad")
	dispose(component)
	var shared := {"item": Value.from_int(3)}
	var cloned: Dictionary = Snapshot.new().copy({"a": Value.from_map(shared), "b": Value.from_map(shared)})
	cloned.a.get_map().item.set_int(5)
	check("clone preserves internal aliases but detaches live graph", cloned.b.get_map().item.get_int() == 5 and shared.item.get_int() == 3)

func _test_snapshot_work_budget() -> void:
	var values := []
	for i in 4000:
		values.append(Value.from_int(i))
	var cloner := Snapshot.new()
	var started := Time.get_ticks_usec()
	var copied = cloner.copy(values)
	print("Typed snapshot 4000 values: %d usec, %d bytes" % [Time.get_ticks_usec() - started, cloner.bytes])
	check("many typed scalar elements do not scan unused containers", cloner.failure.is_empty() and copied.size() == 4000 and copied[3999].get_int() == 3999 and cloner.get("memo_comparisons") == 0)
	var shared_array := []
	var shared_map := {}
	var aliases = Snapshot.new().copy([Value.from_array(shared_array), Value.from_array(shared_array), Value.from_map(shared_map), Value.from_map(shared_map), Value.from_array([]), Value.from_map({})])
	aliases[0].get_array().append(Value.from_int(42))
	aliases[2].get_map().item = Value.from_int(12)
	check("empty container aliases survive and remain detached", aliases[1].get_array()[0].get_int() == 42 and aliases[3].get_map().item.get_int() == 12 and shared_array.is_empty() and shared_map.is_empty())
	check("distinct empty containers remain distinct", aliases[4].get_array().is_empty() and aliases[5].get_map().is_empty())
	var repeated := []
	for i in 4000:
		repeated.append(shared_array)
	cloner = Snapshot.new()
	copied = cloner.copy(repeated)
	check("large repeated empty aliases remain accepted", cloner.failure.is_empty() and is_same(copied[0], copied[3999]))
	for kind in ["array", "map"]:
		var equal_containers := []
		for i in 1000:
			equal_containers.append([] if kind == "array" else {})
		cloner = Snapshot.new()
		cloner.copy(equal_containers)
		check("equal distinct %s containers stop at work budget" % kind, cloner.failure == "budget")
	var cycle := []
	cycle.append(cycle)
	cloner = Snapshot.new()
	cloner.copy(cycle)
	check("shallow memo bucketing still rejects cycles", cloner.failure == "unsupportedState")
	cycle.clear()
	var deep := []
	for i in 130:
		deep = [deep]
	cloner = Snapshot.new()
	cloner.copy(deep)
	check("shallow memo bucketing still respects depth limit", cloner.failure == "unsupportedState")
	var component = start(project_for())
	var costly := []
	for i in 1000:
		costly.append([])
	manager.get_global_variables().costly = Graph.scalar_var("costly", "Costly", Types.VariableType.INTEGER, Value.from_array(costly))
	component.select_option("again")
	check("work overflow rejects checkpoint and keeps playback active", component.is_dialogue_active() and component.get_rollback_availability().reason == "budget" and component._rollback.history.is_empty())
	manager.get_global_variables().erase("costly")
	component.select_option("again")
	check("capture resumes after work-budget boundary", component._rollback.history.size() == 1 and not component.can_go_back())
	dispose(component)
	var scalar := Value.from_int(7)
	var duplicate = scalar.duplicate_variant()
	check("scalar duplication keeps unused storage absent", scalar.get("_array_storage") == null and scalar.get("_map_storage") == null and duplicate.get("_array_storage") == null and duplicate.get("_map_storage") == null)
	var exposed: Array = scalar._array_value
	exposed.append(Value.from_int(8))
	check("direct array property and getter preserve public alias", is_same(exposed, scalar.get_array()) and scalar.get_array()[0].get_int() == 8)
	scalar.set_int(9)
	check("scalar setter preserves previously assigned container", scalar.get_array()[0].get_int() == 8)
	scalar.set_map(shared_map)
	check("map assignment detaches prior array without clearing it", scalar._array_value.is_empty() and exposed.size() == 1 and is_same(scalar._map_value, shared_map))
	shared_map.item = Value.from_int(10)
	duplicate = scalar.duplicate_variant()
	duplicate.get_map().item.set_int(11)
	check("duplicate keeps typed values detached", shared_map.item.get_int() == 10 and duplicate.get_map().item.get_int() == 11)
	scalar.reset()
	check("reset clears exposed map aliases in place", shared_map.is_empty() and scalar.get_map().is_empty())
	scalar._array_value = exposed
	scalar.reset()
	check("reset clears directly assigned array aliases in place", exposed.is_empty())


func _test_recovery() -> void:
	for mode in ["prepare", "commit", "recovery"]:
		var component = start(project_for(), RefusingComponent.new())
		component.select_option("again")
		global_value("Visits").set_int(99)
		component.pause_dialogue()
		component._waiting_for_audio_advance = true
		component._audio_advance_allow_skip = true
		component.refuse_prepare = mode == "prepare"
		component.refuse_commit = mode != "prepare"
		component.refuse_recovery = mode == "recovery"
		var result: Dictionary = component.go_back()
		check(mode + " reports restore failure", result == {"ok": false, "reason": "restoreFailed"})
		if mode == "recovery":
			check("failed recovery stops safely", not component.is_dialogue_active() and manager._active_dialogue_count == 0)
		else:
			check(mode + " preserves immediate live state and controls", global_value("Visits").get_int() == 99 and component._context.is_paused and component._waiting_for_audio_advance and component._audio_advance_allow_skip)
		dispose(component)

func _test_localization_and_owned_stores() -> void:
	var project = project_for("purchase")
	project.has_localization = true
	project.languages = [{"code": "fr", "name": "French"}]
	project.language_strings = {"fr": {"friend.name": "AMI", "A.text": "{Friend.Name} {Item.Title}", "back.option": "Choisir {Friend.Name}", "back.title": "Titre {Friend.Name}", "back.block": "Note {Friend.Name}"}}
	project.global_strings["en.friend.name"] = "PROJECT FRIEND"
	var character := Character.new()
	character.character_path = "friend"
	character.character_name = "friend.name"
	character.variables = {"Score": Graph.scalar_var("score", "Score", Types.VariableType.INTEGER, Value.from_int(5))}
	project.characters.friend = character
	project.character_id_index["da_01234567890123456789012345678901"] = "friend"
	project.global_variables.friend = Graph.scalar_var("friend", "Friend", Types.VariableType.CHARACTER, Value.from_string("da_01234567890123456789012345678901"))
	project.global_variables.item = Graph.scalar_var("item", "Item", Types.VariableType.DATA_ASSET, Value.from_string("item"))
	project.data_assets.item = {"id": "item", "name": "Item", "parent": "", "variables": [{"id": "title", "name": "Title", "type": Types.VariableType.STRING, "value": Value.from_string("old"), "localizable": false}], "raw_overrides": {}}
	var script = project.scripts[project.startup_script]
	script.strings["en.friend.name"] = "SCRIPT SHADOW"
	script.strings["en.A.text"] = "{Friend.Name} {Item.Title}"
	script.nodes.A.data.title = "back.title"
	script.nodes.A.data.options[0].text = "back.option"
	script.nodes.A.data.textBlocks = [{"id": "note", "text": "back.block"}]
	script.strings["en.back.title"] = "Title {Friend.Name}"
	script.strings["en.back.option"] = "Choose {Friend.Name}"
	script.strings["en.back.block"] = "Note {Friend.Name}"
	var component = start(project)
	var identity = manager.get_runtime_characters().friend
	# Owned execution writes, using the same store primitive as graph handlers.
	Store.try_set(manager.get_data_asset_seed(), manager.get_data_asset_overlay(), "item", "title", Value.from_string("future"), manager.get_data_asset_revision())
	identity.character_name = "Future name"
	identity.name_is_literal = true
	identity.variables.Score.value.set_int(40)
	component.select_option("buy")
	manager.set_language("fr")
	check("current-language Back succeeds", component.go_back().ok)
	check("staged interpolation uses restored character bridge and overlay", component.get_current_dialogue().text == "AMI old")
	check("title, cached option and block templates resolve current names", component.get_current_dialogue().title == "Titre AMI" and component.get_current_dialogue().options[0].text == "Choisir AMI" and component.get_current_dialogue().text_blocks[0].text == "Note AMI")
	check("character mutable values and identity restored", manager.get_runtime_characters().friend == identity and identity.variables.Score.value.get_int() == 5 and not identity.name_is_literal)
	check("language preference is not undone", manager.get_language() == "fr")
	component.select_option("buy")
	manager.set_language("en")
	check("authored character names cannot be shadowed by script strings", component.go_back().ok and component.get_current_dialogue().text == "PROJECT FRIEND old")
	dispose(component)

func _test_recursive_activations() -> void:
	var project = project_for()
	project.global_variables.depth = Graph.scalar_var("depth", "Depth", Types.VariableType.INTEGER, Value.from_int(0))
	var result := Graph.scalar_var("result", "Result", Types.VariableType.INTEGER, Value.from_int(0))
	result.is_output = true
	var script = Graph.build("recursive", {"0": Graph.start(),
		"A": Graph.dialogue("A", [{"id": "descend", "text": "Descend"}, {"id": "return", "text": "Return"}]), "B": Graph.dialogue("B"),
		"read": Graph.node("read", Types.NodeType.GET_INT, "getInt", {"variable": "depth", "isGlobal": true}),
		"add": Graph.node("add", Types.NodeType.PLUS, "plus", {"value2": Value.from_int(1)}),
		"depth": Graph.node("depth", Types.NodeType.SET_INT, "setInt", {"variable": "depth", "isGlobal": true}),
		"local": Graph.node("local", Types.NodeType.SET_INT, "setInt", {"variable": "result"}),
		"call": Graph.node("call", Types.NodeType.RUN_SCRIPT, "runScript", {"script": "recursive", "scriptOutputs": [{"id": "returned", "name": "Result", "type": "integer"}]}),
		"end": Graph.node("end", Types.NodeType.END, "end", {})},
		[Graph.exec("0", "depth"), Graph.exec_flow("depth", "local"), Graph.exec_flow("local", "A"),
		Graph.data_wire("read", "integer", "add", "integer-1"), Graph.data_wire("add", "integer", "depth", "integer"), Graph.data_wire("read", "integer", "local", "integer"),
		Graph.edge("A", "source-A-descend", "call", "target-call-"), Graph.edge("A", "source-A-return", "end", "target-end-"),
		Graph.edge("call", "source-call-output", "B", "target-B-"), Graph.exec("B", "end")], {"result": result})
	project.scripts = {"recursive": script}
	project.startup_script = "recursive"
	var component = start(project)
	component.select_option("descend")
	component.select_option("descend")
	check("same-script recursion owns independent caller locals", component._context.call_stack.size() == 2 and component._context.call_stack[0].saved_variables.result.value.get_int() == 1 and component._context.call_stack[1].saved_variables.result.value.get_int() == 2 and component._context.local_variables.result.value.get_int() == 3)
	check("same-script recursion owns independent node caches", not is_same(component._context.call_stack[0].saved_node_runtime_states, component._context.call_stack[1].saved_node_runtime_states))
	component.select_option("return")
	var returned = component._context.get_node_state("call").output_values.get("returned")
	check("recursive End restores caller and typed return", component.get_current_dialogue().node_id == "B" and component._context.local_variables.result.value.get_int() == 2 and returned is Value and returned.type == Types.VariableType.INTEGER and returned.get_int() == 3)
	check("Back restores recursive activation before return", component.go_back().ok and component._context.call_stack.size() == 2 and component._context.local_variables.result.value.get_int() == 3)
	component.select_option("return")
	returned = component._context.get_node_state("call").output_values.get("returned")
	check("restored recursive End repeats the typed return", returned is Value and returned.type == Types.VariableType.INTEGER and returned.get_int() == 3)
	component.advance_dialogue()
	returned = component._context.get_node_state("call").output_values.get("returned")
	check("second return preserves root locals and next typed output", component._context.call_stack.is_empty() and component._context.local_variables.result.value.get_int() == 1 and returned is Value and returned.get_int() == 2)
	var ended_availability := []
	component.rollback_availability_changed.connect(func(value): ended_availability.append(value))
	component.advance_dialogue()
	check("root End publishes empty availability", not ended_availability.is_empty() and ended_availability.back().reason == "empty")
	check("root End releases history owner", not component.is_dialogue_active() and manager._rollback_owners.is_empty())
	dispose(component)

func _test_audio_completion_and_recovery() -> void:
	var project = project_for("barrier")
	var stream := AudioStreamWAV.new()
	stream.mix_rate = 22050
	var samples := PackedByteArray()
	samples.resize(220500)
	stream.data = samples
	project.scripts[project.startup_script].resolved_assets.voice = stream
	var data: Dictionary = project.scripts[project.startup_script].nodes.B.data
	data.audio = "voice"
	data.audioAdvanceOnEnd = true
	data.audioAllowSkip = true
	var component = start(project, RefusingComponent.new())
	component.advance_dialogue()
	await process_frame
	var player = component.get_current_dialogue_audio_player()
	var lipsync := Lipsync.new()
	lipsync.source = component
	lipsync._bind_source()
	var manual_player := AudioStreamPlayer.new()
	manual_player.stream = stream
	root.add_child(manual_player)
	manual_player.play()
	var manual_lipsync := Lipsync.new()
	manual_lipsync.source = component
	manual_lipsync._bind_source()
	manual_lipsync.start_lipsync_for(manual_player)
	var notifications := [0]
	component.dialogue_updated.connect(func(_state): notifications[0] += 1)
	component.dialogue_restored.connect(func(_state): notifications[0] += 1)
	check("automatic lipsync acquires voice before refused commit", lipsync._is_playing_line_audio())
	var old_completion: Callable = player.finished.get_connections()[0].callable
	check("voice owns auto advance", component._waiting_for_audio_advance and player.playing)
	component.refuse_commit = true
	player.seek(1.0)
	player.stream_paused = true
	component.pause_dialogue()
	var recovery_result = component.go_back()
	check("failed commit recovers nonloop voice and pause controls", not recovery_result.ok and component._context.is_paused and component._waiting_for_audio_advance and component._audio_advance_allow_skip and player.has_stream_playback() and player.stream_paused and absf(player.get_playback_position() - 1.0) < 0.02)
	check("failed commit recovers dialogue audio metadata without gameplay notification", component.get_current_dialogue().audio == stream and component.get_current_dialogue().audio_key == "voice" and notifications[0] == 0)
	player.stream_paused = false
	check("failed commit preserves acquired lipsync playback identity", lipsync._is_playing_line_audio())
	check("failed commit leaves host manual lipsync untouched", manual_lipsync._manual and manual_lipsync._speaking == manual_player and manual_player.playing)
	old_completion.call()
	check("obsolete physical audio callback remains cancelled after recovery", component.get_current_dialogue().node_id == "B" and component._waiting_for_audio_advance)
	var late_lipsync := Lipsync.new()
	late_lipsync.source = component
	late_lipsync._bind_source()
	check("late lipsync binds recovered voice instead of text-only idle", late_lipsync._line_has_audio and late_lipsync._is_playing_line_audio())
	lipsync._unbind_source()
	lipsync._bind_source()
	check("rebound lipsync binds recovered voice", lipsync._line_has_audio and lipsync._is_playing_line_audio())
	lipsync._unbind_source()
	late_lipsync._unbind_source()
	manual_lipsync._unbind_source()
	lipsync.free()
	late_lipsync.free()
	manual_lipsync.free()
	manual_player.stop()
	manual_player.free()
	dispose(component)
	component = start(project)
	component.advance_dialogue()
	await process_frame
	player = component.get_current_dialogue_audio_player()
	old_completion = player.finished.get_connections()[0].callable
	check("successful Back cancels voice and auto advance", component.go_back().ok and not player.playing and not component._waiting_for_audio_advance)
	component.advance_dialogue()
	old_completion.call()
	check("stale voice completion cannot advance a later voice", component.get_current_dialogue().node_id == "B" and component._waiting_for_audio_advance)
	dispose(component)


func _test_restored_listener_restart() -> void:
	var project = project_for()
	var component = start(project)
	component.select_option("again")
	component.dialogue_restored.connect(func(_state):
		component.stop_dialogue()
		component.start_dialogue_with_script(project.startup_script))
	var lipsync := Lipsync.new()
	lipsync.source = component
	lipsync._bind_source()
	check("restored listener restart completes", component.go_back().ok and component.is_dialogue_active() and not component.get_current_dialogue().is_restored)
	check("obsolete restored event leaves fresh session lipsync active", lipsync.is_lipsync_active())
	lipsync._unbind_source()
	lipsync.free()
	dispose(component)


func _test_owned_graph_writes() -> void:
	var project = project_for()
	var character := Character.new()
	character.character_path = "friend"
	character.variables.Score = Graph.scalar_var("score", "Score", Types.VariableType.INTEGER, Value.from_int(5))
	project.characters.friend = character
	project.data_assets.item = {"id": "item", "name": "Item", "parent": "", "variables": [{"id": "score", "name": "Score", "type": Types.VariableType.INTEGER, "value": Value.from_int(3)}], "raw_overrides": {}}
	var handles = preload("res://addons/storyflow/core/storyflow_handles.gd")
	var script = Graph.build("owned", {"0": Graph.start(), "A": Graph.dialogue("A"), "B": Graph.dialogue("B"),
		"character": Graph.node("character", Types.NodeType.SET_CHARACTER_VAR, "setCharacterVar", {"characterPath": "friend", "variableName": "Score", "variableType": "integer", "value": Value.from_int(50)}),
		"data": Graph.setter("data", {"variableId": "score", "variableType": "integer"}), "pill": Graph.pill("pill", "item"),
		"value": Graph.node("value", Types.NodeType.GET_INT, "getInt", {"variable": "scoreval"})},
		[Graph.exec("0", "A"), Graph.exec("A", "character"), Graph.exec_flow("character", "data"), Graph.exec_flow("data", "B"),
		Graph.pill_wire("pill", "data"), Graph.data_wire("value", "integer", "data", handles.in_data_asset_value("integer"))], {"scoreval": Graph.scalar_var("scoreval", "ScoreValue", Types.VariableType.INTEGER, Value.from_int(30))})
	project.scripts = {"owned": script}
	project.startup_script = "owned"
	var component = start(project)
	component.advance_dialogue()
	check("graph character and Data Asset writes execute before B", manager.get_runtime_characters().friend.variables.Score.value.get_int() == 50 and manager.get_data_asset_int("item", "Score") == 30)
	check("Back restores both owned graph stores", component.go_back().ok and manager.get_runtime_characters().friend.variables.Score.value.get_int() == 5 and manager.get_data_asset_int("item", "Score") == 3)
	component.advance_dialogue()
	manager.set_data_asset_int("item", "Score", 90)
	check("Data Asset host setter invalidates history", not component.can_go_back() and manager.get_data_asset_int("item", "Score") == 90)
	dispose(component)

func _test_random_float_and_branch() -> void:
	var project = project_for()
	project.global_variables.delta = Graph.scalar_var("delta", "Delta", Types.VariableType.FLOAT, Value.from_float(0.0))
	var script = Graph.build("randoms", {"0": Graph.start(), "A": Graph.dialogue("A"), "B": Graph.dialogue("B"), "C": Graph.dialogue("C"),
		"float": Graph.node("float", Types.NodeType.RANDOM_FLOAT, "randomFloat", {"value1": Value.from_float(-10), "value2": Value.from_float(10)}),
		"write": Graph.node("write", Types.NodeType.SET_FLOAT, "setFloat", {"variable": "delta", "isGlobal": true}),
		"branch": Graph.node("branch", Types.NodeType.RANDOM_BRANCH, "randomBranch", {"randomBranchOptions": [{"id": "left", "weight": 1}, {"id": "right", "weight": 1}]})},
		[Graph.exec("0", "A"), Graph.exec("A", "write"), Graph.exec_flow("write", "branch"), Graph.data_wire("float", "float", "write", "float"),
		Graph.edge("branch", "source-branch-left", "B", "target-B-"), Graph.edge("branch", "source-branch-right", "C", "target-C-")])
	project.scripts = {"randoms": script}
	project.startup_script = "randoms"
	var component = start(project)
	seed(1234)
	var expected := randi()
	seed(1234)
	component.advance_dialogue()
	var delta: float = global_value("Delta").get_float()
	var branch: String = component.get_current_dialogue().node_id
	check("float and branch do not consume global RNG", randi() == expected)
	check("random float executed in its authored interval", delta >= -10 and delta <= 10 and delta != 0 and branch in ["B", "C"])
	var back_result = component.go_back()
	check("Back restores pre-random entry", back_result.ok)
	component.advance_dialogue()
	check("random float and branch replay exactly", global_value("Delta").get_float() == delta and component.get_current_dialogue().node_id == branch)
	dispose(component)

func _test_payload_retention() -> void:
	var project = project_for()
	project.global_variables.payload = Graph.scalar_var("payload", "Payload", Types.VariableType.STRING, Value.from_string("p".repeat(1024 * 1024)))
	var component = start(project)
	for i in 12: component.select_option("again")
	check("byte budget evicts oldest entries before count limit", component._rollback.retained_bytes <= Snapshot.MAX_BYTES and component._rollback.history.size() < 13 and component.can_go_back())
	print("Rollback diagnostics: ", component._rollback.diagnostics)
	component.go_back()
	var enormous_map := {"key".repeat(3 * 1024 * 1024): Value.from_int(1)}
	manager.get_global_variables().payload.value = Value.from_map(enormous_map)
	component.select_option("again")
	check("oversized map keys are counted before retention", component.get_rollback_availability().reason == "budget" and component._rollback.retained_bytes == 0)
	dispose(component)

func _test_missing_media() -> void:
	var project = project_for()
	var stream := AudioStreamWAV.new()
	stream.mix_rate = 22050
	var samples := PackedByteArray()
	samples.resize(220500)
	stream.data = samples
	var script = Graph.build("media", {"0": Graph.start(), "A": Graph.dialogue("A"), "B": Graph.dialogue("B"),
		"play": Graph.node("play", Types.NodeType.PLAY_AUDIO, "playAudio", {"value": Value.from_string("music"), "audioLoop": true})},
		[Graph.exec("0", "play"), Graph.edge("play", "source-play-output", "A", "target-A-"), Graph.exec("A", "B")])
	script.resolved_assets.music = stream
	project.scripts = {"media": script}
	project.startup_script = "media"
	var component = start(project)
	component.advance_dialogue()
	await process_frame
	check("persistent loop resumes without replaying dialogue events", component.go_back().ok and component._audio.is_playing() and component._audio._looping)
	component.advance_dialogue()
	script.resolved_assets.erase("music")
	check("missing loop media degrades to silence without blocking Back", component.go_back().ok and not component._audio.is_playing() and component.get_current_dialogue().node_id == "A")
	dispose(component)


func _test_reenter_tree() -> void:
	for enabled in [false, true]:
		for stopped in [false, true]:
			var project = project_for()
			project.dialogue_rollback.enabled = enabled
			var component = start(project)
			component.select_option("again")
			if stopped:
				component.stop_dialogue()
			root.remove_child(component)
			check("tree removal releases counted owner", manager._active_dialogue_count == 0 and manager._rollback_owners.is_empty())
			component.start_dialogue_with_script(project.startup_script)
			check("removed component cannot restart during teardown", not component.is_dialogue_active() and manager._active_dialogue_count == 0)
			root.add_child(component)
			component.start_dialogue_with_script(project.startup_script)
			check("readded surviving component can restart enabled=" + str(enabled) + " stopped=" + str(stopped), component.is_dialogue_active() and manager._active_dialogue_count == 1)
			check("readded component has balanced rollback ownership", manager._rollback_owners.size() == (1 if enabled else 0))
			component.select_option("again")
			check("readded component executes healthy dialogue", component.get_int_variable("Visits") == 2)
			dispose(component)
			check("final removal returns all ownership", manager._active_dialogue_count == 0 and manager._rollback_owners.is_empty())


func _test_caller_memo_after_callee_write() -> void:
	for enabled in [false, true]:
		var project = preload("res://addons/storyflow/core/storyflow_project.gd").new()
		for name in ["Flag", "Before", "After"]:
			project.global_variables[name.to_lower()] = Graph.scalar_var(name.to_lower(), name, Types.VariableType.BOOLEAN, Value.from_bool(false))
		var read = Graph.node("readFlag", Types.NodeType.GET_BOOL, "getBool", {"variable": "flag", "isGlobal": true})
		var before = Graph.node("copyBefore", Types.NodeType.SET_BOOL, "setBool", {"variable": "before", "isGlobal": true})
		var after = Graph.node("copyAfter", Types.NodeType.SET_BOOL, "setBool", {"variable": "after", "isGlobal": true})
		var call = Graph.node("call", Types.NodeType.RUN_SCRIPT, "runScript", {"script": "callee"})
		var caller_nodes = {"0": Graph.start(), "A": Graph.dialogue("A"), "readFlag": read, "copyBefore": before, "copyAfter": after, "call": call}
		var caller_edges = [Graph.exec("0", "copyBefore"), Graph.exec_flow("copyBefore", "call"), Graph.edge("call", "source-call-output", "copyAfter", "target-copyAfter-"), Graph.exec_flow("copyAfter", "A"), Graph.data_wire("readFlag", "boolean", "copyBefore", "boolean"), Graph.data_wire("readFlag", "boolean", "copyAfter", "boolean")]
		var write = Graph.node("writeFlag", Types.NodeType.SET_BOOL, "setBool", {"variable": "flag", "isGlobal": true, "value": Value.from_bool(true)})
		project.scripts.caller = Graph.build("caller", caller_nodes, caller_edges)
		project.scripts.callee = Graph.build("callee", {"0": Graph.start(), "writeFlag": write, "readFlag": read, "B": Graph.dialogue("B"), "end": Graph.node("end", Types.NodeType.END, "end", {})}, [Graph.exec("0", "writeFlag"), Graph.exec_flow("writeFlag", "B"), Graph.exec("B", "end")])
		project.startup_script = "caller"
		project.dialogue_rollback.enabled = enabled
		var component = start(project)
		check("callee evaluation sees write and consumes revision", component._evaluator.evaluate_boolean_from_node("readFlag"))
		component.advance_dialogue()
		check("caller read was memoized false before call", not component.get_bool_variable("Before"))
		check("callee global write remains true", component.get_bool_variable("Flag"))
		check("caller getter sees callee write enabled=" + str(enabled), component.get_current_dialogue().node_id == "A" and component.get_bool_variable("After"))
		dispose(component)


func _test_graph_barrier_callbacks() -> void:
	for action in ["normal", "disabled", "stop", "restart", "replace"]:
		var project = project_for("barrier")
		project.dialogue_rollback.enabled = action != "disabled"
		project.scripts.replacement = project.scripts[project.startup_script]
		var component = start(project)
		component.advance_dialogue()
		var changed := [false]
		component.rollback_availability_changed.connect(func(available):
			if available.canGoBack or changed[0] or action in ["normal", "disabled"]:
				return
			changed[0] = true
			if action == "stop":
				component.stop_dialogue()
			else:
				component.start_dialogue_with_script("replacement" if action == "replace" else project.startup_script))
		component.advance_dialogue()
		if action in ["normal", "disabled"]:
			check("normal and disabled graph barriers flow onward", component.get_current_dialogue().node_id == "C")
		else:
			check("barrier lifecycle callback fired", changed[0])
			check("barrier callback lifecycle wins", component.is_dialogue_active() == (action != "stop"))
			if action != "stop":
				check("barrier cannot follow same-ID replacement edge", component.get_current_dialogue().node_id == "A")
				component.resume_dialogue()
				check("public resume cannot follow obsolete barrier", component.get_current_dialogue().node_id == "A")
		dispose(component)
		check("barrier final count balanced", manager._active_dialogue_count == 0)


func _test_character_write_after_invalidation() -> void:
	for by_id in [false, true]:
		for action in ["reset", "replace", "missing", "disabled"]:
			for field in ["Score", "CF_NAME", "cf_image"]:
				var project = project_for()
				project.dialogue_rollback.enabled = action != "disabled"
				var character := Character.new()
				character.character_path = "friend"
				character.character_name = "Before"
				character.image_key = "before-image"
				character.variables.Score = Graph.scalar_var("score", "Score", Types.VariableType.INTEGER, Value.from_int(5))
				project.characters.friend = character
				project.character_id_index["da_0123456789abcdef0123456789abcdef"] = "friend"
				var component = start(project)
				component.select_option("again")
				var stale = manager.get_runtime_character("friend")
				var changed := [false]
				component.rollback_availability_changed.connect(func(available):
					if available.canGoBack or changed[0]:
						return
					changed[0] = true
					manager.reset_runtime_characters()
					if action == "replace":
						var replacement = character.duplicate_character()
						replacement.variables.Score.value = Value.from_int(7)
						manager.get_runtime_characters().friend = replacement
					elif action == "missing":
						manager.get_runtime_characters().erase("friend"))
				var value = Value.from_int(99) if field == "Score" else Value.from_string("After")
				var landed := true
				if by_id:
					landed = component.set_character_variable_by_id("da_0123456789abcdef0123456789abcdef", field, value)
				else:
					component.set_character_variable("friend", field, value)
				check("character mutation callbacks balanced", manager._rollback_mutation_depth == 0 and changed[0] == (action != "disabled"))
				var live = manager.get_runtime_character("friend")
				if action == "missing":
					check("missing live target not recreated", live == null)
					if by_id:
						check("ById must not report detached write success", not landed)
				else:
					var got = live.variables.Score.value.get_int() if field == "Score" else (live.character_name if field == "CF_NAME" else live.image_key)
					check("write reaches current live character " + str(by_id) + action + field, landed and got == (99 if field == "Score" else "After"))
				if action != "disabled":
					var old = stale.variables.Score.value.get_int() if field == "Score" else (stale.character_name if field == "CF_NAME" else stale.image_key)
					check("detached character remains untouched", old == (5 if field == "Score" else ("Before" if field == "CF_NAME" else "before-image")))
				dispose(component)

func _test_availability_observer_mutation() -> void:
	for action in ["back", "block", "stop", "restart", "disabled"]:
		var project = project_for()
		var component = start(project)
		var changed := [false]
		var observed := []
		component.rollback_availability_changed.connect(func(a):
			if changed[0] or not a.canGoBack:
				return
			changed[0] = true
			if action == "back":
				check("observer Back succeeds", component.go_back().ok)
			elif action == "block":
				component.block_rollback("host")
			else:
				component.stop_dialogue()
				if action != "stop":
					project.dialogue_rollback.enabled = action != "disabled"
					component.start_dialogue_with_script(project.startup_script))
		component.rollback_availability_changed.connect(func(a): observed.append(a.duplicate()))
		component.select_option("again")
		check(action + " observer mutates session", changed[0])
		check(action + " later observer receives correction", observed.size() >= 2)
		check(action + " final payload is live", not observed.is_empty() and observed.back() == component.get_rollback_availability())
		check(action + " final payload disables Back", not observed.is_empty() and not observed.back().canGoBack)
		dispose(component)

func _test_container_declaration_reentry() -> void:
	for kind in ["array", "map"]:
		for replacement_kind in ["none", "scalar", "type"]:
			for enabled in [false, true]:
				if not enabled and replacement_kind != "none":
					continue
				var project = project_for()
				project.dialogue_rollback.enabled = enabled
				var declaration := {"id":"count", "name":"Count", "type":Types.VariableType.INTEGER, "is_array":true, "value":Value.from_array([Value.from_int(1)])}
				if kind == "map":
					declaration = {"id":"count", "name":"Count", "type":Types.VariableType.MAP, "is_array":false, "key_type":Types.VariableType.STRING, "value_type":Types.VariableType.INTEGER, "value":Value.from_map({"old":Value.from_int(1)})}
				project.data_assets.item = {"id":"item", "name":"Item", "parent":"", "variables":[declaration], "raw_overrides":{}}
				var component = start(project)
				component.select_option("again")
				var changed := [false]
				component.rollback_availability_changed.connect(func(a):
					if a.canGoBack or changed[0] or replacement_kind == "none":
						return
					changed[0] = true
					var replacement = project_for()
					var live_declaration = declaration.duplicate(true)
					if replacement_kind == "scalar":
						live_declaration = {"id":"count", "name":"Count", "type":Types.VariableType.INTEGER, "is_array":false, "value":Value.from_int(6)}
					elif kind == "array":
						live_declaration.type = Types.VariableType.STRING
						live_declaration.value = Value.from_array([Value.from_string("safe")])
					else:
						live_declaration.value_type = Types.VariableType.STRING
						live_declaration.value = Value.from_map({"safe":Value.from_string("safe")})
					replacement.data_assets.item = {"id":"item", "name":"Item", "parent":"", "variables":[live_declaration], "raw_overrides":{}}
					manager.set_project(replacement))
				var landed: bool = manager.set_data_asset_array("item", "Count", [Value.from_int(99)]) if kind == "array" else manager.set_data_asset_map("item", "Count", ["new"], [Value.from_int(99)])
				check(kind + replacement_kind + " reports write result", landed == (replacement_kind == "none"))
				check(kind + " mutation scope balanced", manager._rollback_mutation_depth == 0)
				if replacement_kind != "none":
					check(kind + " replacement callback ran", changed[0])
					check(kind + " replacement overlay untouched", manager.get_data_asset_overlay().is_empty())
					if replacement_kind == "scalar":
						check(kind + " scalar replacement readable", manager.get_data_asset_int("item", "Count") == 6)
				else:
					var stored = manager.get_data_asset_variant("item", "Count")
					check(kind + " normal write stores value", stored.get_array()[0].get_int() == 99 if kind == "array" else stored.get_map()["new"].get_int() == 99)
				dispose(component)

func _test_reset_locals_invalidation() -> void:
	for action in ["normal", "disabled", "replace"]:
		var project = project_for()
		project.dialogue_rollback.enabled = action != "disabled"
		project.startup_script = "main"
		project.scripts.main = Graph.build("main", {"0":Graph.start(), "write":Graph.node("write", Types.NodeType.SET_INT, "setInt", {"variable":"x", "value":Value.from_int(7)}), "A":Graph.dialogue("A"), "B":Graph.dialogue("B")}, [Graph.exec("0", "write"), Graph.exec_flow("write", "A"), Graph.exec("A", "B")], {"x":Graph.scalar_var("x", "X", Types.VariableType.INTEGER, Value.from_int(0))})
		project.scripts.other = Graph.build("other", {"0":Graph.start(), "A":Graph.dialogue("A")}, [Graph.exec("0", "A")], {"x":Graph.scalar_var("x", "X", Types.VariableType.INTEGER, Value.from_int(11))})
		var component = start(project)
		component.advance_dialogue()
		check("local graph writes before reset", component.get_int_variable("X") == 7)
		var changed := [false]
		component.rollback_availability_changed.connect(func(a):
			if action == "replace" and not a.canGoBack and not changed[0]:
				changed[0] = true
				component.start_dialogue_with_script("other")
				component._context.local_variables.x.value = Value.from_int(17))
		component.reset_variables()
		check(action + " reset uses current script", component.get_int_variable("X") == (11 if action == "replace" else 0))
		check(action + " reset clears old history", not component.can_go_back() and not component.go_back().ok)
		check(action + " reset scope balanced", manager._rollback_mutation_depth == 0)
		if action == "replace":
			check("reset callback replaced script", changed[0])
		dispose(component)
