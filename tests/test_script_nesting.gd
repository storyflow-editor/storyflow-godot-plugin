extends SceneTree
## Project script nesting imports and real runScript execution boundaries.

const Component = preload("res://addons/storyflow/core/storyflow_component.gd")
const Graph = preload("res://tests/data_asset_test_graph.gd")
const Importer = preload("res://addons/storyflow/editor/storyflow_importer.gd")
const Manager = preload("res://addons/storyflow/core/storyflow_manager.gd")
const Types = preload("res://addons/storyflow/core/storyflow_types.gd")
const WebSocketSync = preload("res://addons/storyflow/editor/storyflow_websocket_sync.gd")

var _checks := 0
var _failures := 0
var _temp_root := ""
var _manager: Node


func _initialize() -> void:
	await process_frame
	_temp_root = OS.get_user_data_dir().path_join("sf_script_nesting_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(_temp_root)
	_manager = Manager.new()
	_manager.name = "StoryFlowRuntime"
	root.add_child(_manager)
	_test_import_values()
	_test_disk_reload_and_sync()
	for limit in [1, 3, 25, 100]:
		_test_execution_boundary({"maxScriptNesting": limit}, limit)
	_test_execution_boundary({}, 20)
	_test_execution_boundary({"maxScriptNesting": 3.5}, 20)
	_remove_temp_tree(_temp_root)
	print("Script nesting: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures else 0)


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		printerr("FAIL: %s" % label)


func _test_import_values() -> void:
	var importer := Importer.new()
	for value in [1, 20, 100, 25.0]:
		var project := importer.import_project_from_json({"metadata": {"maxScriptNesting": value}})
		_check("inline accepts integer number %s" % str(value), project.get("max_script_nesting") == value)
	for value in [null, false, true, "3", "", [], {}, 0, -1, 101, 2.5, NAN, INF, -INF]:
		var project := importer.import_project_from_json({"metadata": {"maxScriptNesting": value}})
		_check("inline defaults invalid value %s" % str(value), project.get("max_script_nesting") == 20)
	for payload in [{"version": "1.0"}, {"metadata": {}}, {"metadata": {"title": "Legacy"}}]:
		var project := importer.import_project_from_json(payload)
		_check("inline missing field resets to 20", project.get("max_script_nesting") == 20)


func _test_disk_reload_and_sync() -> void:
	var project_root := _temp_root.path_join("project")
	var build := project_root.path_join("build")
	var output := _temp_root.path_join("import")
	DirAccess.make_dir_recursive_absolute(build)
	var importer := Importer.new()
	var sync := WebSocketSync.new()
	sync.set_output_dir(output)
	var seen := {"project": null, "errors": -1}
	sync.sync_complete.connect(func(project, errors):
		seen.project = project
		seen.errors = errors)
	# Reusing the same destination exercises a legacy reimport after a custom setting.
	for row in [[{"maxScriptNesting": 25}, 25], [{}, 20], [{"maxScriptNesting": 0}, 20], [{"maxScriptNesting": 2.5}, 20], [{"maxScriptNesting": "3"}, 20], [{"maxScriptNesting": true}, 20]]:
		var metadata: Dictionary = row[0]
		var expected: int = row[1]
		var file := FileAccess.open(build.path_join("project.json"), FileAccess.WRITE)
		file.store_string(JSON.stringify({"version": "1.0", "metadata": metadata}))
		file.close()
		var project := importer.import_project(build, output)
		_check("disk imports %s" % str(metadata), project != null and project.get("max_script_nesting") == expected)
		var reloaded := importer.load_project_local(output)
		_check("local reload preserves normalized limit", reloaded != null and reloaded.get("max_script_nesting") == expected)
		sync._handle_project_updated({"payload": {"projectPath": project_root}})
		_check("WebSocket sync delivers normalized limit", seen.project != null and seen.project.get("max_script_nesting") == expected)
		_check("WebSocket sync has no import errors", seen.errors == 0)


func _test_execution_boundary(metadata: Dictionary, limit: int) -> void:
	var project := Importer.new().import_project_from_json({"metadata": metadata})
	# Each call pauses for dialogue, so the configured script stack is exercised
	# without depending on the engine's synchronous GDScript recursion limit.
	var script := Graph.build("Recursive", {
		"0": Graph.start(),
		"PAUSE": Graph.dialogue("PAUSE"),
		"CALL": Graph.node("CALL", Types.NodeType.RUN_SCRIPT, "runScript", {"script": "Recursive"}),
	}, [Graph.exec("0", "PAUSE"), Graph.exec("PAUSE", "CALL")])
	project.scripts[script.script_path] = script
	_manager.set_project(project)
	var component := Component.new()
	component.dialogue_ui_scene = null
	component.trace_enabled = false
	root.add_child(component)
	var started: Array = []
	var errors: Array = []
	component.script_started.connect(func(path): started.append(path))
	component.error_occurred.connect(func(message): errors.append(message))
	component.start_dialogue_with_script("Recursive")
	for depth in range(limit):
		component.advance_dialogue()
	_check("limit %d permits exactly that many nested calls" % limit,
		started.size() == limit + 1 and errors.is_empty() and component._context.current_node_id == "PAUSE")
	component.advance_dialogue()
	_check("limit %d rejects the next nested call" % limit, started.size() == limit + 1 and errors.size() == 1)
	_check("limit %d error reports the active setting" % limit,
		errors.size() == 1 and str(errors[0]).contains("(%d)" % limit) and str(errors[0]).contains("script nesting"))
	component.stop_dialogue()
	root.remove_child(component)
	component.free()


func _remove_temp_tree(path: String) -> void:
	# Cleanup is confined to the unique directory created by this test.
	if path != _temp_root and not path.begins_with(_temp_root + "/"):
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for name in dir.get_files():
		DirAccess.remove_absolute(path.path_join(name))
	for name in dir.get_directories():
		_remove_temp_tree(path.path_join(name))
	DirAccess.remove_absolute(path)
