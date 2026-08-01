class_name StoryFlowVariant
extends RefCounted

# Preloaded by path so parsing never depends on the global class name cache,
# which can be stale or mid-rewrite when the game launches (godotengine/godot#75388).
const StoryFlowTypes = preload("res://addons/storyflow/core/storyflow_types.gd")

var type: StoryFlowTypes.VariableType = StoryFlowTypes.VariableType.NONE
var _bool_value: bool = false
var _int_value: int = 0
var _float_value: float = 0.0
var _string_value: String = ""
var _array_value: Array = []
# Map entries: key -> StoryFlowVariant value. Godot Dictionaries preserve
# insertion order, which is contractual — entry order is observable through
# mapKeys/mapValues/forEachMap and must match the editor's serialized order.
# Keys are int (integer keyType, coerced at the importer parse site) or String
# (string/enum keyType). Assignment shares the Dictionary reference, which is
# how setMap aliasing works (mirrors the HTML runtime assigning _runtimeMap).
var _map_value: Dictionary = {}

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


func get_map() -> Dictionary:
	return _map_value


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
	# A variant holds either array or map data, never both. Reassign instead of
	# clear() so a Dictionary shared with another variant is not emptied.
	_map_value = {}
	if value.size() > 0 and value[0] is StoryFlowVariant:
		type = value[0].type


func set_map(value: Dictionary) -> void:
	type = StoryFlowTypes.VariableType.MAP
	_map_value = value
	# A variant holds either array or map data, never both. Reassign instead of
	# clear() so an Array shared with another variant is not emptied.
	_array_value = []


# =============================================================================
# Utilities
# =============================================================================

func is_valid() -> bool:
	return type != StoryFlowTypes.VariableType.NONE


func is_map() -> bool:
	return type == StoryFlowTypes.VariableType.MAP


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
		StoryFlowTypes.VariableType.MAP:
			# Map display formatting is deliberately deferred — interpolation of
			# maps is suppressed contract-wide, so maps render as empty string
			return ""
		_:
			return ""


func duplicate_variant() -> StoryFlowVariant:
	var v := new()
	v.type = type
	v._bool_value = _bool_value
	v._int_value = _int_value
	v._float_value = _float_value
	v._string_value = _string_value
	v._array_value = _array_value.duplicate(true)
	# duplicate(true) deep-copies nested containers but NOT Object values, so the
	# StoryFlowVariant entries must be duplicated explicitly to detach the copy.
	for key in _map_value:
		var entry_value = _map_value[key]
		if entry_value is StoryFlowVariant:
			v._map_value[key] = entry_value.duplicate_variant()
		else:
			v._map_value[key] = entry_value
	return v


func reset() -> void:
	type = StoryFlowTypes.VariableType.NONE
	_bool_value = false
	_int_value = 0
	_float_value = 0.0
	_string_value = ""
	_array_value.clear()
	_map_value.clear()


# =============================================================================
# Factory Methods
# =============================================================================

static func from_bool(value: bool) -> StoryFlowVariant:
	var v := new()
	v.set_bool(value)
	return v


static func from_int(value: int) -> StoryFlowVariant:
	var v := new()
	v.set_int(value)
	return v


static func from_float(value: float) -> StoryFlowVariant:
	var v := new()
	v.set_float(value)
	return v


static func from_string(value: String) -> StoryFlowVariant:
	var v := new()
	v.set_string(value)
	return v


static func from_enum(value: String) -> StoryFlowVariant:
	var v := new()
	v.set_enum(value)
	return v


static func from_array(value: Array) -> StoryFlowVariant:
	var v := new()
	v.set_array(value)
	return v


static func from_map(value: Dictionary) -> StoryFlowVariant:
	var v := new()
	v.set_map(value)
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
