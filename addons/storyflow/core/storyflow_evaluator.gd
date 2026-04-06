class_name StoryFlowEvaluator
extends RefCounted

## Evaluator for StoryFlow node graph expressions.
##
## Evaluators retrieve data from nodes WITHOUT executing them.
## They recursively resolve input connections to compute values.

# =============================================================================
# Dependencies
# =============================================================================

var _context: StoryFlowExecutionContext = null
var _global_variables: Dictionary = {} # id -> variable Dictionary
var _characters: Dictionary = {} # normalized_path -> StoryFlowCharacter
var _global_strings: Dictionary = {} # flattened "lang.key" -> value
var _language_code: String = "en"

## Callable for trace logging, set by the component. Signature: func(msg: String) -> void
var _trace_fn: Callable = Callable()


# =============================================================================
# Initialization
# =============================================================================

func initialize(context: StoryFlowExecutionContext, global_variables: Dictionary, characters: Dictionary = {}, language_code: String = "en", global_strings: Dictionary = {}) -> void:
	_context = context
	_global_variables = global_variables
	_characters = characters
	_global_strings = global_strings
	_language_code = language_code


## Set the trace logging callable. Called by StoryFlowComponent to wire up trace output.
func set_trace(trace_callable: Callable) -> void:
	_trace_fn = trace_callable


func _sf_trace(msg: String) -> void:
	if _trace_fn.is_valid():
		_trace_fn.call(msg)


# =============================================================================
# Boolean Evaluation
# =============================================================================

func evaluate_boolean_input(node_id: String, handle_suffix: String, fallback: bool = false) -> bool:
	if not _context or not _context.current_script:
		return fallback

	var edge := _context.current_script.find_input_edge(node_id, handle_suffix)
	if edge.is_empty():
		return fallback

	var source_node := _context.current_script.get_node(edge.get("source", ""))
	if source_node.is_empty():
		return fallback

	return evaluate_boolean_from_node(edge.get("source", ""), edge.get("source_handle", ""))


func evaluate_boolean_from_node(node_id: String, source_handle: String = "") -> bool:
	if not _context or not _context.current_script:
		return false

	# Depth guard
	if _context.evaluation_depth >= StoryFlowExecutionContext.MAX_EVALUATION_DEPTH:
		push_error("StoryFlow: Max evaluation depth exceeded")
		return false
	_context.evaluation_depth += 1

	var result := false

	# Check cache first
	var node_state := _context.get_node_state(node_id)
	if node_state.cached_output != null:
		var cached: StoryFlowVariant = node_state.cached_output
		if cached.type == StoryFlowTypes.VariableType.BOOLEAN:
			_context.evaluation_depth -= 1
			return cached.get_bool()

	var node := _context.current_script.get_node(node_id)
	if node.is_empty():
		_context.evaluation_depth -= 1
		return false

	var node_type: StoryFlowTypes.NodeType = node.get("type", StoryFlowTypes.NodeType.UNKNOWN)
	var data: Dictionary = node.get("data", {})

	match node_type:
		StoryFlowTypes.NodeType.GET_BOOL:
			var variable := _find_variable(data)
			if not variable.is_empty():
				var value = variable.get("value")
				if value is StoryFlowVariant:
					result = value.get_bool()

		StoryFlowTypes.NodeType.NOT_BOOL:
			var input := evaluate_boolean_input(node_id, StoryFlowHandles.IN_BOOLEAN, _get_data_bool(data, "value", false))
			result = not input

		StoryFlowTypes.NodeType.AND_BOOL:
			var input1 := evaluate_boolean_input(node_id, StoryFlowHandles.IN_BOOLEAN1, _get_data_bool(data, "value1", false))
			var input2 := evaluate_boolean_input(node_id, StoryFlowHandles.IN_BOOLEAN2, _get_data_bool(data, "value2", false))
			result = input1 and input2

		StoryFlowTypes.NodeType.OR_BOOL:
			var input1 := evaluate_boolean_input(node_id, StoryFlowHandles.IN_BOOLEAN1, _get_data_bool(data, "value1", false))
			var input2 := evaluate_boolean_input(node_id, StoryFlowHandles.IN_BOOLEAN2, _get_data_bool(data, "value2", false))
			result = input1 or input2

		StoryFlowTypes.NodeType.EQUAL_BOOL:
			var input1 := evaluate_boolean_input(node_id, StoryFlowHandles.IN_BOOLEAN1, _get_data_bool(data, "value1", false))
			var input2 := evaluate_boolean_input(node_id, StoryFlowHandles.IN_BOOLEAN2, _get_data_bool(data, "value2", false))
			result = (input1 == input2)

		StoryFlowTypes.NodeType.GREATER_THAN, \
		StoryFlowTypes.NodeType.GREATER_THAN_OR_EQUAL, \
		StoryFlowTypes.NodeType.LESS_THAN, \
		StoryFlowTypes.NodeType.LESS_THAN_OR_EQUAL, \
		StoryFlowTypes.NodeType.EQUAL_INT:
			result = _evaluate_integer_comparison(node_id, data, node_type)

		StoryFlowTypes.NodeType.GREATER_THAN_FLOAT, \
		StoryFlowTypes.NodeType.GREATER_THAN_OR_EQUAL_FLOAT, \
		StoryFlowTypes.NodeType.LESS_THAN_FLOAT, \
		StoryFlowTypes.NodeType.LESS_THAN_OR_EQUAL_FLOAT, \
		StoryFlowTypes.NodeType.EQUAL_FLOAT:
			result = _evaluate_float_comparison(node_id, data, node_type)

		StoryFlowTypes.NodeType.EQUAL_STRING:
			var input1 := evaluate_string_input(node_id, StoryFlowHandles.IN_STRING1, _get_localized_data_string(data, "value1"))
			var input2 := evaluate_string_input(node_id, StoryFlowHandles.IN_STRING2, _get_localized_data_string(data, "value2"))
			result = (input1 == input2)

		StoryFlowTypes.NodeType.CONTAINS_STRING:
			var haystack := evaluate_string_input(node_id, StoryFlowHandles.IN_STRING1, _get_localized_data_string(data, "value1"))
			var needle := evaluate_string_input(node_id, StoryFlowHandles.IN_STRING2, _get_localized_data_string(data, "value2"))
			result = haystack.contains(needle)

		StoryFlowTypes.NodeType.EQUAL_ENUM:
			var input1 := evaluate_enum_input(node_id, StoryFlowHandles.IN_ENUM1, _get_data_string(data, "value1"))
			var input2 := evaluate_enum_input(node_id, StoryFlowHandles.IN_ENUM2, _get_data_string(data, "value2"))
			result = (input1 == input2)

		StoryFlowTypes.NodeType.INT_TO_BOOLEAN:
			var input := evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER, _get_data_int(data, "value", 0))
			result = (input != 0)

		StoryFlowTypes.NodeType.FLOAT_TO_BOOLEAN:
			var input := evaluate_float_input(node_id, StoryFlowHandles.IN_FLOAT, _get_data_float(data, "value", 0.0))
			result = not is_zero_approx(input)

		StoryFlowTypes.NodeType.ARRAY_CONTAINS_BOOL:
			var arr := evaluate_bool_array_input(node_id, StoryFlowHandles.IN_BOOL_ARRAY)
			var value := evaluate_boolean_input(node_id, StoryFlowHandles.IN_BOOLEAN, _get_data_bool(data, "value", false))
			for element: StoryFlowVariant in arr:
				if element.get_bool() == value:
					result = true
					break

		StoryFlowTypes.NodeType.ARRAY_CONTAINS_INT:
			var arr := evaluate_int_array_input(node_id, StoryFlowHandles.IN_INT_ARRAY)
			var value := evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER, _get_data_int(data, "value", 0))
			for element: StoryFlowVariant in arr:
				if element.get_int() == value:
					result = true
					break

		StoryFlowTypes.NodeType.ARRAY_CONTAINS_FLOAT:
			var arr := evaluate_float_array_input(node_id, StoryFlowHandles.IN_FLOAT_ARRAY)
			var value := evaluate_float_input(node_id, StoryFlowHandles.IN_FLOAT, _get_data_float(data, "value", 0.0))
			for element: StoryFlowVariant in arr:
				if is_equal_approx(element.get_float(), value):
					result = true
					break

		StoryFlowTypes.NodeType.ARRAY_CONTAINS_STRING:
			var arr := evaluate_string_array_input(node_id, StoryFlowHandles.IN_STRING_ARRAY)
			var value := evaluate_string_input(node_id, StoryFlowHandles.IN_STRING, _get_localized_data_string(data, "value"))
			for element: StoryFlowVariant in arr:
				if element.get_string() == value:
					result = true
					break

		StoryFlowTypes.NodeType.ARRAY_CONTAINS_IMAGE:
			var arr := evaluate_image_array_input(node_id, StoryFlowHandles.IN_IMAGE_ARRAY)
			var value := evaluate_string_input(node_id, StoryFlowHandles.IN_IMAGE, _get_data_string(data, "value"))
			for element: StoryFlowVariant in arr:
				if element.get_string() == value:
					result = true
					break

		StoryFlowTypes.NodeType.ARRAY_CONTAINS_CHARACTER:
			var arr := evaluate_character_array_input(node_id, StoryFlowHandles.IN_CHARACTER_ARRAY)
			var value := evaluate_string_input(node_id, StoryFlowHandles.IN_CHARACTER, _get_data_string(data, "value"))
			for element: StoryFlowVariant in arr:
				if element.get_string() == value:
					result = true
					break

		StoryFlowTypes.NodeType.ARRAY_CONTAINS_AUDIO:
			var arr := evaluate_audio_array_input(node_id, StoryFlowHandles.IN_AUDIO_ARRAY)
			var value := evaluate_string_input(node_id, StoryFlowHandles.IN_AUDIO, _get_data_string(data, "value"))
			for element: StoryFlowVariant in arr:
				if element.get_string() == value:
					result = true
					break

		StoryFlowTypes.NodeType.GET_BOOL_ARRAY_ELEMENT:
			var arr := evaluate_bool_array_input(node_id, StoryFlowHandles.IN_BOOL_ARRAY)
			var index := evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER, _get_data_int(data, "value", 0))
			if index >= 0 and index < arr.size():
				result = arr[index].get_bool()

		StoryFlowTypes.NodeType.GET_RANDOM_BOOL_ARRAY_ELEMENT:
			var arr := evaluate_bool_array_input(node_id, StoryFlowHandles.IN_BOOL_ARRAY)
			if arr.size() > 0:
				result = arr[randi_range(0, arr.size() - 1)].get_bool()

		StoryFlowTypes.NodeType.RUN_SCRIPT:
			result = _evaluate_run_script_output_bool(node_id, source_handle, data)

		StoryFlowTypes.NodeType.GET_CHARACTER_VAR:
			var char_result := _evaluate_character_variable(data, node_id)
			if char_result is StoryFlowVariant:
				result = char_result.get_bool()

		StoryFlowTypes.NodeType.FOR_EACH_BOOL_LOOP:
			var ns := _context.get_node_state(node_id)
			if ns.cached_output != null:
				result = ns.cached_output.get_bool()

		_:
			result = false

	# Cache result
	var cached_variant := StoryFlowVariant.from_bool(result)
	node_state.cached_output = cached_variant

	_sf_trace("EVAL %s %s result=%s" % [node_id, StoryFlowComponent._node_type_name(node_type), str(result).to_lower()])

	_context.evaluation_depth -= 1
	return result


