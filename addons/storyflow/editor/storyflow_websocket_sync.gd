class_name StoryFlowWebSocketSync
extends RefCounted

signal connected()
signal disconnected()
signal sync_complete(project: StoryFlowProject)

var _socket: WebSocketPeer = null
var _host: String = "localhost"
var _port: int = 9000
var _is_connected: bool = false
var _reconnect_attempts: int = 0
var _output_dir: String = "res://storyflow"

const MAX_RECONNECT_ATTEMPTS := 5


func connect_to_editor(host: String = "localhost", port: int = 9000) -> void:
	_host = host
	_port = port
	_reconnect_attempts = 0

	_socket = WebSocketPeer.new()
	var url := "ws://%s:%d" % [_host, _port]
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
	if _is_connected and _socket:
		_socket.send_text('{"type": "requestSync"}')


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
				connected.emit()
				request_sync()

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
				var url := "ws://%s:%d" % [_host, _port]
				_socket.connect_to_url(url)


func _handle_message(text: String) -> void:
	var parsed = JSON.parse_string(text)
	if parsed == null or not parsed is Dictionary:
		return

	var msg_type: String = parsed.get("type", "")
	match msg_type:
		"project-updated", "sync-response":
			_handle_sync(parsed)


func _handle_sync(data: Dictionary) -> void:
	var project_data: Dictionary = data.get("data", {})
	if project_data.is_empty():
		return

	var importer := StoryFlowImporter.new()
	var project := importer.import_project_from_json(project_data)
	if project:
		sync_complete.emit(project)
