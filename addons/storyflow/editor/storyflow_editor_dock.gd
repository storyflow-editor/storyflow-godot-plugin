@tool
class_name StoryFlowEditorDock
extends Control

var _project_path_edit: LineEdit
var _output_path_edit: LineEdit
var _import_button: Button
var _status_label: Label
var _sync_host_edit: LineEdit
var _sync_port_edit: SpinBox
var _connect_button: Button
var _disconnect_button: Button
var _sync_status_label: Label
var _file_dialog: FileDialog
var _ws_sync: StoryFlowWebSocketSync = null
var _poll_timer: Timer = null


func _ready() -> void:
	_build_ui()


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	# === Header ===
	var header := Label.new()
	header.text = "StoryFlow"
	header.add_theme_font_size_override("font_size", 18)
	root.add_child(header)

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
	_output_path_edit.text = "res://storyflow"
	_output_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	out_row.add_child(_output_path_edit)
	root.add_child(out_row)

	# Import button
	_import_button = Button.new()
	_import_button.text = "Import Project"
	_import_button.pressed.connect(_on_import_pressed)
	root.add_child(_import_button)

	# Status
	_status_label = Label.new()
	_status_label.text = ""
	_status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	root.add_child(_status_label)

	root.add_child(HSeparator.new())

	# === Live Sync Section ===
	var sync_header := Label.new()
	sync_header.text = "Live Sync"
	sync_header.add_theme_font_size_override("font_size", 14)
	root.add_child(sync_header)

	var host_row := HBoxContainer.new()
	var host_label := Label.new()
	host_label.text = "Host:"
	host_label.custom_minimum_size.x = 70
	host_row.add_child(host_label)
	_sync_host_edit = LineEdit.new()
	_sync_host_edit.text = "localhost"
	_sync_host_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host_row.add_child(_sync_host_edit)
	root.add_child(host_row)

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
	root.add_child(btn_row)

	_sync_status_label = Label.new()
	_sync_status_label.text = "Status: Disconnected"
	root.add_child(_sync_status_label)

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
	var output_dir := _output_path_edit.text.strip_edges()

	if build_dir.is_empty():
		_status_label.text = "Error: No build directory specified"
		return

	_status_label.text = "Importing..."
	_import_button.disabled = true

	var importer := StoryFlowImporter.new()
	var project := importer.import_project(build_dir, output_dir)

	if project:
		_status_label.text = "Import complete: %s" % project.title
		# Notify editor to rescan
		if Engine.is_editor_hint():
			EditorInterface.get_resource_filesystem().scan()
	else:
		_status_label.text = "Import failed. Check Output log."

	_import_button.disabled = false


func _on_connect_pressed() -> void:
	_sync_status_label.text = "Status: Connecting..."
	_connect_button.disabled = true
	_disconnect_button.disabled = false

	_ws_sync = StoryFlowWebSocketSync.new()
	_ws_sync.set_output_dir(_output_path_edit.text.strip_edges())
	_ws_sync.connected.connect(func(): _sync_status_label.text = "Status: Connected")
	_ws_sync.disconnected.connect(func(): _sync_status_label.text = "Status: Disconnected")
	_ws_sync.sync_complete.connect(func(p):
		_status_label.text = "Sync: %s" % p.title
		if Engine.is_editor_hint():
			EditorInterface.get_resource_filesystem().scan()
	)
	_ws_sync.connect_to_editor(_sync_host_edit.text.strip_edges(), int(_sync_port_edit.value))
	_poll_timer.start()


func _on_disconnect_pressed() -> void:
	_poll_timer.stop()
	if _ws_sync:
		_ws_sync.disconnect_from_editor()
		_ws_sync = null
	_connect_button.disabled = false
	_disconnect_button.disabled = true
	_sync_status_label.text = "Status: Disconnected"


func _on_poll_timer() -> void:
	if _ws_sync:
		_ws_sync.poll()
