@tool
class_name StoryFlowImportPlugin
extends EditorImportPlugin


func _get_importer_name() -> String:
	return "storyflow.project"


func _get_visible_name() -> String:
	return "StoryFlow Project"


func _get_recognized_extensions() -> PackedStringArray:
	return PackedStringArray(["storyflow"])


func _get_save_extension() -> String:
	return "tres"


func _get_resource_type() -> String:
	return "Resource"


func _get_preset_count() -> int:
	return 1


func _get_preset_name(preset_index: int) -> String:
	return "Default"


func _get_import_options(path: String, preset_index: int) -> Array[Dictionary]:
	return [
		{
			"name": "output_directory",
			"default_value": "res://storyflow",
			"hint": PROPERTY_HINT_DIR,
		}
	]


func _get_import_order() -> int:
	return 0


func _get_priority() -> float:
	return 1.0


func _import(source_file: String, save_path: String, options: Dictionary,
		platform_variants: Array[String], gen_files: Array[String]) -> Error:
	var build_dir := source_file.get_base_dir()
	var output_dir: String = options.get("output_directory", "res://storyflow")

	var importer := StoryFlowImporter.new()
	var project := importer.import_project(build_dir, output_dir)

	if not project:
		push_error("[StoryFlow] Import failed for %s" % source_file)
		return ERR_PARSE_ERROR

	# Godot's EditorImportPlugin requires saving a Resource at save_path.
	# The real project data lives in memory (loaded via StoryFlowImporter at runtime).
	# Save a lightweight marker resource so Godot's import pipeline is satisfied.
	var marker := Resource.new()
	marker.set_meta("storyflow_project_title", project.title)
	marker.set_meta("storyflow_build_dir", build_dir)
	var save_file := save_path + "." + _get_save_extension()
	var err := ResourceSaver.save(marker, save_file)
	if err != OK:
		push_error("[StoryFlow] Failed to save import marker: %s" % error_string(err))
		return err

	# Notify the manager if it's loaded
	var mgr := Engine.get_singleton("StoryFlowRuntime") if Engine.has_singleton("StoryFlowRuntime") else null
	if not mgr:
		# Try the autoload path
		var tree := EditorInterface.get_editor_main_screen().get_tree() if Engine.is_editor_hint() else null
		if tree:
			mgr = tree.root.get_node_or_null("/root/StoryFlowRuntime")
	if mgr and mgr.has_method("set_project"):
		mgr.set_project(project)

	return OK