# =============================================================================
# Integer Evaluation
# =============================================================================

func evaluate_integer_input(node_id: String, handle_suffix: String, fallback: int = 0) -> int:
	if not _context or not _context.current_script:
		return fallback

	var edge := _context.current_script.find_input_edge(node_id, handle_suffix)
	if edge.is_empty():
		return fallback

	var source_node := _context.current_script.get_node(edge.get("source", ""))
	if source_node.is_empty():
		return fallback

	return evaluate_integer_from_node(edge.get("source", ""), edge.get("source_handle", ""))


func evaluate_integer_from_node(node_id: String, source_handle: String = "") -> int:
	if not _context or not _context.current_script:
		return 0

	# Depth guard
	if _context.evaluation_depth >= StoryFlowExecutionContext.MAX_EVALUATION_DEPTH:
		push_error("StoryFlow: Max evaluation depth exceeded")
		return 0
	_context.evaluation_depth += 1

	var result: int = 0

	var node := _context.current_script.get_node(node_id)
	if node.is_empty():
		_context.evaluation_depth -= 1
		return 0

	var node_type: StoryFlowTypes.NodeType = node.get("type", StoryFlowTypes.NodeType.UNKNOWN)
	var data: Dictionary = node.get("data", {})

	match node_type:
		StoryFlowTypes.NodeType.GET_INT:
			var variable := _find_variable(data)
			if not variable.is_empty():
				var value = variable.get("value")
				if value is StoryFlowVariant:
					result = value.get_int()

		StoryFlowTypes.NodeType.PLUS:
			var input1 := evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER1, _get_data_int(data, "value1", 0))
			var input2 := evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER2, _get_data_int(data, "value2", 0))
			result = input1 + input2

		StoryFlowTypes.NodeType.MINUS:
			var input1 := evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER1, _get_data_int(data, "value1", 0))
			var input2 := evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER2, _get_data_int(data, "value2", 0))
			result = input1 - input2

		StoryFlowTypes.NodeType.MULTIPLY:
			var input1 := evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER1, _get_data_int(data, "value1", 0))
			var input2 := evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER2, _get_data_int(data, "value2", 0))
			result = input1 * input2

		StoryFlowTypes.NodeType.DIVIDE:
			var input1 := evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER1, _get_data_int(data, "value1", 0))
			var input2 := evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER2, _get_data_int(data, "value2", 1))
			result = (input1 / input2) if input2 != 0 else 0

		StoryFlowTypes.NodeType.RANDOM:
			var min_val := evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER1, _get_data_int(data, "value1", 0))
			var max_val := evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER2, _get_data_int(data, "value2", 100))
			if min_val > max_val:
				var temp := min_val
				min_val = max_val
				max_val = temp
			result = randi_range(min_val, max_val)

		StoryFlowTypes.NodeType.BOOLEAN_TO_INT:
			var input := evaluate_boolean_input(node_id, StoryFlowHandles.IN_BOOLEAN, _get_data_bool(data, "value", false))
			result = 1 if input else 0

		StoryFlowTypes.NodeType.FLOAT_TO_INT:
			var input := evaluate_float_input(node_id, StoryFlowHandles.IN_FLOAT, _get_data_float(data, "value", 0.0))
			result = floori(input)

		StoryFlowTypes.NodeType.STRING_TO_INT:
			var input := evaluate_string_input(node_id, StoryFlowHandles.IN_STRING, _get_data_string(data, "value"))
			result = input.to_int()

		StoryFlowTypes.NodeType.LENGTH_STRING:
			var input := evaluate_string_input(node_id, StoryFlowHandles.IN_STRING, _get_data_string(data, "value"))
			result = input.length()

		StoryFlowTypes.NodeType.ARRAY_LENGTH_BOOL:
			var arr := evaluate_bool_array_input(node_id, StoryFlowHandles.IN_BOOL_ARRAY)
			result = arr.size()

		StoryFlowTypes.NodeType.ARRAY_LENGTH_INT:
			var arr := evaluate_int_array_input(node_id, StoryFlowHandles.IN_INT_ARRAY)
			result = arr.size()

		StoryFlowTypes.NodeType.ARRAY_LENGTH_FLOAT:
			var arr := evaluate_float_array_input(node_id, StoryFlowHandles.IN_FLOAT_ARRAY)
			result = arr.size()

		StoryFlowTypes.NodeType.ARRAY_LENGTH_STRING:
			var arr := evaluate_string_array_input(node_id, StoryFlowHandles.IN_STRING_ARRAY)
			result = arr.size()

		StoryFlowTypes.NodeType.ARRAY_LENGTH_IMAGE:
			var arr := evaluate_image_array_input(node_id, StoryFlowHandles.IN_IMAGE_ARRAY)
			result = arr.size()

		StoryFlowTypes.NodeType.ARRAY_LENGTH_CHARACTER:
			var arr := evaluate_character_array_input(node_id, StoryFlowHandles.IN_CHARACTER_ARRAY)
			result = arr.size()

		StoryFlowTypes.NodeType.ARRAY_LENGTH_AUDIO:
			var arr := evaluate_audio_array_input(node_id, StoryFlowHandles.IN_AUDIO_ARRAY)
			result = arr.size()

		StoryFlowTypes.NodeType.FIND_IN_BOOL_ARRAY:
			var arr := evaluate_bool_array_input(node_id, StoryFlowHandles.IN_BOOL_ARRAY)
			var value := evaluate_boolean_input(node_id, StoryFlowHandles.IN_BOOLEAN, _get_data_bool(data, "value", false))
			result = -1
			for i in range(arr.size()):
				if arr[i].get_bool() == value:
					result = i
					break

		StoryFlowTypes.NodeType.FIND_IN_INT_ARRAY:
			var arr := evaluate_int_array_input(node_id, StoryFlowHandles.IN_INT_ARRAY)
			var value := evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER, _get_data_int(data, "value", 0))
			result = -1
			for i in range(arr.size()):
				if arr[i].get_int() == value:
					result = i
					break

		StoryFlowTypes.NodeType.FIND_IN_FLOAT_ARRAY:
			var arr := evaluate_float_array_input(node_id, StoryFlowHandles.IN_FLOAT_ARRAY)
			var value := evaluate_float_input(node_id, StoryFlowHandles.IN_FLOAT, _get_data_float(data, "value", 0.0))
			result = -1
			for i in range(arr.size()):
				if is_equal_approx(arr[i].get_float(), value):
					result = i
					break

		StoryFlowTypes.NodeType.FIND_IN_STRING_ARRAY:
			var arr := evaluate_string_array_input(node_id, StoryFlowHandles.IN_STRING_ARRAY)
			var value := evaluate_string_input(node_id, StoryFlowHandles.IN_STRING, _get_localized_data_string(data, "value"))
			result = -1
			for i in range(arr.size()):
				if arr[i].get_string() == value:
					result = i
					break

		StoryFlowTypes.NodeType.FIND_IN_IMAGE_ARRAY:
			var arr := evaluate_image_array_input(node_id, StoryFlowHandles.IN_IMAGE_ARRAY)
			var value := evaluate_string_input(node_id, StoryFlowHandles.IN_IMAGE, _get_data_string(data, "value"))
			result = -1
			for i in range(arr.size()):
				if arr[i].get_string() == value:
					result = i
					break

		StoryFlowTypes.NodeType.FIND_IN_CHARACTER_ARRAY:
			var arr := evaluate_character_array_input(node_id, StoryFlowHandles.IN_CHARACTER_ARRAY)
			var value := evaluate_string_input(node_id, StoryFlowHandles.IN_CHARACTER, _get_data_string(data, "value"))
			result = -1
			for i in range(arr.size()):
				if arr[i].get_string() == value:
					result = i
					break

		StoryFlowTypes.NodeType.FIND_IN_AUDIO_ARRAY:
			var arr := evaluate_audio_array_input(node_id, StoryFlowHandles.IN_AUDIO_ARRAY)
			var value := evaluate_string_input(node_id, StoryFlowHandles.IN_AUDIO, _get_data_string(data, "value"))
			result = -1
			for i in range(arr.size()):
				if arr[i].get_string() == value:
					result = i
					break

		StoryFlowTypes.NodeType.GET_INT_ARRAY_ELEMENT:
			var arr := evaluate_int_array_input(node_id, StoryFlowHandles.IN_INT_ARRAY)
			var index := evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER, _get_data_int(data, "value", 0))
			if index >= 0 and index < arr.size():
				result = arr[index].get_int()

		StoryFlowTypes.NodeType.GET_RANDOM_INT_ARRAY_ELEMENT:
			var arr := evaluate_int_array_input(node_id, StoryFlowHandles.IN_INT_ARRAY)
			if arr.size() > 0:
				result = arr[randi_range(0, arr.size() - 1)].get_int()

		StoryFlowTypes.NodeType.FOR_EACH_INT_LOOP, \
		StoryFlowTypes.NodeType.FOR_EACH_BOOL_LOOP, \
		StoryFlowTypes.NodeType.FOR_EACH_FLOAT_LOOP, \
		StoryFlowTypes.NodeType.FOR_EACH_STRING_LOOP, \
		StoryFlowTypes.NodeType.FOR_EACH_IMAGE_LOOP, \
		StoryFlowTypes.NodeType.FOR_EACH_CHARACTER_LOOP, \
		StoryFlowTypes.NodeType.FOR_EACH_AUDIO_LOOP:
			var loop_state := _context.get_node_state(node_id)
			if source_handle.contains(StoryFlowHandles.IN_INTEGER_INDEX):
				result = loop_state.loop_index
			elif node_type == StoryFlowTypes.NodeType.FOR_EACH_INT_LOOP and loop_state.cached_output != null:
				result = loop_state.cached_output.get_int()

		StoryFlowTypes.NodeType.RUN_SCRIPT:
			result = _evaluate_run_script_output_int(node_id, source_handle, data)

		StoryFlowTypes.NodeType.GET_CHARACTER_VAR:
			var char_result := _evaluate_character_variable(data, node_id)
			if char_result is StoryFlowVariant:
				result = char_result.get_int()

		_:
			result = 0

	_sf_trace("EVAL %s %s result=%s" % [node_id, StoryFlowComponent._node_type_name(node_type), str(result)])

	_context.evaluation_depth -= 1
	return result


