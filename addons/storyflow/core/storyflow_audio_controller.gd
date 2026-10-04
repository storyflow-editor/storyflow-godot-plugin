class_name StoryFlowAudioController
extends RefCounted

# Preloaded by path so parsing never depends on the global class name cache,
# which can be stale or mid-rewrite when the game launches (godotengine/godot#75388).
const StoryFlowProject = preload("res://addons/storyflow/core/storyflow_project.gd")
const StoryFlowScript = preload("res://addons/storyflow/core/storyflow_script.gd")

## Manages dialogue audio playback (play, stop, loop).

signal playback_finished()

var _player: AudioStreamPlayer = null
var _looping: bool = false
var _owner: Node = null
var _bus: StringName = &"Master"
var _volume_db: float = 0.0
var _playback_serial: int = 0
var _playback_identity: int = 0
var _finished_callback: Callable


func initialize(owner: Node, bus: StringName, volume_db: float) -> void:
	_owner = owner
	_bus = bus
	_volume_db = volume_db


func play(audio_stream: AudioStream, loop: bool) -> void:
	if not audio_stream or not _owner:
		return

	stop()

	if not is_instance_valid(_player):
		_player = AudioStreamPlayer.new()
		_player.bus = _bus
		_owner.add_child(_player)

	_player.stream = audio_stream
	_player.volume_db = _volume_db
	# Keep an optional lipsync analysis route across line changes. Its bus forwards to _bus.
	_looping = loop

	_finished_callback = _on_audio_finished.bind(_playback_serial)
	_player.finished.connect(_finished_callback)
	_player.stream_paused = false
	_player.play()


func stop() -> void:
	_playback_serial += 1
	_playback_identity = _playback_serial
	if is_instance_valid(_player):
		if _finished_callback.is_valid() and _player.finished.is_connected(_finished_callback):
			_player.finished.disconnect(_finished_callback)
		_player.stop()
	_finished_callback = Callable()
	_looping = false


func is_playing() -> bool:
	return is_instance_valid(_player) and _player.playing


func get_player() -> AudioStreamPlayer:
	return _player if is_instance_valid(_player) else null


func get_playback_serial() -> int:
	return _playback_identity


## Recovery resumes the same presentation; completion callbacks keep their newer generation.
func restore_playback_identity(identity: int) -> void:
	_playback_identity = identity


func resolve_audio_asset(audio_path: String, script: StoryFlowScript, manager: Node) -> AudioStream:
	# Check script resolved assets
	if script and script.resolved_assets.has(audio_path):
		var res = _try_load_asset(script.resolved_assets, audio_path)
		if res is AudioStream:
			return res

	# Check project resolved assets
	if manager:
		var project: StoryFlowProject = manager.get_project()
		if project and project.resolved_assets.has(audio_path):
			var res = _try_load_asset(project.resolved_assets, audio_path)
			if res is AudioStream:
				return res

	return null


func _try_load_asset(assets: Dictionary, key: String) -> Resource:
	var val = assets[key]
	if val is Resource:
		return val
	if val is String and not val.is_empty():
		var loaded = ResourceLoader.load(val)
		if loaded is Resource:
			assets[key] = loaded
			return loaded
	return null


func _on_audio_finished(serial: int) -> void:
	if serial != _playback_serial:
		return
	if _looping and is_instance_valid(_player):
		_player.play()
	else:
		playback_finished.emit()
