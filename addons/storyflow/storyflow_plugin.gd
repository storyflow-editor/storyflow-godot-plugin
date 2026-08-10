@tool
extends EditorPlugin

var _import_plugin: StoryFlowImportPlugin = null
var _inspector_plugin: EditorInspectorPlugin = null
var _editor_dock: StoryFlowEditorDock = null
var _toolbar_button: Button = null
var _icon: Texture2D = null
var _component_icon_missing := false


const MANAGER_AUTOLOAD_NAME := "StoryFlowRuntime"
const MANAGER_SCRIPT_PATH := "res://addons/storyflow/core/storyflow_manager.gd"
const COMPONENT_ICON_PATH := "res://addons/storyflow/icons/storyflow_icon.svg"
const LOGO_PATH := "res://addons/storyflow/icons/storyflow_logo.svg"


func _enter_tree() -> void:
	# The icons resolve at runtime, never preload: preload resolves at parse time, and on the
	# very first open of a fresh project the SVGs' imported textures do not exist yet - the old
	# parse error took the whole plugin down before any code ran. A runtime load can still come
	# back null in that same pre-import window, so when either icon is missing we retry on
	# filesystem_changed until the editor's first import scan lands (_on_editor_fs_changed).
	var component_icon := _load_texture(COMPONENT_ICON_PATH)
	_component_icon_missing = component_icon == null
	add_custom_type(
		"StoryFlowComponent",
		"Node",
		preload("core/storyflow_component.gd"),
		component_icon
	)

	# Load icon
	_icon = _load_texture(LOGO_PATH)

	# Register StoryFlowManager autoload if not already present
	if not ProjectSettings.has_setting("autoload/" + MANAGER_AUTOLOAD_NAME):
		add_autoload_singleton(MANAGER_AUTOLOAD_NAME, MANAGER_SCRIPT_PATH)

	# Register import plugin for .storyflow files
	_import_plugin = StoryFlowImportPlugin.new()
	add_import_plugin(_import_plugin)

	# Register inspector plugin for script_path dropdown
	_inspector_plugin = preload("editor/storyflow_inspector_plugin.gd").new()
	add_inspector_plugin(_inspector_plugin)

	# Add editor dock
	_editor_dock = preload("editor/storyflow_editor_dock.gd").new()
	_editor_dock.name = "StoryFlow"
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _editor_dock)
	_editor_dock.connection_state_changed.connect(_on_connection_state_changed)

	# Add toolbar button
	_toolbar_button = Button.new()
	_toolbar_button.flat = true
	_toolbar_button.focus_mode = Control.FOCUS_NONE
	if _icon:
		# Scale SVG to editor icon size by creating an ImageTexture
		var img: Image = _icon.get_image()
		img.resize(16, 16, Image.INTERPOLATE_LANCZOS)
		_toolbar_button.icon = ImageTexture.create_from_image(img)
	_toolbar_button.text = "Connect"
	_toolbar_button.tooltip_text = "Connect to StoryFlow Editor"
	_toolbar_button.pressed.connect(_on_toolbar_pressed)
	add_control_to_container(CONTAINER_TOOLBAR, _toolbar_button)

	if _component_icon_missing or _icon == null:
		EditorInterface.get_resource_filesystem().filesystem_changed.connect(_on_editor_fs_changed)


func _load_texture(path: String) -> Texture2D:
	if ResourceLoader.exists(path, "Texture2D"):
		return load(path) as Texture2D
	return null


func _on_editor_fs_changed() -> void:
	# First-open heal: the UI was built before the import scan produced the icon textures.
	# Re-resolve whatever is still missing and stop listening once everything is in place.
	if _component_icon_missing:
		var component_icon := _load_texture(COMPONENT_ICON_PATH)
		if component_icon:
			remove_custom_type("StoryFlowComponent")
			add_custom_type(
				"StoryFlowComponent",
				"Node",
				preload("core/storyflow_component.gd"),
				component_icon
			)
			_component_icon_missing = false
	if _icon == null:
		_icon = _load_texture(LOGO_PATH)
		if _icon:
			if _toolbar_button:
				var img: Image = _icon.get_image()
				img.resize(16, 16, Image.INTERPOLATE_LANCZOS)
				_toolbar_button.icon = ImageTexture.create_from_image(img)
			if _editor_dock:
				_editor_dock.refresh_logo()
	if not _component_icon_missing and _icon != null:
		EditorInterface.get_resource_filesystem().filesystem_changed.disconnect(_on_editor_fs_changed)


func _exit_tree() -> void:
	var fs := EditorInterface.get_resource_filesystem()
	if fs.filesystem_changed.is_connected(_on_editor_fs_changed):
		fs.filesystem_changed.disconnect(_on_editor_fs_changed)

	remove_custom_type("StoryFlowComponent")

	if _toolbar_button:
		remove_control_from_container(CONTAINER_TOOLBAR, _toolbar_button)
		_toolbar_button.queue_free()
		_toolbar_button = null

	if _inspector_plugin:
		remove_inspector_plugin(_inspector_plugin)
		_inspector_plugin = null

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


func _on_toolbar_pressed() -> void:
	if _editor_dock:
		if _editor_dock.is_connected_to_editor():
			_editor_dock.request_sync()
		else:
			_editor_dock.connect_to_editor()


func _on_connection_state_changed(is_connected: bool) -> void:
	if _toolbar_button:
		if is_connected:
			_toolbar_button.text = "Sync"
			_toolbar_button.tooltip_text = "Sync project from StoryFlow Editor"
		else:
			_toolbar_button.text = "Connect"
			_toolbar_button.tooltip_text = "Connect to StoryFlow Editor"