# =============================================================================
# Float Evaluation
# =============================================================================

func evaluate_float_input(node_id: String, handle_suffix: String, fallback: float = 0.0) -> float:
	if not _context or not _context.current_script:
		return fallback

	var edge := _context.current_script.find_input_edge(node_id, handle_suffix)
	if edge.is_empty():
		return fallback

	var source_node := _context.current_script.get_node(edge.get("source", ""))
	if source_node.is_empty():
		return fallback

	return evaluate_float_from_node(edge.get("source", ""), edge.get("source_handle", ""))


func evaluate_float_from_node(node_id: String, source_handle: String = "") -> float:
	if not _context or not _context.current_script:
		return 0.0

	# Depth guard
	if _context.evaluation_depth >= StoryFlowExecutionContext.MAX_EVALUATION_DEPTH:
		push_error("StoryFlow: Max evaluation depth exceeded")
		return 0.0
	_context.evaluation_depth += 1

	var result: float = 0.0

	var node := _context.current_script.get_node(node_id)
	if node.is_empty():
		_context.evaluation_depth -= 1
		return 0.0

	var node_type: StoryFlowTypes.NodeType = node.get("type", StoryFlowTypes.NodeType.UNKNOWN)
	var data: Dictionary = node.get("data", {})

	match node_type:
		StoryFlowTypes.NodeType.GET_FLOAT:
			var variable := _find_variable(data)
			if not variable.is_empty():
				var value = variable.get("value")
				if value is StoryFlowVariant:
					result = value.get_float()

		StoryFlowTypes.NodeType.PLUS_FLOAT:
			var input1 := evaluate_float_input(node_id, StoryFlowHandles.IN_FLOAT1, _get_data_float(data, "value1", 0.0))
			var input2 := evaluate_float_input(node_id, StoryFlowHandles.IN_FLOAT2, _get_data_float(data, "value2", 0.0))
			result = input1 + input2

		StoryFlowTypes.NodeType.MINUS_FLOAT:
			var input1 := evaluate_float_input(node_id, StoryFlowHandles.IN_FLOAT1, _get_data_float(data, "value1", 0.0))
			var input2 := evaluate_float_input(node_id, StoryFlowHandles.IN_FLOAT2, _get_data_float(data, "value2", 0.0))
			result = input1 - input2

		StoryFlowTypes.NodeType.MULTIPLY_FLOAT:
			var input1 := evaluate_float_input(node_id, StoryFlowHandles.IN_FLOAT1, _get_data_float(data, "value1", 0.0))
			var input2 := evaluate_float_input(node_id, StoryFlowHandles.IN_FLOAT2, _get_data_float(data, "value2", 0.0))
			result = input1 * input2

		StoryFlowTypes.NodeType.DIVIDE_FLOAT:
			var input1 := evaluate_float_input(node_id, StoryFlowHandles.IN_FLOAT1, _get_data_float(data, "value1", 0.0))
			var input2 := evaluate_float_input(node_id, StoryFlowHandles.IN_FLOAT2, _get_data_float(data, "value2", 1.0))
			result = (input1 / input2) if not is_zero_approx(input2) else 0.0

		StoryFlowTypes.NodeType.RANDOM_FLOAT:
			var min_val := evaluate_float_input(node_id, StoryFlowHandles.IN_FLOAT1, _get_data_float(data, "value1", 0.0))
			var max_val := evaluate_float_input(node_id, StoryFlowHandles.IN_FLOAT2, _get_data_float(data, "value2", 1.0))
			if min_val > max_val:
				var temp := min_val
				min_val = max_val
				max_val = temp
			result = randf_range(min_val, max_val)

		StoryFlowTypes.NodeType.BOOLEAN_TO_FLOAT:
			var input := evaluate_boolean_input(node_id, StoryFlowHandles.IN_BOOLEAN, _get_data_bool(data, "value", false))
			result = 1.0 if input else 0.0

		StoryFlowTypes.NodeType.INT_TO_FLOAT:
			var input := evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER, _get_data_int(data, "value", 0))
			result = float(input)

		StoryFlowTypes.NodeType.STRING_TO_FLOAT:
			var input := evaluate_string_input(node_id, StoryFlowHandles.IN_STRING, _get_data_string(data, "value"))
			result = input.to_float()

		StoryFlowTypes.NodeType.GET_FLOAT_ARRAY_ELEMENT:
			var arr := evaluate_float_array_input(node_id, StoryFlowHandles.IN_FLOAT_ARRAY)
			var index := evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER, _get_data_int(data, "value", 0))
			if index >= 0 and index < arr.size():
				result = arr[index].get_float()

		StoryFlowTypes.NodeType.GET_RANDOM_FLOAT_ARRAY_ELEMENT:
			var arr := evaluate_float_array_input(node_id, StoryFlowHandles.IN_FLOAT_ARRAY)
			if arr.size() > 0:
				result = arr[randi_range(0, arr.size() - 1)].get_float()

		StoryFlowTypes.NodeType.FOR_EACH_FLOAT_LOOP:
			var loop_state := _context.get_node_state(node_id)
			if loop_state.cached_output != null:
				result = loop_state.cached_output.get_float()

		StoryFlowTypes.NodeType.RUN_SCRIPT:
			result = _evaluate_run_script_output_float(node_id, source_handle, data)

		StoryFlowTypes.NodeType.GET_CHARACTER_VAR:
			var char_result := _evaluate_character_variable(data, node_id)
			if char_result is StoryFlowVariant:
				result = char_result.get_float()

		_:
			result = 0.0

	_sf_trace("EVAL %s %s result=%s" % [node_id, StoryFlowComponent._node_type_name(node_type), str(result)])

	_context.evaluation_depth -= 1
	return result


