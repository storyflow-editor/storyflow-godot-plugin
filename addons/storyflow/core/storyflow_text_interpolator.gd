class_name StoryFlowTextInterpolator
extends RefCounted

# Preloaded by path so parsing never depends on the global class name cache,
# which can be stale or mid-rewrite when the game launches (godotengine/godot#75388).
const Store = preload("res://addons/storyflow/core/storyflow_data_asset_store.gd")
const StoryFlowCharacter = preload("res://addons/storyflow/core/storyflow_character.gd")
const StoryFlowCharacterData = preload("res://addons/storyflow/core/storyflow_character_data.gd")
const StoryFlowExecutionContext = preload("res://addons/storyflow/core/storyflow_execution_context.gd")
const StoryFlowLocalization = preload("res://addons/storyflow/core/storyflow_localization.gd")
const StoryFlowProject = preload("res://addons/storyflow/core/storyflow_project.gd")
const StoryFlowScript = preload("res://addons/storyflow/core/storyflow_script.gd")
const StoryFlowTypes = preload("res://addons/storyflow/core/storyflow_types.gd")
const StoryFlowVariant = preload("res://addons/storyflow/core/storyflow_variant.gd")

## Handles variable interpolation in dialogue text and string table lookups.

var _regex: RegEx = null
var _context: StoryFlowExecutionContext = null
var _manager: Node = null
var _language_code: String = "en"


func _init() -> void:
	_regex = RegEx.new()
	_regex.compile("\\{([^}]+)\\}")


func set_context(context: StoryFlowExecutionContext) -> void:
	_context = context


func set_manager(manager: Node) -> void:
	_manager = manager


func set_language_code(code: String) -> void:
	_language_code = code


# =============================================================================
# Text Interpolation
# =============================================================================

func interpolate(text: String) -> String:
	if "{" not in text:
		return text

	var result := text
	var matches := _regex.search_all(text)
	# Process in reverse to preserve offsets
	for i in range(matches.size() - 1, -1, -1):
		var m: RegExMatch = matches[i]
		var var_name: String = m.get_string(1).strip_edges()
		var value = _resolve_reference(var_name)
		var replacement: String = m.get_string(0) if value == null else str(value)

		result = result.substr(0, m.get_start()) + replacement + result.substr(m.get_end())

	return result


# =============================================================================
# String Resolution
# =============================================================================

## THE DIALOGUE-LANE DOOR onto the one shared ladder (StoryFlowLocalization.look_up) - the same
## ladder StoryFlowEvaluator's node lane and StoryFlowComponent's outside-dialogue arm run, never a
## copy of it. The miss policy is this plugin's long-standing one: a key that resolves nowhere is
## its own text.
##
## [param language_code] is the PRE-LOCALIZATION language and is only the FALLBACK: once the loaded
## project ships a localization.json the language is the player's and game-wide, and the manager's
## state (reached through the context) owns it. Callers keep passing their own code so a project
## exported before localization existed behaves exactly as it did.
##
## THE LOOKUP RUNS ON THE AUTHORED TEMPLATE (§9). Every caller interpolates the RESULT of this
## call - `interpolate(get_string(key, code))`, never `get_string(interpolate(text), code)`. A
## translated line is authored with the same `{Variable}` tokens as the source line, so
## interpolating first would hand this lookup a string no table was ever keyed by; the line would
## still render, in the source language, and only for lines that happen to carry a token. GDScript
## cannot catch that ordering, so it is stated at every door.
func get_string(key: String, language_code: String) -> String:
	if key.is_empty():
		return ""
	var script: StoryFlowScript = _context.current_script if _context else null
	var localization = _context.localization if _context else null
	var global_strings: Dictionary = {}
	if _manager:
		var project: StoryFlowProject = _manager.get_project()
		if project:
			global_strings = project.global_strings
	var resolved = StoryFlowLocalization.look_up(localization, script, global_strings, key, language_code)
	return key if resolved == null else resolved


# =============================================================================
# Internal
# =============================================================================

