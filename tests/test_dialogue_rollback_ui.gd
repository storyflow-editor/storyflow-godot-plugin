extends SceneTree
const Component = preload("res://addons/storyflow/core/storyflow_component.gd")
const Importer = preload("res://addons/storyflow/editor/storyflow_importer.gd")
const Manager = preload("res://addons/storyflow/core/storyflow_manager.gd")
var checks := 0
var failures := 0

func _check(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("FAIL: %s" % label)

func _initialize() -> void:
	await process_frame
	var manager := Manager.new()
	manager.name = "StoryFlowRuntime"
	root.add_child(manager)
	var project := Importer.new().import_project("res://tests/fixtures/dialogue-rollback-v1/purchase", "user://rollback_ui_import")
	for path in ["res://addons/storyflow/ui/storyflow_dialogue_ui.tscn", "res://addons/storyflow/ui/storyflow_dialogue_ui_portrait.tscn"]:
		manager.set_project(project)
		var component := Component.new()
		component.trace_enabled = false
		var default_ui: Node = load(path).instantiate()
		_check(path + " default has no injected Back", default_ui.get_node_or_null("%BackButton") == null)
		default_ui.free()
		component.dialogue_ui_scene = _authored_back_scene(path)
		root.add_child(component)
		component.start_dialogue_with_script(project.startup_script)
		var ui: Node = component._dialogue_ui_instance
		var back: Button = ui.get_node_or_null("%BackButton")
		_check(path + " binds authored optional Back", back != null)
		if back and component.has_method("go_back"):
			_check("no history disables Back", back.disabled)
			var stale_button: Button = ui.options_container.get_child(0)
			component.select_option("buy")
			_check("history enables Back", not back.disabled)
			ui.set("author_allows_back", false)
			_check("authored disabled wins", back.disabled)
			ui.set("author_allows_back", true)
			ui.initialize_with_component(component)
			ui.initialize_with_component(component)
			_check("reinitialize keeps single restored subscription", component.get_signal_connection_list("dialogue_restored").size() == 1)
			back.pressed.emit()
			_check("Back refreshes native text", ui.text_label.text == component.get_current_dialogue().text)
			_check("restored text fully revealed", ui.text_label.visible_characters == -1)
			_check("restored options present once", ui.options_container.get_child_count() == component.get_current_dialogue().options.size())
			stale_button.pressed.emit()
			_check("stale removed choice cannot mutate restored line", component.get_current_dialogue().node_id == "A")
			ui.select_option("leave")
			_check("restored line accepts next option", component.get_current_dialogue().node_id == "C")
		component.stop_dialogue()
		root.remove_child(component)
		component.free()
		await process_frame
		await _test_persistent_restore_listener(manager, project, path)
		await _test_history_eviction(manager, path)
		await _test_restored_audio_redraw(manager, path)
	# Custom native scenes may omit the optional Back button entirely.
	manager.set_project(project)
	var custom: Node = load("res://addons/storyflow/ui/storyflow_dialogue_ui.tscn").instantiate()
	var custom_component := Component.new()
	custom_component.trace_enabled = false
	root.add_child(custom_component)
	root.add_child(custom)
	custom.initialize_with_component(custom_component)
	custom_component.start_dialogue_with_script(project.startup_script)
	custom_component.select_option("buy")
	_check("custom scene without Back still restores", custom_component.go_back().ok and custom.text_label.text == custom_component.get_current_dialogue().text)
	custom.free()
	custom_component.stop_dialogue()
	custom_component.free()
	project.dialogue_rollback.enabled = false
	manager.set_project(project)
	var disabled := Component.new()
	disabled.trace_enabled = false
	disabled.dialogue_ui_scene = _authored_back_scene("res://addons/storyflow/ui/storyflow_dialogue_ui.tscn")
	root.add_child(disabled)
	disabled.start_dialogue_with_script(project.startup_script)
	disabled.select_option("buy")
	_check("disabled feature keeps native Back disabled", disabled._dialogue_ui_instance.get_node("%BackButton").disabled)
	disabled.stop_dialogue()
	disabled.free()
	print("Dialogue rollback UI: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)


func _test_persistent_restore_listener(manager: Node, project, path: String) -> void:
	manager.set_project(project)
	var component := Component.new()
	component.trace_enabled = false
	root.add_child(component)
	component.start_dialogue_with_script(project.startup_script)
	component.select_option("buy")
	component.dialogue_restored.connect(func(_state):
		component.stop_dialogue()
		component.start_dialogue_with_script(project.startup_script)
		component.select_option("leave"))
	var ui: Node = load(path).instantiate()
	root.add_child(ui)
	ui.initialize_with_component(component)
	_check(path + " earlier restoration listener restarts", component.go_back().ok and component.get_current_dialogue().node_id == "C")
	_check(path + " persistent UI ignores obsolete restored state", ui.text_label.text == component.get_current_dialogue().text and ui.options_container.get_child_count() == component.get_current_dialogue().options.size())
	ui.free()
	component.stop_dialogue()
	component.free()
	await process_frame


func _test_history_eviction(manager: Node, path: String) -> void:
	var project := Importer.new().import_project("res://tests/fixtures/dialogue-rollback-v1/same-node", "user://rollback_ui_eviction")
	project.dialogue_rollback.historyLimit = 1
	manager.set_project(project)
	var component := Component.new()
	component.trace_enabled = false
	component.dialogue_ui_scene = _authored_back_scene(path)
	root.add_child(component)
	component.start_dialogue_with_script(project.startup_script)
	for i in 3:
		component.select_option("again")
	var back: Button = component._dialogue_ui_instance.get_node("%BackButton")
	_check(path + " capped history keeps newest Back enabled", not back.disabled and component.get_rollback_availability().steps == 1)
	back.pressed.emit()
	_check(path + " eviction disables Back after retained step", back.disabled and not component.can_go_back())
	component.stop_dialogue()
	component.free()
	await process_frame


func _authored_back_scene(path: String) -> PackedScene:
	var authored: Node = load(path).instantiate()
	var button := Button.new()
	button.name = "BackButton"
	button.text = "Back"
	button.custom_minimum_size = Vector2(0, 44)
	authored.get_node("%AdvanceButton").get_parent().add_child(button)
	button.owner = authored
	button.unique_name_in_owner = true
	var scene := PackedScene.new()
	scene.pack(authored)
	authored.free()
	return scene


func _test_restored_audio_redraw(manager: Node, path: String) -> void:
	var project = Importer.new().import_project("res://tests/fixtures/dialogue-rollback-v1/barrier", "user://rollback_ui_audio")
	var script = project.scripts[project.startup_script]
	var stream := AudioStreamWAV.new()
	stream.mix_rate = 22050
	var samples := PackedByteArray()
	samples.resize(220500)
	stream.data = samples
	script.resolved_assets.voice = stream
	script.nodes.A.data.audio = "voice"
	script.nodes.A.data.audioAdvanceOnEnd = true
	script.nodes.A.data.audioAllowSkip = false
	project.global_variables.review = {"id": "review", "name": "Review", "type": 2, "value": preload("res://addons/storyflow/core/storyflow_variant.gd").from_int(0)}
	manager.set_project(project)
	var component := Component.new()
	component.trace_enabled = false
	component.dialogue_ui_scene = load(path)
	root.add_child(component)
	component.start_dialogue_with_script(project.startup_script)
	component.get_current_dialogue_audio_player().finished.emit()
	_check(path + " voice completion reaches B", component.get_current_dialogue().node_id == "B")
	_check(path + " Back restores silent Continue", component.go_back().ok and component._dialogue_ui_instance.advance_button.visible)
	component.set_int_variable("Review", 1)
	var state = component.get_current_dialogue()
	_check(path + " restored redraw retains silent audio flags", state.is_restored and not state.audio_advance_on_end and not state.audio_allow_skip)
	_check(path + " restored redraw exposes Continue", component._dialogue_ui_instance.advance_button.visible and not component._waiting_for_audio_advance)
	component.advance_dialogue()
	_check(path + " restored Continue reaches B", component.get_current_dialogue().node_id == "B")
	component.start_dialogue_with_script(project.startup_script)
	_check(path + " fresh entry recovers audio gating", component.get_current_dialogue().audio_advance_on_end and not component._dialogue_ui_instance.advance_button.visible)
	component.stop_dialogue()
	component.free()
	await process_frame
