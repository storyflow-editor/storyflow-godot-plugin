class_name StoryFlowAudioController
extends RefCounted

## Manages dialogue audio playback (play, stop, loop).

signal playback_finished()

var _player: AudioStreamPlayer = null
var _looping: bool = false
var _owner: Node = null
var _bus: StringName = &"Master"
var _volume_db: float = 0.0


func initialize(owner: Node, bus: StringName, volume_db: float) -> void:
	_owner = owner
	_bus = bus
	_volume_db = volume_db


func play(audio_stream: AudioStream, loop: bool) -> void:
	if not audio_stream or not _owner:
		return

	stop()

	if not _player:
		_player = AudioStreamPlayer.new()
		_player.bus = _bus
		_owner.add_child(_player)

	_player.stream = audio_stream
	_player.volume_db = _volume_db
	_player.bus = _bus
	_looping = loop

	if not _player.finished.is_connected(_on_audio_finished):
		_player.finished.connect(_on_audio_finished)

	_player.play()


func stop() -> void:
	if _player and _player.playing:
		_player.stop()
	_looping = false


func is_playing() -> bool:
	return _player != null and _player.playing


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


func _on_audio_finished() -> void:
	if _looping and _player:
		_player.play()
	else:
		playback_finished.emit()
