class_name StoryFlowVariant
extends RefCounted

var type: StoryFlowTypes.VariableType = StoryFlowTypes.VariableType.NONE
var _bool_value: bool = false
var _int_value: int = 0
var _float_value: float = 0.0
var _string_value: String = ""
var _array_value: Array = []

# =============================================================================
# Getters
# =============================================================================

func get_bool(default: bool = false) -> bool:
	if type == StoryFlowTypes.VariableType.BOOLEAN:
		return _bool_value
	return default


func get_int(default: int = 0) -> int:
	if type == StoryFlowTypes.VariableType.INTEGER:
		return _int_value
	return default


func get_float(default: float = 0.0) -> float:
	if type == StoryFlowTypes.VariableType.FLOAT:
		return _float_value
	return default


func get_string(default: String = "") -> String:
	if type == StoryFlowTypes.VariableType.STRING or type == StoryFlowTypes.VariableType.ENUM:
		return _string_value
	return default


func get_array() -> Array:
	return _array_value


# =============================================================================
# Setters
# =============================================================================

func set_bool(value: bool) -> void:
	type = StoryFlowTypes.VariableType.BOOLEAN
	_bool_value = value


func set_int(value: int) -> void:
	type = StoryFlowTypes.VariableType.INTEGER
	_int_value = value


func set_float(value: float) -> void:
	type = StoryFlowTypes.VariableType.FLOAT
	_float_value = value


func set_string(value: String) -> void:
	type = StoryFlowTypes.VariableType.STRING
	_string_value = value


func set_enum(value: String) -> void:
	type = StoryFlowTypes.VariableType.ENUM
	_string_value = value


func set_array(value: Array) -> void:
	_array_value = value
	if value.size() > 0 and value[0] is StoryFlowVariant:
		type = value[0].type


# =============================================================================
# Utilities
# =============================================================================

func is_valid() -> bool:
	return type != StoryFlowTypes.VariableType.NONE


func to_display_string() -> String:
	match type:
		StoryFlowTypes.VariableType.BOOLEAN:
			return "true" if _bool_value else "false"
		StoryFlowTypes.VariableType.INTEGER:
			return str(_int_value)
		StoryFlowTypes.VariableType.FLOAT:
			return str(_float_value)
		StoryFlowTypes.VariableType.STRING, StoryFlowTypes.VariableType.ENUM:
			return _string_value
		_:
			return ""


func duplicate_variant() -> StoryFlowVariant:
	var v := StoryFlowVariant.new()
	v.type = type
	v._bool_value = _bool_value
	v._int_value = _int_value
	v._float_value = _float_value
	v._string_value = _string_value
	v._array_value = _array_value.duplicate(true)
	return v


func reset() -> void:
	type = StoryFlowTypes.VariableType.NONE
	_bool_value = false
	_int_value = 0
	_float_value = 0.0
	_string_value = ""
	_array_value.clear()


# =============================================================================
# Factory Methods
# =============================================================================

static func from_bool(value: bool) -> StoryFlowVariant:
	var v := StoryFlowVariant.new()
	v.set_bool(value)
	return v


static func from_int(value: int) -> StoryFlowVariant:
	var v := StoryFlowVariant.new()
	v.set_int(value)
	return v


static func from_float(value: float) -> StoryFlowVariant:
	var v := StoryFlowVariant.new()
	v.set_float(value)
	return v


static func from_string(value: String) -> StoryFlowVariant:
	var v := StoryFlowVariant.new()
	v.set_string(value)
	return v


static func from_enum(value: String) -> StoryFlowVariant:
	var v := StoryFlowVariant.new()
	v.set_enum(value)
	return v


static func from_array(value: Array) -> StoryFlowVariant:
	var v := StoryFlowVariant.new()
	v.set_array(value)
	return v


## Deep-copy a variables dictionary (id -> { ..., "value": StoryFlowVariant }).
static func deep_copy_variables(source: Dictionary) -> Dictionary:
	var result := {}
	for var_id in source:
		var v: Dictionary = source[var_id]
		var dup: Dictionary = v.duplicate()
		if dup.has("value") and dup["value"] is StoryFlowVariant:
			dup["value"] = dup["value"].duplicate_variant()
		result[var_id] = dup
	return result
