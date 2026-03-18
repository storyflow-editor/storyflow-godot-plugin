class_name StoryFlowProject
extends RefCounted

var version: String = ""
var api_version: String = ""
var title: String = ""
var description: String = ""
var startup_script: String = ""

## script_path → StoryFlowScript
var scripts: Dictionary = {}

## id → { "id", "name", "type", "value", "is_array", "enum_values", "is_input", "is_output" }
var global_variables: Dictionary = {}

## normalized_path → StoryFlowCharacter
var characters: Dictionary = {}

## "lang.key" → "value"
var global_strings: Dictionary = {}

## asset_key → Resource (Texture2D, AudioStream, etc.)
var resolved_assets: Dictionary = {}


func get_storyflow_script(path: String) -> StoryFlowScript:
	return scripts.get(path, null)


func get_all_script_paths() -> PackedStringArray:
	return PackedStringArray(scripts.keys())


func get_localized_string(key: String, language: String = "en") -> String:
	var full_key := language + "." + key
	return global_strings.get(full_key, key)


func find_character(character_path: String) -> StoryFlowCharacter:
	var normalized := StoryFlowCharacter.normalize_path(character_path)
	return characters.get(normalized, null)
