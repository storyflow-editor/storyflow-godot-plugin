extends SceneTree
## Headless tests for character-type variable interpolation in dialogue text.
##
## Pins the {charVarName.innerField} pattern — reaching THROUGH a character-type
## variable to a field on the character it points to (e.g. {player1.Name}) — plus
## case-insensitive {Character.Name}. Mirrors the Unity/Unreal runtimes and the
## editor's HTML runtime (interpolateVariables). See the memory note
## project_charvar_interpolation_plugin_gap.
##
## Run from the repository root (import first to build the class cache):
##   godot --headless --import
##   godot --headless --script res://tests/test_character_interpolation.gd
## Or: powershell -File tests/run_tests.ps1 -GodotExe <path-to-godot>

const InterpolatorScript := preload("res://addons/storyflow/core/storyflow_text_interpolator.gd")
const ContextScript := preload("res://addons/storyflow/core/storyflow_execution_context.gd")
const ManagerScript := preload("res://addons/storyflow/core/storyflow_manager.gd")
const ProjectScript := preload("res://addons/storyflow/core/storyflow_project.gd")
const CharacterScript := preload("res://addons/storyflow/core/storyflow_character.gd")
const CharacterDataScript := preload("res://addons/storyflow/core/storyflow_character_data.gd")
const DialogueStateScript := preload("res://addons/storyflow/core/storyflow_dialogue_state.gd")
const VariantScript := preload("res://addons/storyflow/core/storyflow_variant.gd")
const Types := preload("res://addons/storyflow/core/storyflow_types.gd")

var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	await process_frame
	_run_tests()
	if _failures == 0:
		print("ALL %d CHECKS PASSED" % _checks)
	else:
		print("%d OF %d CHECKS FAILED" % [_failures, _checks])
	quit(1 if _failures > 0 else 0)


func _run_tests() -> void:
	var char_path := "scripts/Alice.sfc"

	# A character whose display name and string variable are strings-table KEYS,
	# exactly as the JSON export writes them (resolved through the string table).
	var character := CharacterScript.new()
	character.character_path = CharacterScript.normalize_path(char_path)
	character.character_name = "char_name_key"
	character.variables = {
		"mood": {"name": "mood", "type": Types.VariableType.STRING, "value": VariantScript.from_string("mood_key")},
		"level": {"name": "level", "type": Types.VariableType.INTEGER, "value": VariantScript.from_int(7)},
	}

	var project := ProjectScript.new()
	project.characters[CharacterScript.normalize_path(char_path)] = character
	project.global_strings = {
		"en.char_name_key": "Alice",
		"en.mood_key": "cheerful",
		"en.greeting_key": "Hello",
	}
	# A GLOBAL character-type variable "npc", pointing at the same character, to
	# exercise the global lookup branch as well as the local one.
	project.global_variables = {
		"g1": {"id": "g1", "name": "npc", "type": Types.VariableType.CHARACTER, "value": VariantScript.from_string(char_path)},
	}

	var mgr := ManagerScript.new()
	mgr.name = "StoryFlowRuntime"
	root.add_child(mgr)
	mgr.set_project(project)  # populates runtime characters and global variables

	# Context with a LOCAL character-type variable "player1" (Andrew's scenario)
	# plus a plain string variable as a baseline.
	var context := ContextScript.new()
	context.local_variables = {
		"v1": {"id": "v1", "name": "player1", "type": Types.VariableType.CHARACTER, "value": VariantScript.from_string(char_path)},
		"v2": {"id": "v2", "name": "greeting", "type": Types.VariableType.STRING, "value": VariantScript.from_string("greeting_key")},
	}
	context.local_variable_name_index = {"player1": "v1", "greeting": "v2"}
	context.global_variable_name_index = {"npc": "g1"}

	var interp := InterpolatorScript.new()
	interp.set_context(context)
	interp.set_manager(mgr)
	interp.set_language_code("en")

	_check("{player1.Name} resolves the character name (the reported bug)",
		interp.interpolate("{player1.Name}"), "Alice")
	_check("{player1.name} is case-insensitive",
		interp.interpolate("{player1.name}"), "Alice")
	_check("{player1.mood} string var resolves through the string table",
		interp.interpolate("{player1.mood}"), "cheerful")
	_check("{player1.level} numeric inner var resolves",
		interp.interpolate("{player1.level}"), "7")
	_check("{player1.bogus} unknown field falls through to the literal",
		interp.interpolate("{player1.bogus}"), "{player1.bogus}")
	_check("mixed char field and surrounding text",
		interp.interpolate("Hi {player1.Name}!"), "Hi Alice!")
	_check("{npc.Name} works for a GLOBAL character-type variable",
		interp.interpolate("{npc.Name}"), "Alice")
	_check("plain {greeting} variable still interpolates (baseline)",
		interp.interpolate("{greeting}"), "Hello")

	# Assigned dialogue character: {Character.name} must be case-insensitive too.
	var char_data := CharacterDataScript.new()
	char_data.name = "Bob"
	context.current_dialogue_state = DialogueStateScript.new()
	context.current_dialogue_state.character = char_data
	_check("{Character.Name} baseline", interp.interpolate("{Character.Name}"), "Bob")
	_check("{Character.name} is case-insensitive", interp.interpolate("{Character.name}"), "Bob")

	root.remove_child(mgr)
	mgr.free()


func _check(label: String, got: String, expected: String) -> void:
	_checks += 1
	if got == expected:
		print("  PASS: %s" % label)
	else:
		_failures += 1
		printerr("  FAIL: %s: expected [%s] got [%s]" % [label, expected, got])
