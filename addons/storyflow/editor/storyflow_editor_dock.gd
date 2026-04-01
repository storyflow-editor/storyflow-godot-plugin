@tool
class_name StoryFlowEditorDock
extends Control

signal connection_state_changed(is_connected: bool)

const SETTINGS_PATH := "res://addons/storyflow/.storyflow_settings.cfg"
const DEFAULT_OUTPUT_DIR := "res://storyflow"

var _project_path_edit: LineEdit
var _output_path_edit: LineEdit
var _import_button: Button
var _status_label: Label
var _sync_port_edit: SpinBox
var _connect_button: Button
var _disconnect_button: Button
var _sync_button: Button
var _sync_status_label: Label
var _file_dialog: FileDialog
var _ws_sync: StoryFlowWebSocketSync = null
var _poll_timer: Timer = null


func _ready() -> void:
	_build_ui()
	_load_settings()


func _exit_tree() -> void:
	_save_settings()


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	# === Header ===
	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 6)
	var header_icon := TextureRect.new()
	header_icon.custom_minimum_size = Vector2(24, 24)
	header_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	header_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	if FileAccess.file_exists("res://addons/storyflow/icons/storyflow_logo.svg"):
		var logo_tex: Texture2D = load("res://addons/storyflow/icons/storyflow_logo.svg") as Texture2D
		if logo_tex:
			var img: Image = logo_tex.get_image()
			img.resize(24, 24, Image.INTERPOLATE_LANCZOS)
			header_icon.texture = ImageTexture.create_from_image(img)
	header_row.add_child(header_icon)
	var header := Label.new()
	header.text = "StoryFlow"
	header.add_theme_font_size_override("font_size", 18)
	header_row.add_child(header)
	var version_label := Label.new()
	version_label.text = "v" + StoryFlowWebSocketSync._get_plugin_version()
	version_label.add_theme_font_size_override("font_size", 11)
	version_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	header_row.add_child(version_label)
	root.add_child(header_row)

	root.add_child(HSeparator.new())

	# === Live Sync Section ===
	var sync_header := Label.new()
	sync_header.text = "Live Sync"
	sync_header.add_theme_font_size_override("font_size", 14)
	root.add_child(sync_header)

	var port_row := HBoxContainer.new()
	var port_label := Label.new()
	port_label.text = "Port:"
	port_label.custom_minimum_size.x = 70
	port_row.add_child(port_label)
	_sync_port_edit = SpinBox.new()
	_sync_port_edit.min_value = 1
	_sync_port_edit.max_value = 65535
	_sync_port_edit.value = 9000
	_sync_port_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	port_row.add_child(_sync_port_edit)
	root.add_child(port_row)

	var btn_row := HBoxContainer.new()
	_connect_button = Button.new()
	_connect_button.text = "Connect"
	_connect_button.pressed.connect(_on_connect_pressed)
	btn_row.add_child(_connect_button)
	_disconnect_button = Button.new()
	_disconnect_button.text = "Disconnect"
	_disconnect_button.pressed.connect(_on_disconnect_pressed)
	_disconnect_button.disabled = true
	btn_row.add_child(_disconnect_button)
	_sync_button = Button.new()
	_sync_button.text = "Sync"
	_sync_button.pressed.connect(_on_sync_pressed)
	_sync_button.disabled = true
	btn_row.add_child(_sync_button)
	root.add_child(btn_row)

	_sync_status_label = Label.new()
	_sync_status_label.text = "Status: Disconnected"
	root.add_child(_sync_status_label)

	# Status
	_status_label = Label.new()
	_status_label.text = ""
	_status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	root.add_child(_status_label)

	root.add_child(HSeparator.new())

	# === Import Section ===
	var import_header := Label.new()
	import_header.text = "Import"
	import_header.add_theme_font_size_override("font_size", 14)
	root.add_child(import_header)

	# Build directory
	var proj_row := HBoxContainer.new()
	var proj_label := Label.new()
	proj_label.text = "Build Dir:"
	proj_label.custom_minimum_size.x = 70
	proj_row.add_child(proj_label)
	_project_path_edit = LineEdit.new()
	_project_path_edit.placeholder_text = "Path to build/ directory"
	_project_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	proj_row.add_child(_project_path_edit)
	var browse_btn := Button.new()
	browse_btn.text = "Browse"
	browse_btn.pressed.connect(_on_browse_build_dir)
	proj_row.add_child(browse_btn)
	root.add_child(proj_row)

	# Output directory
	var out_row := HBoxContainer.new()
	var out_label := Label.new()
	out_label.text = "Output:"
	out_label.custom_minimum_size.x = 70
	out_row.add_child(out_label)
	_output_path_edit = LineEdit.new()
	_output_path_edit.text = DEFAULT_OUTPUT_DIR
	_output_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	out_row.add_child(_output_path_edit)
	root.add_child(out_row)

	# Import button
	_import_button = Button.new()
	_import_button.text = "Import Project"
	_import_button.pressed.connect(_on_import_pressed)
	root.add_child(_import_button)

	# Reusable file dialog (created once, shown on demand)
	_file_dialog = FileDialog.new()
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.dir_selected.connect(func(dir: String): _project_path_edit.text = dir)
	add_child(_file_dialog)

	# Timer for polling WebSocket sync
	_poll_timer = Timer.new()
	_poll_timer.wait_time = 0.1
	_poll_timer.autostart = false
	_poll_timer.timeout.connect(_on_poll_timer)
	add_child(_poll_timer)


