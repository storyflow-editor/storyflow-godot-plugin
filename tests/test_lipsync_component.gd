extends SceneTree

const LipsyncScript := preload("res://addons/storyflow/lipsync/storyflow_lipsync.gd")
const ComponentScript := preload("res://addons/storyflow/core/storyflow_component.gd")
const StateScript := preload("res://addons/storyflow/core/storyflow_dialogue_state.gd")
const FixtureSourceScript := preload("res://tests/lipsync_source.gd")

var _checks := 0
var _failures := 0


func _initialize() -> void:
	await process_frame
	await _test_text_line_and_teardown()
	await _test_manual_survives_other_dialogue()
	await _test_speaker_and_audio_identity()
	await _test_late_audio_start_after_stale_player()
	await _test_mesh_swap_and_late_part()
	await _test_source_replacement_and_detach()
	await _test_manual_spectrum_pause_and_release()
	await _test_redraw_and_fresh_entry_peak()
	await _test_finished_audio_releases_analysis()
	await _test_actor_reentry()
	await _test_restored_entry()
	await _test_explicit_analysis_bus()
	await _test_voiced_analysis_failure_stays_silent()
	await create_timer(0.1).timeout
	print("LIPSYNC COMPONENT: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures else 0)


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(label)


func _make_face() -> Dictionary:
	var actor := Node3D.new()
	actor.name = "Actor"
	root.add_child(actor)
	var face := MeshInstance3D.new()
	face.name = "Face"
	face.mesh = _make_mesh(["MESHBlends.jawOpen"])
	actor.add_child(face)
	var lipsync := LipsyncScript.new()
	actor.add_child(lipsync)
	# Idle pose selection must not depend on resource/object allocation order.
	lipsync._driver._random.seed = 1
	return {"actor": actor, "face": face, "lipsync": lipsync}


func _make_mesh(names: Array[String]) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var shapes := []
	for name in names:
		mesh.add_blend_shape(name)
		var shape := []
		shape.resize(Mesh.ARRAY_MAX)
		shape[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP * 1.2])
		shapes.append(shape)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, shapes)
	return mesh


func _test_text_line_and_teardown() -> void:
	var source := ComponentScript.new()
	root.add_child(source)
	var parts := _make_face()
	var lipsync: Node = parts.lipsync
	lipsync.source = source
	lipsync.smoothing = 40.0
	await process_frame
	var line := StateScript.new()
	line.is_valid = true
	line.node_id = "A"
	source.dialogue_updated.emit(line)
	_check(lipsync.is_lipsync_active(), "text-only dialogue activates this face")
	var jaw_moved := false
	for i in 90:
		await process_frame
		jaw_moved = jaw_moved or parts.face.get_blend_shape_value(0) > 0.0
		if jaw_moved:
			break
	_check(jaw_moved, "text-only dialogue animates the real mesh")
	source.dialogue_ended.emit()
	for i in 90:
		await process_frame
		if is_zero_approx(parts.face.get_blend_shape_value(0)):
			break
	_check(not lipsync.is_lipsync_active(), "dialogue end clears line ownership")
	_check(is_zero_approx(parts.face.get_blend_shape_value(0)), "dialogue end closes the owned morph")
	lipsync.enabled = false
	parts.face.set_blend_shape_value(0, 0.3)
	await process_frame
	_check(is_equal_approx(parts.face.get_blend_shape_value(0), 0.3), "disabled component releases settled morph")
	parts.actor.free()
	source.free()


func _test_manual_survives_other_dialogue() -> void:
	var source := ComponentScript.new()
	root.add_child(source)
	var parts := _make_face()
	var lipsync: Node = parts.lipsync
	lipsync.source = source
	await process_frame
	var player := AudioStreamPlayer.new()
	parts.actor.add_child(player)
	lipsync.start_lipsync_for(player)
	_check(lipsync.is_lipsync_active(), "manual source activates lipsync")
	var line := StateScript.new()
	line.is_valid = true
	line.node_id = "other"
	lipsync.character_id = "nobody"
	source.dialogue_updated.emit(line)
	_check(lipsync.is_lipsync_active(), "other speaker does not cancel manual source")
	source.dialogue_ended.emit()
	_check(lipsync.is_lipsync_active(), "dialogue end does not cancel manual source")
	lipsync.stop_lipsync()
	_check(not lipsync.is_lipsync_active(), "manual stop clears activity")
	parts.actor.free()
	source.free()


