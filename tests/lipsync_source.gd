extends "res://addons/storyflow/core/storyflow_component.gd"

var fixture_dialogue = null
var fixture_speaker := ""
var fixture_character_path := ""
var fixture_entry_serial := 0
var fixture_player: AudioStreamPlayer
var fixture_playback_serial := 0


func is_dialogue_active() -> bool:
	return fixture_dialogue != null


func get_current_dialogue():
	return fixture_dialogue


func get_current_speaker_path() -> String:
	return fixture_speaker


func get_character_path_by_id(_character_id: String) -> String:
	return fixture_character_path


func get_dialogue_entry_serial() -> int:
	return fixture_entry_serial


func get_current_dialogue_audio_player() -> AudioStreamPlayer:
	return fixture_player


func get_dialogue_audio_playback_serial() -> int:
	return fixture_playback_serial