# =============================================================================
# String Evaluation
# =============================================================================

func evaluate_string_input(node_id: String, handle_suffix: String, fallback: String = "") -> String:
	if not _context or not _context.current_script:
		return fallback

	var edge := _context.current_script.find_input_edge(node_id, handle_suffix)
	if edge.is_empty():
		return fallback

	var source_node := _context.current_script.get_node(edge.get("source", ""))
	if source_node.is_empty():
		return fallback

	return evaluate_string_from_node(edge.get("source", ""), edge.get("source_handle", ""))


func evaluate_string_from_node(node_id: String, source_handle: String = "") -> String:
	if not _context or not _context.current_script:
		return ""

	# Depth guard
	if _context.evaluation_depth >= StoryFlowExecutionContext.MAX_EVALUATION_DEPTH:
		push_error("StoryFlow: Max evaluation depth exceeded")
		return ""
	_context.evaluation_depth += 1

	var result: String = ""

	var node := _context.current_script.get_node(node_id)
	if node.is_empty():
		_context.evaluation_depth -= 1
		return ""

	var node_type: StoryFlowTypes.NodeType = node.get("type", StoryFlowTypes.NodeType.UNKNOWN)
	var data: Dictionary = node.get("data", {})

	match node_type:
		StoryFlowTypes.NodeType.GET_STRING:
			var variable := _find_variable(data)
			if not variable.is_empty():
				var value = variable.get("value")
				if value is StoryFlowVariant:
					result = value.get_string()

		StoryFlowTypes.NodeType.CONCATENATE_STRING:
			var input1 := evaluate_string_input(node_id, StoryFlowHandles.IN_STRING1, _get_localized_data_string(data, "value1"))
			var input2 := evaluate_string_input(node_id, StoryFlowHandles.IN_STRING2, _get_localized_data_string(data, "value2"))
			result = input1 + input2

		StoryFlowTypes.NodeType.TO_UPPER_CASE:
			var input := evaluate_string_input(node_id, StoryFlowHandles.IN_STRING, _get_data_string(data, "value"))
			result = input.to_upper()

		StoryFlowTypes.NodeType.TO_LOWER_CASE:
			var input := evaluate_string_input(node_id, StoryFlowHandles.IN_STRING, _get_data_string(data, "value"))
			result = input.to_lower()

		StoryFlowTypes.NodeType.INT_TO_STRING:
			var input := evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER, _get_data_int(data, "value", 0))
			result = str(input)

		StoryFlowTypes.NodeType.FLOAT_TO_STRING:
			var input := evaluate_float_input(node_id, StoryFlowHandles.IN_FLOAT, _get_data_float(data, "value", 0.0))
			result = str(input)

		StoryFlowTypes.NodeType.GET_ENUM:
			var variable := _find_variable(data)
			if not variable.is_empty():
				var value = variable.get("value")
				if value is StoryFlowVariant:
					result = value.get_string()

		StoryFlowTypes.NodeType.ENUM_TO_STRING:
			var input := evaluate_enum_input(node_id, StoryFlowHandles.IN_ENUM, _get_data_string(data, "value"))
			result = input

		StoryFlowTypes.NodeType.GET_IMAGE:
			var variable := _find_variable(data)
			if not variable.is_empty():
				var value = variable.get("value")
				if value is StoryFlowVariant:
					result = value.get_string()

		StoryFlowTypes.NodeType.GET_AUDIO:
			var variable := _find_variable(data)
			if not variable.is_empty():
				var value = variable.get("value")
				if value is StoryFlowVariant:
					result = value.get_string()

		StoryFlowTypes.NodeType.GET_CHARACTER:
			var variable := _find_variable(data)
			if not variable.is_empty():
				var value = variable.get("value")
				if value is StoryFlowVariant:
					result = value.get_string()

		StoryFlowTypes.NodeType.GET_STRING_ARRAY_ELEMENT:
			var arr := evaluate_string_array_input(node_id, StoryFlowHandles.IN_STRING_ARRAY)
			var index := evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER, _get_data_int(data, "value", 0))
			if index >= 0 and index < arr.size():
				result = arr[index].get_string()

		StoryFlowTypes.NodeType.GET_RANDOM_STRING_ARRAY_ELEMENT:
			var arr := evaluate_string_array_input(node_id, StoryFlowHandles.IN_STRING_ARRAY)
			if arr.size() > 0:
				result = arr[randi_range(0, arr.size() - 1)].get_string()

		StoryFlowTypes.NodeType.GET_IMAGE_ARRAY_ELEMENT:
			var arr := evaluate_image_array_input(node_id, StoryFlowHandles.IN_IMAGE_ARRAY)
			var index := evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER, _get_data_int(data, "value", 0))
			if index >= 0 and index < arr.size():
				result = arr[index].get_string()

		StoryFlowTypes.NodeType.GET_RANDOM_IMAGE_ARRAY_ELEMENT:
			var arr := evaluate_image_array_input(node_id, StoryFlowHandles.IN_IMAGE_ARRAY)
			if arr.size() > 0:
				result = arr[randi_range(0, arr.size() - 1)].get_string()

		StoryFlowTypes.NodeType.GET_CHARACTER_ARRAY_ELEMENT:
			var arr := evaluate_character_array_input(node_id, StoryFlowHandles.IN_CHARACTER_ARRAY)
			var index := evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER, _get_data_int(data, "value", 0))
			if index >= 0 and index < arr.size():
				result = arr[index].get_string()

		StoryFlowTypes.NodeType.GET_RANDOM_CHARACTER_ARRAY_ELEMENT:
			var arr := evaluate_character_array_input(node_id, StoryFlowHandles.IN_CHARACTER_ARRAY)
			if arr.size() > 0:
				result = arr[randi_range(0, arr.size() - 1)].get_string()

		StoryFlowTypes.NodeType.GET_AUDIO_ARRAY_ELEMENT:
			var arr := evaluate_audio_array_input(node_id, StoryFlowHandles.IN_AUDIO_ARRAY)
			var index := evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER, _get_data_int(data, "value", 0))
			if index >= 0 and index < arr.size():
				result = arr[index].get_string()

		StoryFlowTypes.NodeType.GET_RANDOM_AUDIO_ARRAY_ELEMENT:
			var arr := evaluate_audio_array_input(node_id, StoryFlowHandles.IN_AUDIO_ARRAY)
			if arr.size() > 0:
				result = arr[randi_range(0, arr.size() - 1)].get_string()

		StoryFlowTypes.NodeType.FOR_EACH_STRING_LOOP, \
		StoryFlowTypes.NodeType.FOR_EACH_IMAGE_LOOP, \
		StoryFlowTypes.NodeType.FOR_EACH_CHARACTER_LOOP, \
		StoryFlowTypes.NodeType.FOR_EACH_AUDIO_LOOP:
			var loop_state := _context.get_node_state(node_id)
			if loop_state.cached_output != null:
				result = loop_state.cached_output.get_string()

		StoryFlowTypes.NodeType.RUN_SCRIPT:
			result = _evaluate_run_script_output_string(node_id, source_handle, data)

		StoryFlowTypes.NodeType.GET_CHARACTER_VAR:
			var char_result := _evaluate_character_variable(data, node_id)
			if char_result is StoryFlowVariant:
				result = char_result.get_string()

		_:
			result = ""

	var resolved_result := _resolve_string_key(result)
	_sf_trace("EVAL %s %s result=%s" % [node_id, StoryFlowComponent._node_type_name(node_type), resolved_result])

	_context.evaluation_depth -= 1
	return resolved_result