func _test_speaker_and_audio_identity() -> void:
	var source := FixtureSourceScript.new()
	root.add_child(source)
	var parts := _make_face()
	var lipsync: Node = parts.lipsync
	lipsync.source = source
	lipsync.character_id = "hero"
	await process_frame
	var line := StateScript.new()
	line.is_valid = true
	line.node_id = "speech"
	var stream := AudioStreamGenerator.new()
	line.audio = stream
	var player := AudioStreamPlayer.new()
	player.stream = stream
	source.add_child(player)
	source.fixture_player = player
	source.fixture_dialogue = line
	source.fixture_character_path = "characters/hero.json"
	source.fixture_speaker = "characters/villain.json"
	source.fixture_entry_serial = 1
	source.fixture_playback_serial = 5
	player.play()
	source.dialogue_updated.emit(line)
	_check(not lipsync.is_lipsync_active(), "other speaker leaves face inactive")
	source.fixture_speaker = "CHARACTERS\\HERO.JSON"
	source.fixture_entry_serial = 2
	source.dialogue_updated.emit(line)
	_check(lipsync.is_lipsync_active(), "normalized matching speaker activates face")
	source.dialogue_ended.emit()
	_check(lipsync.is_lipsync_active(), "playing audio tail stays active after dialogue end")
	source.fixture_playback_serial = 6
	_check(not lipsync.is_lipsync_active(), "replayed same stream cannot adopt old dialogue tail")
	parts.actor.free()
	source.free()


func _test_late_audio_start_after_stale_player() -> void:
	var source := FixtureSourceScript.new()
	root.add_child(source)
	var parts := _make_face()
	var lipsync: Node = parts.lipsync
	lipsync.source = source
	await process_frame
	var line := StateScript.new()
	line.is_valid = true
	line.node_id = "repeat"
	var stream := AudioStreamGenerator.new()
	line.audio = stream
	var player := AudioStreamPlayer.new()
	player.stream = stream
	source.add_child(player)
	source.fixture_player = player
	source.fixture_entry_serial = 2
	source.fixture_playback_serial = 8
	source.dialogue_updated.emit(line)
	# A custom audio handler starts after dialogue_updated. The same player still
	# holds the previous stream before play, so it cannot be acquired yet.
	source.fixture_playback_serial = 9
	player.play()
	await process_frame
	source.dialogue_ended.emit()
	_check(lipsync.is_lipsync_active(), "late audio start retains its playing tail")
	parts.actor.free()
	source.free()


func _test_mesh_swap_and_late_part() -> void:
	var source := ComponentScript.new()
	root.add_child(source)
	var parts := _make_face()
	var lipsync: Node = parts.lipsync
	lipsync.source = source
	await process_frame
	var line := StateScript.new()
	line.is_valid = true
	line.node_id = "mesh"
	source.dialogue_updated.emit(line)
	var old_mesh: Mesh = parts.face.mesh
	var swapped := _make_mesh(["identitySmile", "MESHBlends.jawOpen"])
	parts.face.mesh = swapped
	parts.face.set_blend_shape_value(0, 0.4)
	var moved := false
	for i in 90:
		await process_frame
		moved = moved or parts.face.get_blend_shape_value(1) > 0.0
		if moved:
			break
	_check(moved, "mesh swap resolves reordered jaw index")
	_check(is_equal_approx(parts.face.get_blend_shape_value(0), 0.4), "lipsync preserves unrelated identity expression")
	var teeth := MeshInstance3D.new()
	teeth.mesh = _make_mesh(["jawOpen"])
	parts.actor.add_child(teeth)
	await create_timer(1.1).timeout
	var teeth_moved := false
	for i in 120:
		await process_frame
		teeth_moved = teeth_moved or teeth.get_blend_shape_value(0) > 0.0
		if teeth_moved:
			break
	_check(teeth_moved, "late-added teeth receive jaw fanout")
	source.dialogue_ended.emit()
	for i in 20:
		await process_frame
	_check(is_equal_approx(parts.face.get_blend_shape_value(0), 0.4), "closing mouth preserves unrelated expression")
	parts.actor.free()
	source.free()


