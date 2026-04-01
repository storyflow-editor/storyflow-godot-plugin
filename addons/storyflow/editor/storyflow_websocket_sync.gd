class_name StoryFlowWebSocketSync
extends RefCounted

signal connected()
signal disconnected()
signal sync_complete(project: StoryFlowProject)

var _socket: WebSocketPeer = null
var _port: int = 9000
var _is_connected: bool = false
var _reconnect_attempts: int = 0
var _output_dir: String = StoryFlowEditorDock.DEFAULT_OUTPUT_DIR

const MAX_RECONNECT_ATTEMPTS := 5


func connect_to_editor(port: int = 9000) -> void:
	_port = port
	_reconnect_attempts = 0

	_socket = WebSocketPeer.new()
	var url := "ws://localhost:%d" % _port
	var err := _socket.connect_to_url(url)
	if err != OK:
		push_error("[StoryFlow] WebSocket connection failed: %s" % error_string(err))
		return


func disconnect_from_editor() -> void:
	if _socket:
		_socket.close()
		_socket = null
	_is_connected = false
	disconnected.emit()


func is_connected_to_editor() -> bool:
	return _is_connected


func request_sync() -> void:
	_send_message("request-sync")


func set_output_dir(dir: String) -> void:
	_output_dir = dir


func poll() -> void:
	if _socket == null:
		return

	_socket.poll()

	var state := _socket.get_ready_state()
	match state:
		WebSocketPeer.STATE_OPEN:
			if not _is_connected:
				_is_connected = true
				_reconnect_attempts = 0
				_send_handshake()
				connected.emit()

			while _socket.get_available_packet_count() > 0:
				var packet := _socket.get_packet()
				var text := packet.get_string_from_utf8()
				_handle_message(text)

		WebSocketPeer.STATE_CLOSING:
			pass

		WebSocketPeer.STATE_CLOSED:
			if _is_connected:
				_is_connected = false
				disconnected.emit()

			# Auto-reconnect
			if _reconnect_attempts < MAX_RECONNECT_ATTEMPTS:
				_reconnect_attempts += 1
				var url := "ws://localhost:%d" % _port
				_socket.connect_to_url(url)


func _send_message(type: String, payload: Dictionary = {}) -> void:
	if not _is_connected or _socket == null:
		return
	var msg := { "type": type, "payload": payload }
	_socket.send_text(JSON.stringify(msg))


func _send_handshake() -> void:
	_send_message("connect", {
		"engine": "godot",
		"version": Engine.get_version_info().get("string", ""),
		"pluginVersion": _get_plugin_version(),
	})


static func _get_plugin_version() -> String:
	var cfg := ConfigFile.new()
	if cfg.load("res://addons/storyflow/plugin.cfg") == OK:
		return cfg.get_value("plugin", "version", "unknown")
	return "unknown"


func _handle_message(text: String) -> void:
	var parsed = JSON.parse_string(text)
	if parsed == null or not parsed is Dictionary:
		return

	var msg_type: String = parsed.get("type", "")
	match msg_type:
		"project-updated":
			_handle_project_updated(parsed)
		"pong":
			pass


func _handle_project_updated(data: Dictionary) -> void:
	# The editor sends { type: "project-updated", payload: { projectPath: "..." } }
	# The projectPath is the absolute path to the StoryFlow project directory.
	# The build files are in projectPath/build/
	var payload: Dictionary = data.get("payload", {})
	var project_path: String = payload.get("projectPath", "")

	if project_path.is_empty():
		push_warning("[StoryFlow] project-updated message missing projectPath")
		return

	# Build directory is projectPath/build
	var build_dir: String = project_path.replace("\\", "/") + "/build"

	print("[StoryFlow] Syncing from build directory: %s" % build_dir)

	var importer := StoryFlowImporter.new()
	var project := importer.import_project(build_dir, _output_dir)
	if project:
		sync_complete.emit(project)
	else:
		push_error("[StoryFlow] Failed to import project from sync")
