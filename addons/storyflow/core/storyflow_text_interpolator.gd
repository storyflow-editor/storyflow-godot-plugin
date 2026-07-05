class_name StoryFlowTextInterpolator
extends RefCounted

# Preloaded by path so parsing never depends on the global class name cache,
# which can be stale or mid-rewrite when the game launches (godotengine/godot#75388).
const StoryFlowCharacter = preload("res://addons/storyflow/core/storyflow_character.gd")
const StoryFlowCharacterData = preload("res://addons/storyflow/core/storyflow_character_data.gd")
const StoryFlowExecutionContext = preload("res://addons/storyflow/core/storyflow_execution_context.gd")
const StoryFlowProject = preload("res://addons/storyflow/core/storyflow_project.gd")
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
		var var_name: String = m.get_string(1)
		var replacement := ""

		if var_name.begins_with("Character."):
			var char_field: String = var_name.substr("Character.".length())
			var char_data: StoryFlowCharacterData = _context.current_dialogue_state.character if _context.current_dialogue_state else null
			if char_data:
				if char_field.to_lower() == "name":
					replacement = char_data.name
				else:
					replacement = char_data.variables.get(char_field, "{%s}" % var_name)
		else:
			# {charVarName.innerField}: reach through a character-type variable to a
			# field on the character it points to (e.g. {player1.Name}). Handled only
			# when the left side is a character-type variable; otherwise fall through
			# to the plain-variable lookup below.
			var dot := var_name.find(".")
			var handled := false
			if dot > 0:
				var info := _lookup_variable(var_name.substr(0, dot))
				if info.get("type", StoryFlowTypes.VariableType.NONE) == StoryFlowTypes.VariableType.CHARACTER:
					replacement = _resolve_character_field(info.get("value", null), var_name.substr(dot + 1), var_name)
					handled = true
			if not handled:
				replacement = _get_variable_display_value(var_name)

		result = result.substr(0, m.get_start()) + replacement + result.substr(m.get_end())

	return result


# =============================================================================
# String Resolution
# =============================================================================

func get_string(key: String, language_code: String) -> String:
	if key.is_empty():
		return ""
	# Try script-local strings first
	if _context and _context.current_script:
		var result := _context.current_script.get_localized_string(key, language_code)
		if result != key:
			return result
	# Try global strings
	if _manager:
		var project: StoryFlowProject = _manager.get_project()
		if project:
			var result := project.get_localized_string(key, language_code)
			if result != key:
				return result
	return key


# =============================================================================
# Internal
# =============================================================================

func _get_variable_display_value(display_name: String) -> String:
	var val = _lookup_variable(display_name).get("value", null)
	if val is StoryFlowVariant:
		return _resolve_display_value(val)
	return "{%s}" % display_name


## Looks up a variable by display name across local then global scope, returning
## { "type": VariableType, "value": StoryFlowVariant } or {} when not found.
func _lookup_variable(display_name: String) -> Dictionary:
	if not _context:
		return {}
	var result := _context.find_variable_by_name(display_name)
	if result.is_empty():
		return {}
	if result.get("is_global", false):
		if _manager:
			var globals: Dictionary = _manager.get_global_variables()
			var var_id: String = result["id"]
			if globals.has(var_id):
				var gv: Dictionary = globals[var_id]
				return {"type": gv.get("type", StoryFlowTypes.VariableType.NONE), "value": gv.get("value", null)}
		return {}
	var v: Dictionary = result["variable"]
	return {"type": v.get("type", StoryFlowTypes.VariableType.NONE), "value": v.get("value", null)}


## Resolves {charVar.innerField}: looks the character up by path and returns its
## Name (case-insensitive) or the inner variable's display value. Returns the
## literal placeholder when the character or field cannot be resolved. String-type
## inner values resolve through the string table (via _resolve_display_value).
func _resolve_character_field(path_variant, inner_field: String, var_name: String) -> String:
	var literal := "{%s}" % var_name
	if not (path_variant is StoryFlowVariant) or not _manager:
		return literal
	var path: String = path_variant.get_string()
	if path.is_empty():
		return literal
	var character: StoryFlowCharacter = _manager.get_runtime_character(path)
	if not character:
		return literal
	if inner_field.to_lower() == "name":
		return get_string(character.character_name, _language_code)
	if character.variables.has(inner_field):
		var v: Dictionary = character.variables[inner_field]
		var val = v.get("value", null)
		if val is StoryFlowVariant:
			return _resolve_display_value(val)
	return literal


func _resolve_display_value(val: StoryFlowVariant) -> String:
	var text := val.to_display_string()
	# String-type values from the JSON export are localization keys — resolve them
	if val.type == StoryFlowTypes.VariableType.STRING:
		text = get_string(text, _language_code)
	return text