func _test_source_replacement_and_detach() -> void:
	var first := FixtureSourceScript.new()
	root.add_child(first)
	var second := FixtureSourceScript.new()
	root.add_child(second)
	var parts := _make_face()
	var lipsync: Node = parts.lipsync
	lipsync.source = first
	await process_frame
	var line := StateScript.new()
	line.is_valid = true
	line.node_id = "live"
	first.fixture_dialogue = line
	first.fixture_entry_serial = 1
	first.dialogue_updated.emit(line)
	_check(lipsync.is_lipsync_active(), "first source owns the line")
	second.fixture_dialogue = line
	second.fixture_entry_serial = 2
	lipsync.source = second
	await process_frame
	_check(lipsync.is_lipsync_active(), "replacement source catches up current dialogue")
	second.dialogue_ended.emit()
	second.fixture_dialogue = null
	_check(not lipsync.is_lipsync_active(), "replacement source end clears activity")
	lipsync.source = null
	await process_frame
	_check(lipsync.is_lipsync_active(), "clearing source rebinds to discovered active source")
	root.remove_child(first)
	await process_frame
	_check(not lipsync.is_lipsync_active(), "source removed from tree stops mouth while node remains valid")
	first.free()
	parts.actor.free()
	second.free()


func _test_manual_spectrum_pause_and_release() -> void:
	var parts := _make_face()
	var lipsync: Node = parts.lipsync
	var player := AudioStreamPlayer.new()
	player.stream = _tone(800.0)
	parts.actor.add_child(player)
	var original_bus: StringName = player.bus
	player.play()
	lipsync.start_lipsync_for(player)
	var heard := false
	var deadline := Time.get_ticks_msec() + 2000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		heard = lipsync.get_raw_peak() > 0.01 and lipsync.get_level() > 0.0 and parts.face.get_blend_shape_value(0) > 0.0
		if heard:
			break
	_check(heard, "manual real audio spectrum drives the actual jaw morph")
	var analysis_bus: StringName = player.bus
	_check(analysis_bus != original_bus, "manual playback acquires an isolated analyzer bus")
	player.stream_paused = true
	for i in 30:
		await process_frame
	_check(parts.face.get_blend_shape_value(0) < 0.0001, "paused audio closes the mouth even while player reports playing")
	_check(player.bus == analysis_bus, "pause retains analyzer acquisition")
	player.stream_paused = false
	lipsync.stop_lipsync()
	_check(player.bus == original_bus, "manual stop restores audio route")
	lipsync.start_lipsync_for(player)
	await process_frame
	_check(player.bus != original_bus, "manual restart acquires analyzer again")
	lipsync.enabled = false
	_check(player.bus == original_bus, "disable releases analyzer and restores audio route")
	parts.actor.free()


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


