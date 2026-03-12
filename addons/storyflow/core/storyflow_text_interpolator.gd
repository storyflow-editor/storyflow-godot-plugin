class_name StoryFlowTextInterpolator
extends RefCounted

## Handles variable interpolation in dialogue text and string table lookups.

var _regex: RegEx = null
var _context: StoryFlowExecutionContext = null
var _manager: StoryFlowManager = null


func _init() -> void:
	_regex = RegEx.new()
	_regex.compile("\\{([^}]+)\\}")


func set_context(context: StoryFlowExecutionContext) -> void:
	_context = context


func set_manager(manager: StoryFlowManager) -> void:
	_manager = manager


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
				if char_field == "Name":
					replacement = char_data.name
				else:
					replacement = char_data.variables.get(char_field, "{%s}" % var_name)
		else:
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
	if not _context:
		return "{%s}" % display_name

	var result := _context.find_variable_by_name(display_name)
	if result.is_empty():
		return "{%s}" % display_name

	if result.get("is_global", false):
		if _manager:
			var var_id: String = result["id"]
			var globals: Dictionary = _manager.get_global_variables()
			if globals.has(var_id):
				var v: Dictionary = globals[var_id]
				var val = v.get("value", null)
				if val is StoryFlowVariant:
					return val.to_display_string()
		return "{%s}" % display_name
	else:
		var v: Dictionary = result["variable"]
		var val = v.get("value", null)
		if val is StoryFlowVariant:
			return val.to_display_string()
	return "{%s}" % display_name
