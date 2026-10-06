extends SceneTree
## Shared exported graphs exercise rollback through the native public component.

const Component = preload("res://addons/storyflow/core/storyflow_component.gd")
const Importer = preload("res://addons/storyflow/editor/storyflow_importer.gd")
const Manager = preload("res://addons/storyflow/core/storyflow_manager.gd")
const Value = preload("res://addons/storyflow/core/storyflow_variant.gd")
const FIXTURES := "res://tests/fixtures/dialogue-rollback-v1/"
var checks := 0
var failures := 0
var manager: Node
var scratch := ""

func _initialize() -> void:
	await process_frame
	scratch = "user://rollback_%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(scratch)
	manager = Manager.new()
	manager.name = "StoryFlowRuntime"
	root.add_child(manager)
	_test_settings()
	for case_name in ["purchase", "nested-loops", "same-node", "random", "barrier"]:
		_run_rollback_case(case_name)
	print("Dialogue rollback: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)

func _check(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("FAIL: %s" % label)

func _json(path: String):
	return JSON.parse_string(FileAccess.get_file_as_string(path))

func _test_settings() -> void:
	var importer := Importer.new()
	for vector in _json(FIXTURES + "settings.json"):
		var metadata := {}
		if vector.has("input"):
			metadata.dialogueRollback = vector.input
		var document := {"version": "1.0", "metadata": metadata}
		var inline_project := importer.import_project_from_json(document)
		_check("inline settings " + vector.name, _equal(inline_project.get("dialogue_rollback"), vector.expected))
		var build := scratch.path_join("settings")
		DirAccess.make_dir_recursive_absolute(build)
		var file := FileAccess.open(build.path_join("project.json"), FileAccess.WRITE)
		file.store_string(JSON.stringify(document))
		file.close()
		var disk_project := importer.import_project(build, scratch.path_join("import"))
		_check("disk settings " + vector.name, disk_project != null and _equal(disk_project.get("dialogue_rollback"), vector.expected))
		var reloaded := importer.load_project_local(scratch.path_join("import"))
		_check("cached settings " + vector.name, reloaded != null and _equal(reloaded.get("dialogue_rollback"), vector.expected))

func _new_case(case_name: String):
	var project := Importer.new().import_project(FIXTURES + case_name, scratch.path_join(case_name))
	manager.set_project(project)
	var component := Component.new()
	component.trace_enabled = false
	root.add_child(component)
	component.start_dialogue_with_script(project.startup_script)
	return component

func _dispose(component) -> void:
	component.stop_dialogue()
	root.remove_child(component)
	component.free()

func _plain(value):
	if value is Value:
		if value.is_map():
			var entries := []
			for key in value.get_map():
				entries.append({"key": key, "value": _plain(value.get_map()[key])})
			return entries
		if not value.get_array().is_empty():
			return value.get_array().map(_plain)
		match value.type:
			1: return value.get_bool()
			2: return value.get_int()
			3: return value.get_float()
		if value.type == 4 and not value.string_is_literal:
			var resolved = preload("res://addons/storyflow/core/storyflow_localization.gd").look_up(manager.get_localization(), null, manager.get_project().global_strings, value.get_string(), "en")
			return value.get_string() if resolved == null else resolved
		return value.get_string()
	return value

func _globals() -> Dictionary:
	var values := {}
	for variable in manager.get_global_variables().values():
		var value = variable.value
		values[variable.name] = value.get_array().map(_plain) if variable.get("is_array", false) else _plain(value)
	return values

func _run_rollback_case(case_name: String) -> void:
	var component = _new_case(case_name)
	_check(case_name + " exposes native rollback API", component.has_method("go_back") and component.has_method("get_rollback_availability"))
	if not component.has_method("go_back"):
		_dispose(component)
		return
	var remembered := {}
	for action in _json(FIXTURES + "expected-traces.json")[case_name]:
		match action.op:
			"choose": component.select_option(action.id)
			"advance": component.advance_dialogue()
			"back": _check(case_name + " Back succeeds", component.go_back().ok)
			"block": component.block_rollback("fixture")
			"assert":
				var expected: Dictionary = action.state
				var state = component.get_current_dialogue()
				_check(case_name + " dialogue " + expected.dialogue, state != null and state.node_id == expected.dialogue)
				var globals := _globals()
				for key in expected.get("globals", {}):
					_check(case_name + " global " + key, _equal(globals.get(key), expected.globals[key]))
				if expected.has("canGoBack"):
					_check(case_name + " availability", component.can_go_back() == expected.canGoBack)
				if expected.has("options") and state:
					var ids := []
					for option in state.options: ids.append(option.id)
					_check(case_name + " option identities", ids == expected.options)
				if expected.has("callDepth"):
					_check(case_name + " call depth", component._context.call_stack.size() == int(expected.callDepth))
				if expected.has("loopCursors"):
					var cursors := []
					if not component._context.call_stack.is_empty():
						var caller = component._context.call_stack.back()
						if caller.get("saved_loop_stack") != null:
							for frame in caller.saved_loop_stack: cursors.append(frame.current_index)
					_check(case_name + " caller loop cursors " + str(expected.loopCursors), _equal(cursors, expected.loopCursors))
				for key in expected.get("rememberGlobals", []): remembered[key] = globals[key]
				for key in expected.get("sameGlobals", []): _check(case_name + " deterministic " + key, globals[key] == remembered[key])
	_dispose(component)

func _equal(actual, expected) -> bool:
	if actual is Dictionary and expected is Dictionary:
		if actual.size() != expected.size(): return false
		for key in actual:
			if not expected.has(key) or not _equal(actual[key], expected[key]): return false
		return true
	if actual is Array and expected is Array:
		if actual.size() != expected.size(): return false
		for i in actual.size():
			if not _equal(actual[i], expected[i]): return false
		return true
	if typeof(actual) in [TYPE_INT, TYPE_FLOAT] and typeof(expected) in [TYPE_INT, TYPE_FLOAT]:
		return actual == expected
	return typeof(actual) == typeof(expected) and actual == expected