func _test_redraw_and_fresh_entry_peak() -> void:
	var source := FixtureSourceScript.new()
	root.add_child(source)
	var parts := _make_face()
	var lipsync: Node = parts.lipsync
	lipsync.source = source
	await process_frame
	var line := StateScript.new()
	line.is_valid = true
	line.node_id = "repeat"
	line.audio = _tone(800.0)
	var player := AudioStreamPlayer.new()
	player.stream = line.audio
	source.add_child(player)
	source.fixture_player = player
	source.fixture_entry_serial = 1
	source.fixture_playback_serial = 1
	player.play()
	source.dialogue_updated.emit(line)
	var deadline := Time.get_ticks_msec() + 2000
	while Time.get_ticks_msec() < deadline and lipsync.get_raw_peak() <= 0.01:
		await process_frame
	_check(lipsync.get_raw_peak() > 0.01, "audio builds a measurable raw peak")
	player.stream_paused = true
	var before: float = lipsync.get_raw_peak()
	source.dialogue_updated.emit(line)
	_check(is_equal_approx(lipsync.get_raw_peak(), before), "same-entry redraw keeps raw peak history")
	source.fixture_entry_serial = 2
	source.dialogue_updated.emit(line)
	_check(is_zero_approx(lipsync.get_raw_peak()), "fresh repeat of same node resets raw peak")
	source.dialogue_ended.emit()
	_check(player.bus == &"Master", "dialogue end releases paused analyzer")
	parts.actor.free()
	source.free()


func _test_finished_audio_releases_analysis() -> void:
	var source := FixtureSourceScript.new()
	root.add_child(source)
	var parts := _make_face()
	var lipsync: Node = parts.lipsync
	lipsync.source = source
	await process_frame
	var line := StateScript.new()
	line.is_valid = true
	line.node_id = "voiced"
	line.audio = _tone(800.0)
	var player := AudioStreamPlayer.new()
	player.stream = line.audio
	source.add_child(player)
	source.fixture_player = player
	source.fixture_entry_serial = 1
	source.fixture_playback_serial = 1
	player.play()
	source.dialogue_updated.emit(line)
	await process_frame
	_check(player.bus != &"Master", "voiced line acquires analyzer")
	player.stop()
	source.fixture_playback_serial = 2
	await process_frame
	_check(player.bus == &"Master", "finished line audio releases analyzer bus")
	_check(lipsync.is_lipsync_active(), "voiced line remains owned while visible")
	for i in 30:
		await process_frame
	_check(is_zero_approx(parts.face.get_blend_shape_value(0)), "finished voiced line closes without idle motion")
	parts.actor.free()
	source.free()


func _test_actor_reentry() -> void:
	var source := ComponentScript.new()
	root.add_child(source)
	var parts := _make_face()
	var lipsync: Node = parts.lipsync
	lipsync.source = source
	await process_frame
	var line := StateScript.new()
	line.is_valid = true
	line.node_id = "before-remove"
	source.dialogue_updated.emit(line)
	_check(lipsync.is_lipsync_active(), "actor starts with a bound dialogue source")
	root.remove_child(parts.actor)
	_check(not lipsync.is_lipsync_active(), "removing actor tears down line ownership")
	_check(is_zero_approx(parts.face.get_blend_shape_value(0)), "removing actor closes owned jaw")
	root.add_child(parts.actor)
	await process_frame
	await process_frame
	lipsync._driver._random.seed = 1
	line.node_id = "after-readd"
	source.dialogue_updated.emit(line)
	_check(lipsync.is_lipsync_active(), "readded actor binds and hears new dialogue")
	var moved := false
	for i in 90:
		await process_frame
		moved = moved or parts.face.get_blend_shape_value(0) > 0.0
		if moved:
			break
	_check(moved, "readded actor resumes driving its mesh")
	parts.actor.free()
	source.free()


func _test_explicit_analysis_bus() -> void:
	AudioServer.add_bus()
	var bus: StringName = &"LipsyncComponentExplicit"
	AudioServer.set_bus_name(AudioServer.bus_count - 1, bus)
	var parts := _make_face()
	var lipsync: Node = parts.lipsync
	lipsync.analysis_bus = bus
	var player := AudioStreamPlayer.new()
	player.bus = bus
	player.stream = _tone(800.0)
	parts.actor.add_child(player)
	player.play()
	lipsync.start_lipsync_for(player)
	var heard := false
	var deadline := Time.get_ticks_msec() + 2000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		heard = lipsync.get_raw_peak() > 0.01
		if heard:
			break
	_check(heard, "explicit analysis bus feeds the component driver")
	_check(player.bus == bus, "explicit analysis leaves the player's route intact")
	lipsync.analysis_bus = &""
	await process_frame
	_check(player.bus != bus, "switching to automatic analysis isolates the player")
	lipsync.analysis_bus = bus
	await process_frame
	_check(player.bus == bus, "switching back to explicit analysis restores player route")
	lipsync.stop_lipsync()
	parts.actor.free()
	AudioServer.remove_bus(AudioServer.get_bus_index(bus))


