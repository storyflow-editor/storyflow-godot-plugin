class_name StoryFlowLipsyncAnalyzer
extends RefCounted
## One native spectrum effect per audio player, shared by every face following it.
## The temporary bus sends to the player's original bus, preserving the game's mixer setup.
## An explicit bus observes custom/Area routing without rerouting the player.

const BAND_COUNT := 24
const MIN_HZ := 90.0
const MAX_HZ := 4200.0

static var _shared: Dictionary = {}
static var _playback_modes: Dictionary = {}

var _player: WeakRef
var _player_id: int
var _key: String
var _owns_bus: bool = true
var _users: int = 0
var _closed: bool = false
var _bus_name: StringName
var _destination: StringName
var _effect: AudioEffectSpectrumAnalyzer
var _magnitudes := PackedFloat32Array()


static func acquire(player: Node, analysis_bus: StringName = &"") -> StoryFlowLipsyncAnalyzer:
	if not is_instance_valid(player) or not player.is_inside_tree():
		return null
	if not (player is AudioStreamPlayer or player is AudioStreamPlayer2D or player is AudioStreamPlayer3D):
		return null
	if not analysis_bus.is_empty() and AudioServer.get_bus_index(analysis_bus) < 0:
		push_warning("StoryFlow Editor lipsync analysis bus '%s' does not exist." % analysis_bus)
		return null
	var id := player.get_instance_id()
	var key := "%d:%s" % [id, analysis_bus]
	if _shared.has(key):
		var existing: StoryFlowLipsyncAnalyzer = _shared[key]
		existing._users += 1
		return existing
	var analyzer: StoryFlowLipsyncAnalyzer = load("res://addons/storyflow/lipsync/storyflow_lipsync_analyzer.gd").new()
	analyzer._player = weakref(player)
	analyzer._player_id = id
	analyzer._key = key
	analyzer._owns_bus = analysis_bus.is_empty()
	analyzer._users = 1
	analyzer._destination = player.bus
	# A player may have automatic and explicit-bus listeners simultaneously.
	# Keep Stream mode until the last analyzer, regardless of route, is released.
	if not _playback_modes.has(id):
		_playback_modes[id] = {"users": 0, "original": player.playback_type}
	_playback_modes[id].users += 1
	analyzer._bus_name = StringName("StoryFlowLipsync_%d" % id) if analyzer._owns_bus else analysis_bus
	analyzer._magnitudes.resize(BAND_COUNT)
	analyzer._effect = AudioEffectSpectrumAnalyzer.new()
	analyzer._effect.fft_size = AudioEffectSpectrumAnalyzer.FFT_SIZE_512
	analyzer._effect.buffer_length = 0.25
	if analyzer._owns_bus:
		analyzer._install_bus()
	else:
		AudioServer.add_bus_effect(AudioServer.get_bus_index(analysis_bus), analyzer._effect, 0)
	# Web Sample playback bypasses AudioEffects. A player already running in that mode
	# needs to restart at its current position once, when it first gains a listener.
	var restart: bool = OS.has_feature("web") and player.playback_type != AudioServer.PLAYBACK_TYPE_STREAM and player.playing
	var position: float = player.get_playback_position() if restart else 0.0
	player.playback_type = AudioServer.PLAYBACK_TYPE_STREAM
	if analyzer._owns_bus:
		player.bus = analyzer._bus_name
	if restart:
		player.play(position)
	player.tree_exiting.connect(analyzer._on_player_exiting)
	_shared[key] = analyzer
	return analyzer


func release() -> void:
	if _closed:
		return
	_users -= 1
	if _users <= 0:
		_dispose()


func is_available() -> bool:
	return _instance() != null


## The driver consumes linear magnitudes at evenly spaced frequencies, as in Unreal.
## Read the stronger stereo channel so a hard-panned voice still drives the face.
func read_magnitudes() -> PackedFloat32Array:
	var instance := _instance()
	if instance == null:
		return PackedFloat32Array()
	for index in BAND_COUNT:
		var hz := lerpf(MIN_HZ, MAX_HZ, float(index) / (BAND_COUNT - 1))
		var magnitude := instance.get_magnitude_for_frequency_range(hz, hz)
		_magnitudes[index] = maxf(magnitude.x, magnitude.y)
	return _magnitudes


func _install_bus() -> void:
	AudioServer.add_bus()
	var index := AudioServer.bus_count - 1
	AudioServer.set_bus_name(index, _bus_name)
	AudioServer.set_bus_send(index, _destination if AudioServer.get_bus_index(_destination) >= 0 else &"Master")
	var destination_index := AudioServer.get_bus_index(_destination)
	AudioServer.set_bus_solo(index, destination_index >= 0 and AudioServer.is_bus_solo(destination_index))
	AudioServer.add_bus_effect(index, _effect)


func _instance() -> AudioEffectSpectrumAnalyzerInstance:
	if _closed:
		return null
	var player = _player.get_ref()
	if not is_instance_valid(player) or not player.is_inside_tree():
		return null
	var index := AudioServer.get_bus_index(_bus_name)
	# A game may replace its bus layout or change the player's destination during a line.
	# Reattach the effect while preserving that new destination for the final release.
	if _owns_bus:
		if player.bus != _bus_name:
			_destination = player.bus
		if index < 0:
			_install_bus()
			index = AudioServer.get_bus_index(_bus_name)
		if AudioServer.get_bus_index(_destination) > index:
			AudioServer.move_bus(index, -1)
			index = AudioServer.get_bus_index(_bus_name)
		if player.bus != _bus_name:
			AudioServer.set_bus_send(index, _destination if AudioServer.get_bus_index(_destination) >= 0 else &"Master")
			player.bus = _bus_name
		var destination_index := AudioServer.get_bus_index(_destination)
		var solo := destination_index >= 0 and AudioServer.is_bus_solo(destination_index)
		if AudioServer.is_bus_solo(index) != solo:
			AudioServer.set_bus_solo(index, solo)
	elif index < 0:
		return null
	for effect_index in AudioServer.get_bus_effect_count(index):
		if AudioServer.get_bus_effect(index, effect_index) == _effect:
			return AudioServer.get_bus_effect_instance(index, effect_index) as AudioEffectSpectrumAnalyzerInstance
	# Restoring a bus layout may have removed the effect from a surviving named bus.
	AudioServer.add_bus_effect(index, _effect, 0)
	return AudioServer.get_bus_effect_instance(index, 0) as AudioEffectSpectrumAnalyzerInstance


func _on_player_exiting() -> void:
	_dispose()


func _dispose() -> void:
	_closed = true
	_shared.erase(_key)
	var player = _player.get_ref()
	var mode: Dictionary = _playback_modes[_player_id]
	mode.users -= 1
	if mode.users == 0:
		_playback_modes.erase(_player_id)
	if is_instance_valid(player):
		if _owns_bus and player.bus == _bus_name:
			player.bus = _destination
		if mode.users == 0 and player.playback_type == AudioServer.PLAYBACK_TYPE_STREAM:
			player.playback_type = mode.original
		if player.tree_exiting.is_connected(_on_player_exiting):
			player.tree_exiting.disconnect(_on_player_exiting)
	var index := AudioServer.get_bus_index(_bus_name)
	if index >= 0:
		if _owns_bus:
			AudioServer.remove_bus(index)
		else:
			for effect_index in AudioServer.get_bus_effect_count(index):
				if AudioServer.get_bus_effect(index, effect_index) == _effect:
					AudioServer.remove_bus_effect(index, effect_index)
					break