# Each hop consumes authored path text. Revisited references are safe and finite.
func _resolve_reference(path: String):
	if not _context:
		return null
	if path.begins_with("Character."):
		var speaker = _context.current_dialogue_state.character if _context.current_dialogue_state else null
		if not speaker:
			return null
		if not speaker.character_path.is_empty():
			return _walk(StoryFlowTypes.VariableType.CHARACTER, speaker.character_path, path.substr(10).strip_edges())
		# Legacy callers can supply a presentation-only speaker without a live identity.
		var field := path.substr(10).strip_edges()
		if StoryFlowCharacter.is_name_token(field):
			return speaker.name
		return speaker.variables.get(field)
	var dot := path.find(".")
	if dot < 0:
		return _leaf(_lookup_variable(path))
	var root := _lookup_variable(path.substr(0, dot))
	if root.is_empty() or root.get("is_array", false):
		return null
	var value = root.get("value")
	if not value is StoryFlowVariant:
		return null
	return _walk(root.get("type", -1), value.get_string(), path.substr(dot + 1))


func _walk(kind: int, reference: String, remaining: String):
	while not reference.is_empty():
		var exact := _field(kind, reference, remaining)
		if not exact.is_empty():
			return _leaf(exact)
		var dot := remaining.find(".")
		if dot < 0:
			return null
		var next := _field(kind, reference, remaining.substr(0, dot))
		if next.is_empty() or next.get("is_array", false):
			return null
		var value = next.get("value")
		if not value is StoryFlowVariant:
			return null
		kind = next.get("type", -1)
		reference = value.get_string()
		remaining = remaining.substr(dot + 1)
	return null


func _field(kind: int, reference: String, field: String) -> Dictionary:
	if not _manager:
		return {}
	if kind == StoryFlowTypes.VariableType.DATA_ASSET:
		var seed: Dictionary = _manager.get_data_asset_seed()
		var declaration := Store.find_declaration_by_name(seed, reference, field)
		if declaration.is_empty():
			return {}
		var result := declaration.duplicate()
		var locale := StoryFlowLocalization.reading_locale(_manager.get_localization(), _manager.get_project().global_strings, _language_code)
		result["value"] = Store.try_read(seed, _manager.get_data_asset_overlay(), locale, reference, str(declaration.get("id", "")))
		result["resolved"] = true
		return result
	if kind != StoryFlowTypes.VariableType.CHARACTER:
		return {}
	var key: String = StoryFlowCharacter.resolve_character_key(_manager.get_character_id_bridge(), _manager.get_runtime_characters(), reference, _context)
	var character: StoryFlowCharacter = _manager.get_runtime_character(key)
	if not character:
		return {}
	if StoryFlowCharacter.is_name_token(field):
		return {"type": StoryFlowTypes.VariableType.STRING, "value": StoryFlowVariant.from_string(character.character_name if character.name_is_literal else get_string(character.character_name, _language_code)), "resolved": true}
	return character.variables.get(field, {})


func _leaf(declaration: Dictionary):
	if declaration.is_empty() or declaration.get("is_array", false):
		return null
	var kind: int = declaration.get("type", -1)
	if kind not in [StoryFlowTypes.VariableType.BOOLEAN, StoryFlowTypes.VariableType.INTEGER, StoryFlowTypes.VariableType.FLOAT, StoryFlowTypes.VariableType.STRING, StoryFlowTypes.VariableType.ENUM]:
		return null
	var value = declaration.get("value")
	if not value is StoryFlowVariant:
		return null
	if declaration.get("resolved", false):
		return value.to_display_string()
	return _resolve_display_value(value) if kind == StoryFlowTypes.VariableType.STRING else value.to_display_string()


func _lookup_variable(display_name: String) -> Dictionary:
	if not _context:
		return {}
	var result := _context.find_variable_by_name(display_name)
	if result.is_empty():
		return {}
	if result.get("is_global", false):
		return _manager.get_global_variables().get(result["id"], {}) if _manager else {}
	return result["variable"]


func _resolve_display_value(val: StoryFlowVariant) -> String:
	var text := val.to_display_string()
	if val.type == StoryFlowTypes.VariableType.STRING and not val.string_is_literal:
		text = get_string(text, _language_code)
	return text


# Retained for hosts that called the previous one-hop helper directly.
func _resolve_character_field(path_variant, inner_field: String, var_name: String) -> String:
	var value = _walk(StoryFlowTypes.VariableType.CHARACTER, path_variant.get_string(), inner_field) if path_variant is StoryFlowVariant else null
	return "{%s}" % var_name if value == null else str(value)