# =============================================================================
# Enum Evaluation
# =============================================================================

func evaluate_enum_input(node_id: String, handle_suffix: String, fallback: String = "") -> String:
	# Enums are stored as strings - delegate to string input evaluation
	return evaluate_string_input(node_id, handle_suffix, fallback)


func evaluate_enum_from_node(node_id: String, source_handle: String = "") -> String:
	if not _context or not _context.current_script:
		return ""

	# Depth guard
	if _context.evaluation_depth >= StoryFlowExecutionContext.MAX_EVALUATION_DEPTH:
		push_error("StoryFlow: Max evaluation depth exceeded")
		return ""
	_context.evaluation_depth += 1

	var result: String = ""

	var node := _context.current_script.get_node(node_id)
	if node.is_empty():
		_context.evaluation_depth -= 1
		return ""

	var node_type: StoryFlowTypes.NodeType = node.get("type", StoryFlowTypes.NodeType.UNKNOWN)
	var data: Dictionary = node.get("data", {})

	match node_type:
		StoryFlowTypes.NodeType.GET_ENUM:
			var variable := _find_variable(data)
			if not variable.is_empty():
				var value = variable.get("value")
				if value is StoryFlowVariant:
					result = value.get_string()

		StoryFlowTypes.NodeType.ENUM_TO_STRING:
			result = evaluate_enum_input(node_id, StoryFlowHandles.IN_ENUM, _get_data_string(data, "value"))

		StoryFlowTypes.NodeType.INT_TO_ENUM:
			var int_val := evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER, _get_data_int(data, "value", 0))
			var enum_values: Array = data.get("enumValues", [])
			if enum_values.size() > 0:
				var clamped_index := clampi(int_val, 0, enum_values.size() - 1)
				result = str(enum_values[clamped_index])

		StoryFlowTypes.NodeType.STRING_TO_ENUM:
			var str_val := evaluate_string_input(node_id, StoryFlowHandles.IN_STRING, _get_data_string(data, "value"))
			var enum_values: Array = data.get("enumValues", [])
			if enum_values.has(str_val):
				result = str_val
			elif enum_values.size() > 0:
				result = str(enum_values[0])

		StoryFlowTypes.NodeType.GET_CHARACTER_VAR:
			var char_result := _evaluate_character_variable(data, node_id)
			if char_result is StoryFlowVariant:
				result = char_result.get_string()

		StoryFlowTypes.NodeType.RUN_SCRIPT:
			result = _evaluate_run_script_output_string(node_id, source_handle, data)

		_:
			result = ""

	_sf_trace("EVAL %s %s result=%s" % [node_id, StoryFlowComponent._node_type_name(node_type), result])

	_context.evaluation_depth -= 1
	return result