func _test_voiced_analysis_failure_stays_silent() -> void:
	var source := FixtureSourceScript.new()
	root.add_child(source)
	var parts := _make_face()
	var lipsync: Node = parts.lipsync
	lipsync.source = source
	lipsync.analysis_bus = &"MissingLipsyncAnalysisBus"
	await process_frame
	var line := StateScript.new()
	line.is_valid = true
	line.node_id = "unavailable-analysis"
	line.audio = _tone(800.0)
	var player := AudioStreamPlayer.new()
	player.stream = line.audio
	source.add_child(player)
	source.fixture_player = player
	source.fixture_entry_serial = 1
	source.fixture_playback_serial = 1
	player.play()
	source.dialogue_updated.emit(line)
	_check(lipsync.is_lipsync_active(), "voiced line remains owned without analysis")
	var voiced_moved := false
	for i in 120:
		await process_frame
		voiced_moved = voiced_moved or parts.face.get_blend_shape_value(0) > 0.0001
	_check(not voiced_moved, "voiced line without analysis does not use idle jaw motion")
	lipsync.stop_lipsync()
	lipsync.start_lipsync_for(player)
	var manual_moved := false
	for i in 120:
		await process_frame
		manual_moved = manual_moved or parts.face.get_blend_shape_value(0) > 0.0001
	_check(not manual_moved, "manual playing audio without analysis also stays silent")
	parts.actor.free()
	source.free()


func _test_restored_entry() -> void:
	var source := FixtureSourceScript.new()
	root.add_child(source)
	var parts := _make_face()
	var lipsync: Node = parts.lipsync
	lipsync.source = source
	await process_frame
	var line := StateScript.new()
	line.is_valid = true
	line.node_id = "before-back"
	source.fixture_entry_serial = 1
	source.fixture_dialogue = line
	source.dialogue_updated.emit(line)
	_check(lipsync.is_lipsync_active(), "ordinary entry owns lipsync before Back")
	parts.face.set_blend_shape_value(0, 0.4)
	line.node_id = "restored"
	line.set("is_restored", true)
	source.fixture_entry_serial = 2
	source.dialogue_restored.emit(line)
	_check(not lipsync.is_lipsync_active() and is_zero_approx(parts.face.get_blend_shape_value(0)), "restored entry releases prior lipsync and closes mesh immediately")
	source.dialogue_updated.emit(line)
	_check(not lipsync.is_lipsync_active(), "redraw of fully revealed restored entry stays closed")
	root.remove_child(parts.actor)
	root.add_child(parts.actor)
	await process_frame
	await process_frame
	_check(source.get_signal_connection_list("dialogue_restored").size() == 1 and not lipsync.is_lipsync_active(), "rebind keeps one restored listener and respects restored presentation")
	lipsync.enabled = false
	lipsync.enabled = true
	_check(not lipsync.is_lipsync_active(), "re-enabled lipsync leaves restored entry fully revealed")
	var manual := AudioStreamPlayer.new()
	parts.actor.add_child(manual)
	lipsync.start_lipsync_for(manual)
	source.dialogue_restored.emit(line)
	source.dialogue_updated.emit(line)
	_check(lipsync.is_lipsync_active(), "restoration and redraw preserve explicit manual lipsync")
	lipsync.stop_lipsync()
	line.set("is_restored", false)
	line.node_id = "next-fresh"
	source.fixture_entry_serial = 3
	source.dialogue_updated.emit(line)
	_check(lipsync.is_lipsync_active(), "next fresh entry resumes lipsync normally")
	parts.actor.free()
	_check(source.get_signal_connection_list("dialogue_restored").is_empty(), "disposed lipsync disconnects restored listener")
	source.free()
