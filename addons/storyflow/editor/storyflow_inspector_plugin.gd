@tool
extends EditorInspectorPlugin

const StoryFlowScriptProperty = preload("storyflow_script_property.gd")


func _can_handle(object: Object) -> bool:
	return object is StoryFlowComponent


func _parse_property(object: Object, type: Variant.Type, name: String, hint_type: PropertyHint, hint_string: String, usage_flags: int, wide: bool) -> bool:
	if name == "script_path" and type == TYPE_STRING:
		add_property_editor(name, StoryFlowScriptProperty.new())
		return true
	return false