# =============================================================================
# Array Evaluation
# =============================================================================

func evaluate_bool_array_input(node_id: String, handle_suffix: String) -> Array:
	return _evaluate_array_input_generic(node_id, handle_suffix, StoryFlowTypes.NodeType.GET_BOOL_ARRAY)


func evaluate_int_array_input(node_id: String, handle_suffix: String) -> Array:
	return _evaluate_array_input_generic(node_id, handle_suffix, StoryFlowTypes.NodeType.GET_INT_ARRAY)


func evaluate_float_array_input(node_id: String, handle_suffix: String) -> Array:
	return _evaluate_array_input_generic(node_id, handle_suffix, StoryFlowTypes.NodeType.GET_FLOAT_ARRAY)


func evaluate_string_array_input(node_id: String, handle_suffix: String) -> Array:
	return _evaluate_array_input_generic(node_id, handle_suffix, StoryFlowTypes.NodeType.GET_STRING_ARRAY)


func evaluate_image_array_input(node_id: String, handle_suffix: String) -> Array:
	return _evaluate_array_input_generic(node_id, handle_suffix, StoryFlowTypes.NodeType.GET_IMAGE_ARRAY)


func evaluate_character_array_input(node_id: String, handle_suffix: String) -> Array:
	return _evaluate_array_input_generic(node_id, handle_suffix, StoryFlowTypes.NodeType.GET_CHARACTER_ARRAY)


func evaluate_audio_array_input(node_id: String, handle_suffix: String) -> Array:
	return _evaluate_array_input_generic(node_id, handle_suffix, StoryFlowTypes.NodeType.GET_AUDIO_ARRAY)


func _evaluate_array_input_generic(node_id: String, handle_suffix: String, expected_get_array_type: int) -> Array:
	if not _context or not _context.current_script:
		return []

	var edge := _context.current_script.find_input_edge(node_id, handle_suffix)
	if edge.is_empty():
		return []

	var source_id: String = edge.get("source", "")
	var source_node := _context.current_script.get_node(source_id)
	if source_node.is_empty():
		return []

	var source_type: StoryFlowTypes.NodeType = source_node.get("type", StoryFlowTypes.NodeType.UNKNOWN)
	var source_data: Dictionary = source_node.get("data", {})

	# Handle getCharacterVar nodes that can return arrays
	if source_type == StoryFlowTypes.NodeType.GET_CHARACTER_VAR:
		var variant := _evaluate_character_variable(source_data, source_id)
		return variant.get_array()

	# Handle array modify nodes (add/remove/clear) that output their result array.
	# The HTML runtime stores the result via setNodeOutputValue; we use the node's cached output.
	var NT := StoryFlowTypes.NodeType
	if source_type in [
		NT.ADD_TO_BOOL_ARRAY, NT.ADD_TO_INT_ARRAY, NT.ADD_TO_FLOAT_ARRAY,
		NT.ADD_TO_STRING_ARRAY, NT.ADD_TO_IMAGE_ARRAY, NT.ADD_TO_CHARACTER_ARRAY, NT.ADD_TO_AUDIO_ARRAY,
		NT.REMOVE_FROM_BOOL_ARRAY, NT.REMOVE_FROM_INT_ARRAY, NT.REMOVE_FROM_FLOAT_ARRAY,
		NT.REMOVE_FROM_STRING_ARRAY, NT.REMOVE_FROM_IMAGE_ARRAY, NT.REMOVE_FROM_CHARACTER_ARRAY, NT.REMOVE_FROM_AUDIO_ARRAY,
		NT.CLEAR_BOOL_ARRAY, NT.CLEAR_INT_ARRAY, NT.CLEAR_FLOAT_ARRAY,
		NT.CLEAR_STRING_ARRAY, NT.CLEAR_IMAGE_ARRAY, NT.CLEAR_CHARACTER_ARRAY, NT.CLEAR_AUDIO_ARRAY,
		NT.SET_BOOL_ARRAY, NT.SET_INT_ARRAY, NT.SET_FLOAT_ARRAY,
		NT.SET_STRING_ARRAY, NT.SET_IMAGE_ARRAY, NT.SET_CHARACTER_ARRAY, NT.SET_AUDIO_ARRAY]:
		var ns := _context.get_node_state(source_id)
		if ns.cached_output != null and ns.cached_output is StoryFlowVariant:
			return ns.cached_output.get_array()
		return []

	# Handle forEach loop nodes that output their current element array
	if source_type in [NT.FOR_EACH_BOOL_LOOP, NT.FOR_EACH_INT_LOOP, NT.FOR_EACH_FLOAT_LOOP,
		NT.FOR_EACH_STRING_LOOP, NT.FOR_EACH_IMAGE_LOOP, NT.FOR_EACH_CHARACTER_LOOP, NT.FOR_EACH_AUDIO_LOOP]:
		var ns := _context.get_node_state(source_id)
		if ns.cached_output != null and ns.cached_output is StoryFlowVariant:
			return ns.cached_output.get_array()
		return []

	if source_type != expected_get_array_type:
		return []

	var variable := _find_variable(source_data)
	if not variable.is_empty():
		var is_array: bool = variable.get("is_array", false)
		if is_array:
			var value = variable.get("value")
			if value is StoryFlowVariant:
				return value.get_array()

	return []