func _on_browse_build_dir() -> void:
	_file_dialog.popup_centered(Vector2i(600, 400))


func _on_import_pressed() -> void:
	var build_dir := _project_path_edit.text.strip_edges()

	if build_dir.is_empty():
		_status_label.text = "Error: No build directory specified"
		return

	_status_label.text = "Importing..."
	_import_button.disabled = true

	_save_settings()

	var importer := StoryFlowImporter.new()
	var project := importer.import_project(build_dir, _get_output_dir())

	if project:
		_set_project_on_manager(project)
		_status_label.text = "Import complete: %s" % project.title
	else:
		_status_label.text = "Import failed. Check Output log."

	_import_button.disabled = false


func _on_connect_pressed() -> void:
	_sync_status_label.text = "Status: Connecting..."
	_connect_button.disabled = true
	_disconnect_button.disabled = false

	_save_settings()

	_ws_sync = StoryFlowWebSocketSync.new()
	_ws_sync.set_output_dir(_get_output_dir())
	_ws_sync.connected.connect(_on_ws_connected)
	_ws_sync.disconnected.connect(_on_ws_disconnected)
	_ws_sync.sync_complete.connect(_on_ws_sync_complete)
	_ws_sync.connect_to_editor(int(_sync_port_edit.value))
	_poll_timer.start()


func _on_disconnect_pressed() -> void:
	_poll_timer.stop()
	if _ws_sync:
		_ws_sync.disconnect_from_editor()
		_ws_sync = null
	_connect_button.disabled = false
	_disconnect_button.disabled = true
	_sync_button.disabled = true
	_sync_status_label.text = "Status: Disconnected"
	connection_state_changed.emit(false)


func _on_sync_pressed() -> void:
	if _ws_sync and _ws_sync.is_connected_to_editor():
		_ws_sync.set_output_dir(_get_output_dir())
		_save_settings()
		_sync_status_label.text = "Status: Syncing..."
		_ws_sync.request_sync()


func _on_ws_connected() -> void:
	_sync_status_label.text = "Status: Connected"
	_sync_button.disabled = false
	connection_state_changed.emit(true)


func _on_ws_disconnected() -> void:
	_sync_status_label.text = "Status: Disconnected"
	_sync_button.disabled = true
	connection_state_changed.emit(false)


## Returns true if currently connected to the StoryFlow editor.
func is_connected_to_editor() -> bool:
	return _ws_sync != null and _ws_sync.is_connected_to_editor()


## Trigger a connect from external UI (e.g. toolbar button).
func connect_to_editor() -> void:
	if not is_connected_to_editor():
		_on_connect_pressed()


## Trigger a sync from external UI (e.g. toolbar button).
func request_sync() -> void:
	_on_sync_pressed()


func _on_ws_sync_complete(project: StoryFlowProject) -> void:
	_set_project_on_manager(project)
	_update_import_meta(project)
	_status_label.text = "Sync: %s (%d scripts)" % [project.title, project.scripts.size()]
	_sync_status_label.text = "Status: Connected"


func _set_project_on_manager(project: StoryFlowProject) -> void:
	var tree := get_tree()
	if not tree:
		return
	var mgr := tree.root.get_node_or_null("/root/StoryFlowRuntime")
	if mgr and mgr.has_method("set_project"):
		mgr.set_project(project)
		print("[StoryFlow] Project set on manager: %s" % project.title)


func _update_import_meta(project: StoryFlowProject) -> void:
	var output_dir := _get_output_dir()

	var meta_path := output_dir.path_join("storyflow_import_meta.json")
	var meta := {}

	# Preserve existing meta fields
	if FileAccess.file_exists(meta_path):
		var existing := FileAccess.open(meta_path, FileAccess.READ)
		if existing:
			var json := JSON.new()
			if json.parse(existing.get_as_text()) == OK and json.data is Dictionary:
				meta = json.data

	meta["script_paths"] = Array(project.get_all_script_paths())
	meta["synced_at"] = Time.get_datetime_string_from_system()
	if not meta.has("output_dir"):
		meta["output_dir"] = output_dir

	DirAccess.make_dir_recursive_absolute(output_dir)

	var file := FileAccess.open(meta_path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(meta, "\t"))
		file.close()


func _on_poll_timer() -> void:
	if _ws_sync:
		_ws_sync.poll()


func _get_output_dir() -> String:
	var dir := _output_path_edit.text.strip_edges()
	return dir if not dir.is_empty() else DEFAULT_OUTPUT_DIR


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("dock", "port", int(_sync_port_edit.value))
	cfg.set_value("dock", "output_dir", _output_path_edit.text)
	cfg.set_value("dock", "build_dir", _project_path_edit.text)
	cfg.save(SETTINGS_PATH)


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	_sync_port_edit.value = cfg.get_value("dock", "port", 9000)
	_output_path_edit.text = cfg.get_value("dock", "output_dir", DEFAULT_OUTPUT_DIR)
	_project_path_edit.text = cfg.get_value("dock", "build_dir", "")
