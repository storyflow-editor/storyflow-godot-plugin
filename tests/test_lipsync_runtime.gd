extends SceneTree
## Pins the dialogue/audio identities consumed by the lipsync node against real execution.

const Component = preload("res://addons/storyflow/core/storyflow_component.gd")
const Manager = preload("res://addons/storyflow/core/storyflow_manager.gd")
const Project = preload("res://addons/storyflow/core/storyflow_project.gd")
const Character = preload("res://addons/storyflow/core/storyflow_character.gd")
const Graph = preload("res://tests/data_asset_test_graph.gd")
const Types = preload("res://addons/storyflow/core/storyflow_types.gd")
const VariantValue = preload("res://addons/storyflow/core/storyflow_variant.gd")

var _checks := 0
var _failures := 0


func _initialize() -> void:
	await process_frame
	var component = Component.new()
	for method in ["get_current_speaker_path", "get_dialogue_entry_serial", "get_current_dialogue_audio_player", "get_dialogue_audio_playback_serial"]:
		_check("runtime exposes %s" % method, component.has_method(method))
	if _failures > 0:
		component.free()
		quit(1)
		return
	var manager = Manager.new()
	manager.name = "StoryFlowRuntime"
	root.add_child(manager)
	var project = Project.new()
	var character = Character.new()
	character.character_path = "characters\\alice"
	character.character_name = "Alice"
	project.characters[character.character_path] = character
	project.character_id_index["da_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"] = character.character_path
	var voiced = Graph.dialogue("A")
	voiced.data.merge({"characterRefId": "da_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "character": "WRONG", "audio": "voice"})
	var script = Graph.build("lipsync", {"0": Graph.start(), "A": voiced, "B": Graph.dialogue("B")}, [Graph.exec("0", "A"), Graph.exec("A", "B")], {
		"flag": Graph.scalar_var("flag", "flag", Types.VariableType.BOOLEAN, VariantValue.from_bool(false)),
	})
	var audio := AudioStreamWAV.new()
	audio.format = AudioStreamWAV.FORMAT_16_BITS
	audio.mix_rate = 22050
	var pcm := PackedByteArray()
	pcm.resize(22050 * 2 * 10)
	audio.data = pcm
	script.resolved_assets["voice"] = audio
	project.scripts["lipsync"] = script
	manager.set_project(project)
	root.add_child(component)
	component.trace_enabled = false
	_check("component participates in scene discovery", component.is_in_group("storyflow_components"))
	var observed: Array = []
	component.dialogue_updated.connect(func(_state): observed.append([component.get_current_speaker_path(), component.get_dialogue_entry_serial(), component.get_current_dialogue_audio_player()]))
	component.start_dialogue_with_script("lipsync")
	var first_entry: int = component.get_dialogue_entry_serial()
	var first_playback: int = component.get_dialogue_audio_playback_serial()
	var player: AudioStreamPlayer = component.get_current_dialogue_audio_player()
	await _wait_for_playback(player)
	_check("resolved identity is ready before line broadcast", observed[0][0] == "characters\\alice")
	_check("audio is ready before line broadcast", observed[0][2] == player and player != null and player.stream == audio)
	component.set_bool_variable("flag", true)
	component.pause_dialogue()
	component.resume_dialogue()
	_check("redraws retain dialogue entry identity", component.get_dialogue_entry_serial() == first_entry)
	_check("redraws retain playback identity", component.get_dialogue_audio_playback_serial() == first_playback)
	component.advance_dialogue()
	_check("narrator clears prior speaker", component.get_current_speaker_path().is_empty())
	_check("fresh entry changes identity", component.get_dialogue_entry_serial() > first_entry)
	_check("text-only line retains original audio", component.get_current_dialogue_audio_player() == player and component.get_dialogue_audio_playback_serial() == first_playback)
	component.stop_audio_on_dialogue_end = false
	component.stop_dialogue()
	_check("dialogue end clears speaker", component.get_current_speaker_path().is_empty())
	_check("retained tail keeps playback identity", component.get_dialogue_audio_playback_serial() == first_playback)
	component.start_dialogue_with_script("lipsync")
	await _wait_for_playback(player)
	_check("same node in a restarted dialogue has a new identity", component.get_dialogue_entry_serial() > first_entry)
	_check("same clip on reused player has a new playback identity", component.get_current_dialogue_audio_player() == player and component.get_dialogue_audio_playback_serial() > first_playback)
	var repeat_serial: int = component.get_dialogue_audio_playback_serial()
	component.stop_audio_on_dialogue_end = true
	component.stop_dialogue()
	_check("explicit audio stop invalidates playback identity", component.get_dialogue_audio_playback_serial() > repeat_serial and not player.playing)
	root.remove_child(component)
	component.free()
	root.remove_child(manager)
	manager.free()
	# Player stop/free is retired asynchronously by Godot's mixer.
	await create_timer(0.1).timeout
	print("LIPSYNC RUNTIME: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _wait_for_playback(player: AudioStreamPlayer) -> void:
	var deadline := Time.get_ticks_msec() + 1000
	while player.get_playback_position() <= 0.0 and Time.get_ticks_msec() < deadline:
		await process_frame


func _check(label: String, condition: bool) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr("FAIL: " + label)