# =============================================================================
# Boolean Chain Processing
# =============================================================================

## Pre-processes a boolean chain to cache results, walking input connections
## recursively so that all intermediate values are evaluated and cached before
## the final evaluation pass.
func process_boolean_chain(node_id: String) -> void:
	if not _context or not _context.current_script:
		return

	# Depth guard
	if _context.evaluation_depth >= StoryFlowExecutionContext.MAX_EVALUATION_DEPTH:
		push_error("StoryFlow: Max evaluation depth exceeded in process_boolean_chain")
		return
	_context.evaluation_depth += 1

	var node := _context.current_script.get_node(node_id)
	if node.is_empty():
		_context.evaluation_depth -= 1
		return

	var node_type: StoryFlowTypes.NodeType = node.get("type", StoryFlowTypes.NodeType.UNKNOWN)
	var node_state := _context.get_node_state(node_id)

	match node_type:
		StoryFlowTypes.NodeType.NOT_BOOL:
			# Process single input first
			var input_edge := _context.current_script.find_input_edge(node_id, StoryFlowHandles.IN_BOOLEAN)
			if not input_edge.is_empty():
				var source_id: String = input_edge.get("source", "")
				if source_id != "":
					process_boolean_chain(source_id)
			# Then evaluate and cache
			var data: Dictionary = node.get("data", {})
			var input := evaluate_boolean_input(node_id, StoryFlowHandles.IN_BOOLEAN, _get_data_bool(data, "value", false))
			node_state.cached_output = StoryFlowVariant.from_bool(not input)

		StoryFlowTypes.NodeType.AND_BOOL, \
		StoryFlowTypes.NodeType.OR_BOOL, \
		StoryFlowTypes.NodeType.EQUAL_BOOL:
			# Process both inputs recursively
			var edge1 := _context.current_script.find_input_edge(node_id, StoryFlowHandles.IN_BOOLEAN1)
			if not edge1.is_empty():
				var source1_id: String = edge1.get("source", "")
				if source1_id != "":
					process_boolean_chain(source1_id)
			var edge2 := _context.current_script.find_input_edge(node_id, StoryFlowHandles.IN_BOOLEAN2)
			if not edge2.is_empty():
				var source2_id: String = edge2.get("source", "")
				if source2_id != "":
					process_boolean_chain(source2_id)

		StoryFlowTypes.NodeType.BRANCH:
			# Process the condition input
			var cond_edge := _context.current_script.find_input_edge(node_id, StoryFlowHandles.IN_BOOLEAN_CONDITION)
			if not cond_edge.is_empty():
				var cond_source_id: String = cond_edge.get("source", "")
				if cond_source_id != "":
					process_boolean_chain(cond_source_id)

		StoryFlowTypes.NodeType.RUN_SCRIPT:
			# RunScript output depends on source handle to extract variable ID.
			# Only clear the cache so the real evaluation (with correct handle) gets a fresh read.
			node_state.cached_output = null

		_:
			# For all other boolean-producing types (comparisons, array contains,
			# type conversions, etc.), clear cached output first to force fresh
			# evaluation (matches HTML runtime which always overwrites cache).
			node_state.cached_output = null
			evaluate_boolean_from_node(node_id, "")

	_context.evaluation_depth -= 1


# =============================================================================
# Option Visibility
# =============================================================================

## Evaluate whether a dialogue option should be visible.
## Returns true if no visibility connection exists (default visible).
func evaluate_option_visibility(option_data: Dictionary, node_id: String) -> bool:
	if not _context or not _context.current_script:
		return true

	var option_id: String = option_data.get("id", "")
	if option_id.is_empty():
		return true

	# Check if there's a visibility connection for this option
	var handle_suffix := "boolean-%s" % option_id
	var edge := _context.current_script.find_input_edge(node_id, handle_suffix)

	if edge.is_empty():
		return true # No visibility connection means always visible

	var source_id: String = edge.get("source", "")
	var source_node := _context.current_script.get_node(source_id)
	if source_node.is_empty():
		return true

	# Process the boolean chain to ensure all values are cached
	process_boolean_chain(source_id)

	# Evaluate the visibility
	return evaluate_boolean_from_node(source_id, edge.get("source_handle", ""))


# =============================================================================
# Cache Management
# =============================================================================

func clear_cache() -> void:
	if _context:
		_context.clear_cached_outputs()


# =============================================================================
# Comparison Helpers (Private)
# =============================================================================

func _evaluate_integer_comparison(node_id: String, data: Dictionary, comparison_type: int) -> bool:
	var input1 := evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER1, _get_data_int(data, "value1", 0))
	var input2 := evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER2, _get_data_int(data, "value2", 0))

	match comparison_type:
		StoryFlowTypes.NodeType.GREATER_THAN:
			return input1 > input2
		StoryFlowTypes.NodeType.GREATER_THAN_OR_EQUAL:
			return input1 >= input2
		StoryFlowTypes.NodeType.LESS_THAN:
			return input1 < input2
		StoryFlowTypes.NodeType.LESS_THAN_OR_EQUAL:
			return input1 <= input2
		StoryFlowTypes.NodeType.EQUAL_INT:
			return input1 == input2
		_:
			return false


func _evaluate_float_comparison(node_id: String, data: Dictionary, comparison_type: int) -> bool:
	var input1 := evaluate_float_input(node_id, StoryFlowHandles.IN_FLOAT1, _get_data_float(data, "value1", 0.0))
	var input2 := evaluate_float_input(node_id, StoryFlowHandles.IN_FLOAT2, _get_data_float(data, "value2", 0.0))

	match comparison_type:
		StoryFlowTypes.NodeType.GREATER_THAN_FLOAT:
			return input1 > input2
		StoryFlowTypes.NodeType.GREATER_THAN_OR_EQUAL_FLOAT:
			return input1 >= input2
		StoryFlowTypes.NodeType.LESS_THAN_FLOAT:
			return input1 < input2
		StoryFlowTypes.NodeType.LESS_THAN_OR_EQUAL_FLOAT:
			return input1 <= input2
		StoryFlowTypes.NodeType.EQUAL_FLOAT:
			return is_equal_approx(input1, input2)
		_:
			return false


