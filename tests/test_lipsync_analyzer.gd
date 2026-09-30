extends SceneTree
## Real AudioServer tests: independent player routes, shared readers and route restoration.
## Dummy audio keeps this silent while exercising Godot's mixer and spectrum effect.

const ANALYZER_PATH := "res://addons/storyflow/lipsync/storyflow_lipsync_analyzer.gd"
var _checks := 0
var _failures := 0


func _initialize() -> void:
	await process_frame
	_check("lipsync analyzer exists", FileAccess.file_exists(ANALYZER_PATH))
	if _failures > 0:
		quit(1)
		return
	var analyzer_script = load(ANALYZER_PATH)
	var unrelated := Node.new()
	root.add_child(unrelated)
	_check("non-audio nodes are rejected", analyzer_script.acquire(unrelated) == null)
	unrelated.free()
	var initial_bus_count := AudioServer.bus_count
	AudioServer.add_bus()
	var destination_index := AudioServer.bus_count - 1
	AudioServer.set_bus_name(destination_index, &"LipsyncTestDestination")
	var player := AudioStreamPlayer.new()
	player.bus = &"LipsyncTestDestination"
	player.playback_type = AudioServer.PLAYBACK_TYPE_DEFAULT
	player.stream = _tone(800.0)
	root.add_child(player)
	var first = analyzer_script.acquire(player)
	var second = analyzer_script.acquire(player)
	_check("faces sharing a player share one analyzer", first == second and AudioServer.bus_count == initial_bus_count + 2)
	var isolated_bus: StringName = player.bus
	_check("player is isolated from its destination bus", isolated_bus != &"LipsyncTestDestination")
	_check("analysis forwards to the original route", AudioServer.get_bus_send(AudioServer.get_bus_index(isolated_bus)) == &"LipsyncTestDestination")
	_check("stream playback enables effects on web", player.playback_type == AudioServer.PLAYBACK_TYPE_STREAM)
	player.play()
	await _wait_for_spectrum(first, true)
	_check("analyzer has a native effect instance", first.is_available())
	var magnitudes: PackedFloat32Array = first.read_magnitudes()
	_check("speech band is sampled", magnitudes.size() == 24)
	var peak := 0.0
	for value in magnitudes:
		peak = maxf(peak, value)
	_check("real mixed audio reaches analysis", peak > 0.01)
	print("Full-scale 800 Hz tone peak: %f" % peak)
	# Godot only sends to earlier buses. Moving the game's bus must not silence its voice.
	AudioServer.move_bus(AudioServer.get_bus_index(&"LipsyncTestDestination"), -1)
	first.read_magnitudes()
	_check("destination reordering preserves forward audio flow", AudioServer.get_bus_index(isolated_bus) > AudioServer.get_bus_index(&"LipsyncTestDestination"))
	await create_timer(0.15).timeout
	_check("reordered destination still receives audible output", AudioServer.get_bus_peak_volume_left_db(AudioServer.get_bus_index(&"LipsyncTestDestination"), 0) > -20.0)
	AudioServer.set_bus_solo(AudioServer.get_bus_index(&"LipsyncTestDestination"), true)
	first.read_magnitudes()
	await create_timer(0.15).timeout
	_check("soloing the original destination preserves voice output", AudioServer.get_bus_peak_volume_left_db(0, 0) > -20.0)
	AudioServer.set_bus_solo(AudioServer.get_bus_index(&"LipsyncTestDestination"), false)
	first.read_magnitudes()
	_check("helper stops soloing when the destination does", not AudioServer.is_bus_solo(AudioServer.get_bus_index(isolated_bus)))

	var other := AudioStreamPlayer.new()
	other.stream = _tone(2400.0)
	root.add_child(other)
	var independent = analyzer_script.acquire(other)
	other.play()
	player.stop()
	await _wait_for_spectrum(first, false)
	var silent: PackedFloat32Array = first.read_magnitudes()
	var silent_peak := 0.0
	for value in silent:
		silent_peak = maxf(silent_peak, value)
	_check("another player cannot drive a silent face's analyzer", silent_peak < 0.0001)
	_check("separate players have separate analysis routes", player.bus != other.bus and first != independent)
	# A game switching buses during a line must keep that new destination after release.
	other.bus = &"LipsyncTestDestination"
	independent.read_magnitudes()
	independent.release()
	_check("a runtime route change survives release", other.bus == &"LipsyncTestDestination")
	independent = analyzer_script.acquire(other)

	first.release()
	_check("one face releasing retains another face's analyzer", AudioServer.get_bus_index(isolated_bus) >= 0 and player.bus == isolated_bus)
	second.release()
	_check("last release restores original routing", player.bus == &"LipsyncTestDestination" and AudioServer.get_bus_index(isolated_bus) == -1)
	_check("last release restores playback mode", player.playback_type == AudioServer.PLAYBACK_TYPE_DEFAULT)
	# Explicit routing observes the selected bus without taking over the player's own route.
	var explicit = analyzer_script.acquire(player, &"LipsyncTestDestination")
	_check("explicit bus does not reroute the player", player.bus == &"LipsyncTestDestination")
	_check("explicit bus uses the existing bus", AudioServer.bus_count == initial_bus_count + 2)
	explicit.release()
	_check("explicit bus survives final release", AudioServer.get_bus_index(&"LipsyncTestDestination") >= 0)
	_check("explicit analysis removes only its effect", AudioServer.get_bus_effect_count(AudioServer.get_bus_index(&"LipsyncTestDestination")) == 0)
	for release_auto_first in [true, false]:
		var automatic = analyzer_script.acquire(player)
		var selected = analyzer_script.acquire(player, &"LipsyncTestDestination")
		if release_auto_first:
			automatic.release()
		else:
			selected.release()
		_check("mixed analysis routes retain Stream playback until final release (%s)" % release_auto_first, player.playback_type == AudioServer.PLAYBACK_TYPE_STREAM)
		if release_auto_first:
			selected.release()
		else:
			automatic.release()
		_check("mixed analysis routes restore the original playback mode (%s)" % release_auto_first, player.playback_type == AudioServer.PLAYBACK_TYPE_DEFAULT)
	var other_bus: StringName = other.bus
	other.free()
	_check("destroyed player releases its temporary bus", AudioServer.get_bus_index(other_bus) == -1)
	independent.release()
	player.free()
	await _test_area_route(analyzer_script)
	AudioServer.remove_bus(AudioServer.get_bus_index(&"LipsyncTestDestination"))
	_check("no temporary buses remain", AudioServer.bus_count == initial_bus_count)
	# Freeing a playing node queues its voice retirement on the mixer thread.
	await create_timer(0.1).timeout
	print("LIPSYNC ANALYZER: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _test_area_route(analyzer_script) -> void:
	var stage := Node2D.new()
	root.add_child(stage)
	var area := Area2D.new()
	area.audio_bus_override = true
	area.audio_bus_name = &"LipsyncTestDestination"
	stage.add_child(area)
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 100.0
	shape.shape = circle
	area.add_child(shape)
	var player := AudioStreamPlayer2D.new()
	player.area_mask = 1
	player.stream = _tone(800.0)
	stage.add_child(player)
	await physics_frame
	await physics_frame
	var analyzer = analyzer_script.acquire(player, &"LipsyncTestDestination")
	player.play()
	await _wait_for_spectrum(analyzer, true)
	var peak := 0.0
	for value in analyzer.read_magnitudes():
		peak = maxf(peak, value)
	_check("explicit bus hears actual Area2D audio override", peak > 0.01)
	_check("explicit Area analysis preserves the player's assigned bus", player.bus == &"Master")
	analyzer.release()
	_check("Area analysis leaves no effects behind", AudioServer.get_bus_effect_count(AudioServer.get_bus_index(&"LipsyncTestDestination")) == 0)
	stage.free()


func _wait_for_spectrum(analyzer, audible: bool) -> void:
	var deadline := Time.get_ticks_msec() + 2000
	while Time.get_ticks_msec() < deadline:
		var peak := 0.0
		for value in analyzer.read_magnitudes():
			peak = maxf(peak, value)
		if (audible and peak > 0.01) or (not audible and peak < 0.0001):
			return
		await process_frame


func _tone(frequency: float) -> AudioStreamWAV:
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = 44100
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_end = 44100
	var pcm := PackedByteArray()
	pcm.resize(44100 * 2)
	for index in 44100:
		pcm.encode_s16(index * 2, int(sin(TAU * frequency * index / 44100.0) * 32767.0))
	stream.data = pcm
	return stream


func _check(label: String, condition: bool) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr("FAIL: " + label)
