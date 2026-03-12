@tool
extends EditorPlugin

var _import_plugin: StoryFlowImportPlugin = null
var _editor_dock: StoryFlowEditorDock = null


const MANAGER_AUTOLOAD_NAME := "StoryFlowManager"
const MANAGER_SCRIPT_PATH := "res://addons/storyflow/core/storyflow_manager.gd"


func _enter_tree() -> void:
	add_custom_type(
		"StoryFlowComponent",
		"Node",
		preload("core/storyflow_component.gd"),
		preload("icons/storyflow_icon.svg") if FileAccess.file_exists("res://addons/storyflow/icons/storyflow_icon.svg") else null
	)

	# Register StoryFlowManager autoload if not already present
	if not ProjectSettings.has_setting("autoload/" + MANAGER_AUTOLOAD_NAME):
		add_autoload_singleton(MANAGER_AUTOLOAD_NAME, MANAGER_SCRIPT_PATH)

	# Register import plugin for .storyflow files
	_import_plugin = StoryFlowImportPlugin.new()
	add_import_plugin(_import_plugin)

	# Add editor dock
	_editor_dock = preload("editor/storyflow_editor_dock.gd").new()
	_editor_dock.name = "StoryFlow"
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _editor_dock)


func _exit_tree() -> void:
	remove_custom_type("StoryFlowComponent")

	if _import_plugin:
		remove_import_plugin(_import_plugin)
		_import_plugin = null

	if _editor_dock:
		remove_control_from_docks(_editor_dock)
		_editor_dock.queue_free()
		_editor_dock = null

	# Remove autoload when plugin is disabled
	if ProjectSettings.has_setting("autoload/" + MANAGER_AUTOLOAD_NAME):
		remove_autoload_singleton(MANAGER_AUTOLOAD_NAME)
