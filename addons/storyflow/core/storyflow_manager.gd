class_name StoryFlowManager
extends Node

# =============================================================================
# Project
# =============================================================================

const DEFAULT_IMPORT_META_PATH := "res://storyflow/storyflow_import_meta.json"

var _project: StoryFlowProject = null
var _global_variables: Dictionary = {}
var _runtime_characters: Dictionary = {}
var _used_once_only_options: Dictionary = {}
var _active_dialogue_count: int = 0


func _ready() -> void:
	_auto_load_project()


## Attempt to load the project from the saved import metadata.
func _auto_load_project() -> void:
	if not FileAccess.file_exists(DEFAULT_IMPORT_META_PATH):
		return

	var file := FileAccess.open(DEFAULT_IMPORT_META_PATH, FileAccess.READ)
	if not file:
		return

	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_warning("[StoryFlow] Failed to parse import metadata")
		return

	var meta: Dictionary = json.data
	var build_dir: String = meta.get("build_dir", "")
	var output_dir: String = meta.get("output_dir", "")
	if build_dir.is_empty():
		push_warning("[StoryFlow] Import metadata missing build_dir")
		return

	var importer := StoryFlowImporter.new()
	var project := importer.import_project(build_dir, output_dir)
	if project:
		set_project(project)


# =============================================================================
# Project Access
# =============================================================================

func get_project() -> StoryFlowProject:
	return _project


func set_project(project: StoryFlowProject) -> void:
	_project = project
	if _project:
		_initialize_from_project()


func has_project() -> bool:
	return _project != null


func get_script(path: String) -> StoryFlowScript:
	if _project:
		return _project.get_script(path)
	return null


func get_all_script_paths() -> PackedStringArray:
	if _project:
		return _project.get_all_script_paths()
	return PackedStringArray()


# =============================================================================
# Global Variables
# =============================================================================

func get_global_variables() -> Dictionary:
	return _global_variables


func set_global_variable(var_id: String, value: StoryFlowVariant) -> void:
	if _global_variables.has(var_id):
		_global_variables[var_id]["value"] = value


func get_global_variable(var_id: String) -> Dictionary:
	return _global_variables.get(var_id, {})


func reset_global_variables() -> void:
	if _project:
		_global_variables = StoryFlowVariant.deep_copy_variables(_project.global_variables)


# =============================================================================
# Runtime Characters
# =============================================================================

func get_runtime_characters() -> Dictionary:
	return _runtime_characters


func get_runtime_character(character_path: String) -> StoryFlowCharacter:
	var normalized := StoryFlowCharacter.normalize_path(character_path)
	return _runtime_characters.get(normalized, null)


func reset_runtime_characters() -> void:
	if _project:
		_runtime_characters.clear()
		for path in _project.characters:
			var original: StoryFlowCharacter = _project.characters[path]
			_runtime_characters[path] = original.duplicate_character()


# =============================================================================
# Once-Only Options
# =============================================================================

func get_used_once_only_options() -> Dictionary:
	return _used_once_only_options


func mark_option_used(key: String) -> void:
	_used_once_only_options[key] = true


func is_option_used(key: String) -> bool:
	return _used_once_only_options.has(key)


# =============================================================================
# Active Dialogue Tracking
# =============================================================================

func is_dialogue_active() -> bool:
	return _active_dialogue_count > 0


func register_dialogue_start() -> void:
	_active_dialogue_count += 1


func register_dialogue_end() -> void:
	_active_dialogue_count = maxi(0, _active_dialogue_count - 1)


# =============================================================================
# Save / Load
# =============================================================================

func save_to_slot(slot_name: String) -> bool:
	return StoryFlowSaveData.save_to_slot(
		slot_name, _global_variables, _runtime_characters, _used_once_only_options
	)


func load_from_slot(slot_name: String) -> bool:
	if is_dialogue_active():
		push_warning("[StoryFlow] Cannot load while dialogue is active")
		return false

	var data := StoryFlowSaveData.load_from_slot(slot_name)
	if data.is_empty():
		return false

	# Restore global variables
	if data.has("global_variables"):
		_global_variables = data["global_variables"]

	# Restore runtime characters (merge saved variable state into existing characters)
	if data.has("runtime_characters"):
		var saved_chars: Dictionary = data["runtime_characters"]
		for path in saved_chars:
			if _runtime_characters.has(path):
				var character: StoryFlowCharacter = _runtime_characters[path]
				var saved_vars: Dictionary = saved_chars[path]
				for vname in saved_vars:
					if character.variables.has(vname):
						character.variables[vname] = saved_vars[vname]

	# Restore once-only options
	if data.has("used_once_only_options"):
		_used_once_only_options = data["used_once_only_options"]

	return true


func does_save_exist(slot_name: String) -> bool:
	return StoryFlowSaveData.does_save_exist(slot_name)


func delete_save(slot_name: String) -> void:
	StoryFlowSaveData.delete_save(slot_name)


func list_save_slots() -> PackedStringArray:
	return StoryFlowSaveData.list_save_slots()


# =============================================================================
# Reset
# =============================================================================

func reset_all_state() -> void:
	reset_global_variables()
	reset_runtime_characters()
	_used_once_only_options.clear()


# =============================================================================
# Internal
# =============================================================================

func _initialize_from_project() -> void:
	_global_variables = StoryFlowVariant.deep_copy_variables(_project.global_variables)

	_runtime_characters.clear()
	for path in _project.characters:
		var original: StoryFlowCharacter = _project.characters[path]
		_runtime_characters[path] = original.duplicate_character()

	_used_once_only_options.clear()
	_active_dialogue_count = 0