# =============================================================================
# RunScript Output Helpers (Private)
# =============================================================================

func _evaluate_run_script_output_bool(node_id: String, source_handle: String, _data: Dictionary) -> bool:
	var node_state := _context.get_node_state(node_id)
	if node_state.has_output_values and not source_handle.is_empty():
		var var_id := _extract_run_script_output_var_id(source_handle)
		if not var_id.is_empty() and node_state.output_values.has(var_id):
			var val = node_state.output_values[var_id]
			if val is StoryFlowVariant:
				return val.get_bool()
	return false


func _evaluate_run_script_output_int(node_id: String, source_handle: String, _data: Dictionary) -> int:
	var node_state := _context.get_node_state(node_id)
	if node_state.has_output_values and not source_handle.is_empty():
		var var_id := _extract_run_script_output_var_id(source_handle)
		if not var_id.is_empty() and node_state.output_values.has(var_id):
			var val = node_state.output_values[var_id]
			if val is StoryFlowVariant:
				return val.get_int()
	return 0


func _evaluate_run_script_output_float(node_id: String, source_handle: String, _data: Dictionary) -> float:
	var node_state := _context.get_node_state(node_id)
	if node_state.has_output_values and not source_handle.is_empty():
		var var_id := _extract_run_script_output_var_id(source_handle)
		if not var_id.is_empty() and node_state.output_values.has(var_id):
			var val = node_state.output_values[var_id]
			if val is StoryFlowVariant:
				return val.get_float()
	return 0.0


func _evaluate_run_script_output_string(node_id: String, source_handle: String, _data: Dictionary) -> String:
	var node_state := _context.get_node_state(node_id)
	if node_state.has_output_values and not source_handle.is_empty():
		var var_id := _extract_run_script_output_var_id(source_handle)
		if not var_id.is_empty() and node_state.output_values.has(var_id):
			var val = node_state.output_values[var_id]
			if val is StoryFlowVariant:
				return val.get_string()
	return ""


## Extract the variable ID from a RunScript source handle.
## Handle format: "source-{nodeId}-out-{varId}" → returns varId.
## Matches HTML runtime regex /-out-(.+)$/.
func _extract_run_script_output_var_id(source_handle: String) -> String:
	var out_idx := source_handle.find("-out-")
	if out_idx == -1:
		return ""
	return source_handle.substr(out_idx + 5) # skip "-out-"


# =============================================================================
# Character Variable Helper (Private)
# =============================================================================

## Evaluate a getCharacterVar node: find the character and return the variable's value.
func _evaluate_character_variable(data: Dictionary, node_id: String = "") -> StoryFlowVariant:
	var character_path: String = data.get("characterPath", "")

	# Check for connected character input (override dropdown)
	if not node_id.is_empty() and _context and _context.current_script:
		var char_edge: Dictionary = _context.current_script.find_input_edge(node_id, StoryFlowHandles.IN_CHARACTER_INPUT)
		if not char_edge.is_empty():
			var source_node: Dictionary = _context.current_script.get_node(char_edge.get("source", ""))
			if not source_node.is_empty():
				character_path = evaluate_string_from_node(source_node.get("id", ""), char_edge.get("source_handle", ""))

	if character_path.is_empty():
		return StoryFlowVariant.new()

	var normalized_path := StoryFlowCharacter.normalize_path(character_path)
	if not _characters.has(normalized_path):
		push_warning("StoryFlow: Character not found for GetCharacterVar: %s" % character_path)
		return StoryFlowVariant.new()

	var character: StoryFlowCharacter = _characters[normalized_path]
	var variable_name: String = data.get("variableName", "")

	if variable_name.is_empty():
		return StoryFlowVariant.new()

	# Handle built-in "Name" field
	if variable_name.to_lower() == "name":
		return StoryFlowVariant.from_string(character.character_name)

	# Handle built-in "Image" field
	if variable_name.to_lower() == "image":
		return StoryFlowVariant.from_string(character.image_key)

	# Find custom variable
	if character.variables.has(variable_name):
		var var_data: Dictionary = character.variables[variable_name]
		var value = var_data.get("value")
		if value is StoryFlowVariant:
			return value

	push_warning("StoryFlow: Variable '%s' not found on character '%s'" % [variable_name, character_path])
	return StoryFlowVariant.new()


# =============================================================================
# Variable Lookup Helper (Private)
# =============================================================================

## Find a variable from a node's data. Checks is_global to determine scope.
## Returns the variable dictionary or empty dictionary if not found.
func _find_variable(data: Dictionary) -> Dictionary:
	var variable_id: String = data.get("variable", "")
	if variable_id.is_empty():
		return {}

	var is_global: bool = data.get("isGlobal", false)

	if is_global:
		return _global_variables.get(variable_id, {})
	else:
		return _context.local_variables.get(variable_id, {})


# =============================================================================
# Data Access Helpers (Private)
# =============================================================================

## Get a boolean value from node data, with fallback.
func _get_data_bool(data: Dictionary, key: String, fallback: bool = false) -> bool:
	var val = data.get(key)
	if val is bool:
		return val
	if val is StoryFlowVariant:
		return val.get_bool(fallback)
	return fallback


## Get an integer value from node data, with fallback.
func _get_data_int(data: Dictionary, key: String, fallback: int = 0) -> int:
	var val = data.get(key)
	if val is int:
		return val
	if val is float:
		return int(val)
	if val is StoryFlowVariant:
		return val.get_int(fallback)
	return fallback


## Get a float value from node data, with fallback.
func _get_data_float(data: Dictionary, key: String, fallback: float = 0.0) -> float:
	var val = data.get(key)
	if val is float:
		return val
	if val is int:
		return float(val)
	if val is StoryFlowVariant:
		return val.get_float(fallback)
	return fallback


## Get a string value from node data, with fallback.
func _get_data_string(data: Dictionary, key: String, fallback: String = "") -> String:
	var val = data.get(key)
	if val is String:
		return val
	if val is StoryFlowVariant:
		return val.get_string(fallback)
	return fallback


## Resolves a string key through the localized strings dictionary.
## The JSON export stores all string-type values as keys into the strings table.
## Returns the resolved text, or the raw value if the key is not found.
func _resolve_string_key(value: String) -> String:
	if value.is_empty():
		return value
	# Try script-local strings first
	if _context and _context.current_script:
		var result := _context.current_script.get_localized_string(value, _language_code)
		if result != value:
			return result
	# Try global strings (includes character strings)
	var full_key := _language_code + "." + value
	if _global_strings.has(full_key):
		return _global_strings[full_key]
	return value


## Get a localized string from node data. The data value is used as a string
## table key, resolved through script-local then global strings.
func _get_localized_data_string(data: Dictionary, key: String) -> String:
	var val: String = _get_data_string(data, key)
	if val.is_empty():
		return ""
	return _resolve_string_key(val)
