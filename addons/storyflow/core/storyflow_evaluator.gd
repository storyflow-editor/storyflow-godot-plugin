class_name StoryFlowEvaluator
extends RefCounted

# Preloaded by path so parsing never depends on the global class name cache,
# which can be stale or mid-rewrite when the game launches (godotengine/godot#75388).
const StoryFlowCharacter = preload("res://addons/storyflow/core/storyflow_character.gd")
const StoryFlowExecutionContext = preload("res://addons/storyflow/core/storyflow_execution_context.gd")
const StoryFlowHandles = preload("res://addons/storyflow/core/storyflow_handles.gd")
const StoryFlowTypes = preload("res://addons/storyflow/core/storyflow_types.gd")
const StoryFlowVariant = preload("res://addons/storyflow/core/storyflow_variant.gd")

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

	var node := _context.current_script.get_node(node_id)
	if node.is_empty():
		_context.evaluation_depth -= 1
		return false

	var node_type: StoryFlowTypes.NodeType = node.get("type", StoryFlowTypes.NodeType.UNKNOWN)
	var data: Dictionary = node.get("data", {})

	# Map reads are never memoized: maps resolve to LIVE variable storage and
	# in-place mutations (setMapValue/removeMapKey/clearMap) must be observable
	# on the next read. The HTML runtime recomputes map reads inline the same way.
	var is_map_read := node_type == StoryFlowTypes.NodeType.GET_MAP_VALUE \
		or node_type == StoryFlowTypes.NodeType.HAS_MAP_KEY

	# Check cache first (map reads excluded — see is_map_read above)
	var node_state := _context.get_node_state(node_id)
	if not is_map_read and node_state.cached_output != null:
		var cached: StoryFlowVariant = node_state.cached_output
		if cached.type == StoryFlowTypes.VariableType.BOOLEAN:
			_context.evaluation_depth -= 1
			return cached.get_bool()

	if node_type == StoryFlowTypes.NodeType.UNKNOWN:
		_warn_unknown_evaluator_source(node)

	match node_type:
		StoryFlowTypes.NodeType.GET_BOOL, \
		StoryFlowTypes.NodeType.SET_BOOL:
			var variable := _find_variable(data)
			if not variable.is_empty():
				var value = variable.get("value")
				if value is StoryFlowVariant:
					result = value.get_bool()
			# HTML parity: the evaluator's get/set arm emits VAR GET on every
			# data pull (runtime-evaluators.js), before the EVAL line below —
			# never when the node sits in the exec chain (see _handle_get_bool).
			_sf_trace('VAR GET "%s" global=%s value=%s' % [variable.get("name", data.get("variable", "")), str(data.get("isGlobal", false)).to_lower(), str(result).to_lower()])

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

		# Map op arms branch on the node's OWN data keyType/valueType strings —
		# a NEW pattern for this evaluator: catalog map ops carry K/V in node
		# data, unlike array ops which encode the element type in the node type
		# itself. (Pattern note shared by all map arms across the evaluators.)
		StoryFlowTypes.NodeType.GET_MAP_VALUE:
			# getMapValue exposes two outputs sharing one node:
			#   "source-{id}-{valueType}-value" and "source-{id}-boolean-isValid".
			# Discriminate by source handle suffix (precedent: runScript "-out-").
			var computed := _compute_get_map_value(node)
			if source_handle.ends_with("-isValid"):
				# IsValid is always boolean, regardless of the node's valueType
				result = bool(computed["found"])
			elif str(data.get("valueType", "")) == "boolean":
				var found_value = computed["value"]
				if found_value is StoryFlowVariant:
					result = found_value.get_bool(false)

		StoryFlowTypes.NodeType.HAS_MAP_KEY:
			# Key FIRST, then resolve the map and consume it immediately
			# (mirrors the Unreal port's input-order rule).
			var key = evaluate_map_op_key_input(node, "2")
			var map_result := resolve_map_input(node, "1")
			var map = map_result.get("map")
			if map is Dictionary:
				result = map.has(key)

		# forEachMap Key/Value — two outputs share one node:
		#   "source-{id}-{keyType}-key" and "source-{id}-{valueType}-value".
		# Reads come from the iteration SNAPSHOT (loop_key/loop_value), not the
		# live map, so this is NOT a map read for the is_map_read bypass: within
		# an iteration the value is constant, and the per-iteration cache clear
		# drops it before the next entry — exactly the array loop precedent.
		# keyType can't be "boolean" per spec — the key branch is unreachable,
		# included for symmetry with the HTML evaluators.
		StoryFlowTypes.NodeType.FOR_EACH_MAP:
			var loop_state := _context.get_node_state(node_id)
			if source_handle.ends_with("-key") and str(data.get("keyType", "")) == "boolean":
				if loop_state.loop_key is bool:
					result = loop_state.loop_key
			elif source_handle.ends_with("-value") and str(data.get("valueType", "")) == "boolean":
				if loop_state.loop_value is StoryFlowVariant:
					result = loop_state.loop_value.get_bool(false)

		StoryFlowTypes.NodeType.RUN_SCRIPT:
			result = _evaluate_run_script_output_bool(node_id, source_handle, data)

		StoryFlowTypes.NodeType.GET_CHARACTER_VAR, \
		StoryFlowTypes.NodeType.SET_CHARACTER_VAR:
			var char_result := _evaluate_character_variable(data, node_id)
			if char_result is StoryFlowVariant:
				result = char_result.get_bool()

		StoryFlowTypes.NodeType.FOR_EACH_BOOL_LOOP:
			var ns := _context.get_node_state(node_id)
			if ns.cached_output != null:
				result = ns.cached_output.get_bool()

		_:
			result = false

	# Cache result (map reads excluded — see is_map_read above)
	if not is_map_read:
		node_state.cached_output = StoryFlowVariant.from_bool(result)

	# Trace the wire-name (type_string), not the SCREAMING enum key — the
	# cross-runtime fixture pins e.g. "hasMapKey". (Same in every evaluator.)
	_sf_trace("EVAL %s %s result=%s" % [node_id, node.get("type_string", ""), str(result).to_lower()])

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

	if node_type == StoryFlowTypes.NodeType.UNKNOWN:
		_warn_unknown_evaluator_source(node)

	match node_type:
		StoryFlowTypes.NodeType.GET_INT, \
		StoryFlowTypes.NodeType.SET_INT:
			var variable := _find_variable(data)
			if not variable.is_empty():
				var value = variable.get("value")
				if value is StoryFlowVariant:
					result = value.get_int()
			# HTML parity: VAR GET on every data pull, before the EVAL line
			# (see the boolean evaluator's arm)
			_sf_trace('VAR GET "%s" global=%s value=%s' % [variable.get("name", data.get("variable", "")), str(data.get("isGlobal", false)).to_lower(), str(result)])

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

		StoryFlowTypes.NodeType.MODULO:
			var input1 := evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER1, _get_data_int(data, "value1", 0))
			var input2 := evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER2, _get_data_int(data, "value2", 0))
			result = (input1 % input2) if input2 != 0 else 0

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

		# Map ops branch on the node's data keyType/valueType (see the boolean
		# evaluator's map arms for the pattern note)
		StoryFlowTypes.NodeType.MAP_SIZE:
			# Unresolved/missing-K-V map input falls through to 0 (HTML parity)
			var map_result := resolve_map_input(node, "1")
			var map = map_result.get("map")
			if map is Dictionary:
				result = map.size()

		StoryFlowTypes.NodeType.GET_MAP_VALUE:
			if str(data.get("valueType", "")) == "integer":
				var computed := _compute_get_map_value(node)
				var found_value = computed["value"]
				if found_value is StoryFlowVariant:
					result = found_value.get_int(0)

		# forEachMap Key/Value (integer) — discriminate by source handle suffix
		# ("-key"/"-value"); reads come from the iteration snapshot, see the
		# boolean evaluator's FOR_EACH_MAP arm for the full pattern note
		StoryFlowTypes.NodeType.FOR_EACH_MAP:
			var map_loop_state := _context.get_node_state(node_id)
			if source_handle.ends_with("-key") and str(data.get("keyType", "")) == "integer":
				if map_loop_state.loop_key is int:
					result = map_loop_state.loop_key
			elif source_handle.ends_with("-value") and str(data.get("valueType", "")) == "integer":
				if map_loop_state.loop_value is StoryFlowVariant:
					result = map_loop_state.loop_value.get_int(0)

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

		StoryFlowTypes.NodeType.GET_CHARACTER_VAR, \
		StoryFlowTypes.NodeType.SET_CHARACTER_VAR:
			var char_result := _evaluate_character_variable(data, node_id)
			if char_result is StoryFlowVariant:
				result = char_result.get_int()

		_:
			result = 0

	_sf_trace("EVAL %s %s result=%s" % [node_id, node.get("type_string", ""), str(result)])

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

	if node_type == StoryFlowTypes.NodeType.UNKNOWN:
		_warn_unknown_evaluator_source(node)

	match node_type:
		StoryFlowTypes.NodeType.GET_FLOAT, \
		StoryFlowTypes.NodeType.SET_FLOAT:
			var variable := _find_variable(data)
			if not variable.is_empty():
				var value = variable.get("value")
				if value is StoryFlowVariant:
					result = value.get_float()
			# HTML parity: VAR GET on every data pull (see the boolean evaluator's arm)
			_sf_trace('VAR GET "%s" global=%s value=%s' % [variable.get("name", data.get("variable", "")), str(data.get("isGlobal", false)).to_lower(), str(result)])

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

		StoryFlowTypes.NodeType.MODULO_FLOAT:
			var input1 := evaluate_float_input(node_id, StoryFlowHandles.IN_FLOAT1, _get_data_float(data, "value1", 0.0))
			var input2 := evaluate_float_input(node_id, StoryFlowHandles.IN_FLOAT2, _get_data_float(data, "value2", 0.0))
			result = fmod(input1, input2) if not is_zero_approx(input2) else 0.0

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

		# Map op branches on the node's data valueType (see the boolean
		# evaluator's map arms for the pattern note)
		StoryFlowTypes.NodeType.GET_MAP_VALUE:
			if str(data.get("valueType", "")) == "float":
				var computed := _compute_get_map_value(node)
				var found_value = computed["value"]
				if found_value is StoryFlowVariant:
					result = found_value.get_float(0.0)

		# forEachMap Value (float) — discriminate by source handle suffix;
		# reads come from the iteration snapshot, see the boolean evaluator's
		# FOR_EACH_MAP arm for the full pattern note. keyType can't be "float"
		# per spec, so there is no key branch here.
		StoryFlowTypes.NodeType.FOR_EACH_MAP:
			var map_loop_state := _context.get_node_state(node_id)
			if source_handle.ends_with("-value") and str(data.get("valueType", "")) == "float":
				if map_loop_state.loop_value is StoryFlowVariant:
					result = map_loop_state.loop_value.get_float(0.0)

		StoryFlowTypes.NodeType.FOR_EACH_FLOAT_LOOP:
			var loop_state := _context.get_node_state(node_id)
			if loop_state.cached_output != null:
				result = loop_state.cached_output.get_float()

		StoryFlowTypes.NodeType.RUN_SCRIPT:
			result = _evaluate_run_script_output_float(node_id, source_handle, data)

		StoryFlowTypes.NodeType.GET_CHARACTER_VAR, \
		StoryFlowTypes.NodeType.SET_CHARACTER_VAR:
			var char_result := _evaluate_character_variable(data, node_id)
			if char_result is StoryFlowVariant:
				result = char_result.get_float()

		_:
			result = 0.0

	_sf_trace("EVAL %s %s result=%s" % [node_id, node.get("type_string", ""), str(result)])

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

	if node_type == StoryFlowTypes.NodeType.UNKNOWN:
		_warn_unknown_evaluator_source(node)

	match node_type:
		StoryFlowTypes.NodeType.GET_STRING, \
		StoryFlowTypes.NodeType.SET_STRING:
			var variable := _find_variable(data)
			if not variable.is_empty():
				var value = variable.get("value")
				if value is StoryFlowVariant:
					result = value.get_string()
			# HTML parity: VAR GET on every data pull (see the boolean
			# evaluator's arm). The value traces RAW (pre-_resolve_string_key),
			# matching HTML which traces the stored variable value.
			_sf_trace('VAR GET "%s" global=%s value=%s' % [variable.get("name", data.get("variable", "")), str(data.get("isGlobal", false)).to_lower(), result])

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

		StoryFlowTypes.NodeType.GET_ENUM, \
		StoryFlowTypes.NodeType.SET_ENUM:
			var variable := _find_variable(data)
			if not variable.is_empty():
				var value = variable.get("value")
				if value is StoryFlowVariant:
					result = value.get_string()
			# HTML parity: VAR GET on every data pull (see the boolean evaluator's arm)
			_sf_trace('VAR GET "%s" global=%s value=%s' % [variable.get("name", data.get("variable", "")), str(data.get("isGlobal", false)).to_lower(), result])

		StoryFlowTypes.NodeType.ENUM_TO_STRING:
			var input := evaluate_enum_input(node_id, StoryFlowHandles.IN_ENUM, _get_data_string(data, "value"))
			result = input

		StoryFlowTypes.NodeType.INT_TO_ENUM:
			result = _evaluate_int_to_enum(node_id, data)

		StoryFlowTypes.NodeType.STRING_TO_ENUM:
			result = _evaluate_string_to_enum(node_id, data)

		StoryFlowTypes.NodeType.GET_IMAGE, \
		StoryFlowTypes.NodeType.SET_IMAGE:
			var variable := _find_variable(data)
			if not variable.is_empty():
				var value = variable.get("value")
				if value is StoryFlowVariant:
					result = value.get_string()
			# HTML parity: VAR GET on every data pull (see the boolean evaluator's arm)
			_sf_trace('VAR GET "%s" global=%s value=%s' % [variable.get("name", data.get("variable", "")), str(data.get("isGlobal", false)).to_lower(), result])

		StoryFlowTypes.NodeType.SET_BACKGROUND_IMAGE:
			# As an image source the node exposes the image it sets: connected
			# image input first, then the dropdown value (matches HTML runtime).
			result = evaluate_string_input(node_id, StoryFlowHandles.IN_IMAGE_INPUT, _get_data_string(data, "value"))

		StoryFlowTypes.NodeType.GET_AUDIO, \
		StoryFlowTypes.NodeType.SET_AUDIO:
			var variable := _find_variable(data)
			if not variable.is_empty():
				var value = variable.get("value")
				if value is StoryFlowVariant:
					result = value.get_string()
			# HTML parity: VAR GET on every data pull (see the boolean evaluator's arm)
			_sf_trace('VAR GET "%s" global=%s value=%s' % [variable.get("name", data.get("variable", "")), str(data.get("isGlobal", false)).to_lower(), result])

		StoryFlowTypes.NodeType.GET_CHARACTER, \
		StoryFlowTypes.NodeType.SET_CHARACTER:
			var variable := _find_variable(data)
			if not variable.is_empty():
				var value = variable.get("value")
				if value is StoryFlowVariant:
					result = value.get_string()
			# HTML parity: VAR GET on every data pull (see the boolean evaluator's arm)
			_sf_trace('VAR GET "%s" global=%s value=%s' % [variable.get("name", data.get("variable", "")), str(data.get("isGlobal", false)).to_lower(), result])

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

		# Map op branches on the node's data valueType (see the boolean
		# evaluator's map arms for the pattern note). All string-family value
		# types (string/enum/image/character/audio) read through this evaluator
		# — enums included, mirroring scalar enum reads (evaluate_enum_input
		# delegates here). String results flow through _resolve_string_key below,
		# matching how scalar string variables resolve their stored table keys.
		StoryFlowTypes.NodeType.GET_MAP_VALUE:
			var map_value_type := str(data.get("valueType", ""))
			if map_value_type in ["string", "enum", "image", "character", "audio"]:
				var computed := _compute_get_map_value(node)
				var found_value = computed["value"]
				if found_value is StoryFlowVariant:
					result = found_value.get_string()

		# forEachMap Key/Value (string-family) — discriminate by source handle
		# suffix; reads come from the iteration snapshot, see the boolean
		# evaluator's FOR_EACH_MAP arm for the full pattern note. Keys cover
		# string/enum, values the full string/enum/image/character/audio family.
		StoryFlowTypes.NodeType.FOR_EACH_MAP:
			var map_loop_state := _context.get_node_state(node_id)
			var map_key_type := str(data.get("keyType", ""))
			var map_value_type := str(data.get("valueType", ""))
			if source_handle.ends_with("-key") and (map_key_type == "string" or map_key_type == "enum"):
				if map_loop_state.loop_key != null:
					result = str(map_loop_state.loop_key)
			elif source_handle.ends_with("-value") and map_value_type in ["string", "enum", "image", "character", "audio"]:
				if map_loop_state.loop_value is StoryFlowVariant:
					result = map_loop_state.loop_value.get_string()

		StoryFlowTypes.NodeType.FOR_EACH_STRING_LOOP, \
		StoryFlowTypes.NodeType.FOR_EACH_IMAGE_LOOP, \
		StoryFlowTypes.NodeType.FOR_EACH_CHARACTER_LOOP, \
		StoryFlowTypes.NodeType.FOR_EACH_AUDIO_LOOP:
			var loop_state := _context.get_node_state(node_id)
			if loop_state.cached_output != null:
				result = loop_state.cached_output.get_string()

		StoryFlowTypes.NodeType.RUN_SCRIPT:
			result = _evaluate_run_script_output_string(node_id, source_handle, data)

		StoryFlowTypes.NodeType.GET_CHARACTER_VAR, \
		StoryFlowTypes.NodeType.SET_CHARACTER_VAR:
			var char_result := _evaluate_character_variable(data, node_id)
			if char_result is StoryFlowVariant:
				result = char_result.get_string()

		_:
			result = ""

	var resolved_result := _resolve_string_key(result)
	_sf_trace("EVAL %s %s result=%s" % [node_id, node.get("type_string", ""), resolved_result])

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

	if node_type == StoryFlowTypes.NodeType.UNKNOWN:
		_warn_unknown_evaluator_source(node)

	match node_type:
		StoryFlowTypes.NodeType.GET_ENUM, \
		StoryFlowTypes.NodeType.SET_ENUM:
			var variable := _find_variable(data)
			if not variable.is_empty():
				var value = variable.get("value")
				if value is StoryFlowVariant:
					result = value.get_string()

		StoryFlowTypes.NodeType.ENUM_TO_STRING:
			result = evaluate_enum_input(node_id, StoryFlowHandles.IN_ENUM, _get_data_string(data, "value"))

		StoryFlowTypes.NodeType.INT_TO_ENUM:
			result = _evaluate_int_to_enum(node_id, data)

		StoryFlowTypes.NodeType.STRING_TO_ENUM:
			result = _evaluate_string_to_enum(node_id, data)

		StoryFlowTypes.NodeType.GET_CHARACTER_VAR, \
		StoryFlowTypes.NodeType.SET_CHARACTER_VAR:
			var char_result := _evaluate_character_variable(data, node_id)
			if char_result is StoryFlowVariant:
				result = char_result.get_string()

		StoryFlowTypes.NodeType.RUN_SCRIPT:
			result = _evaluate_run_script_output_string(node_id, source_handle, data)

		_:
			result = ""

	_sf_trace("EVAL %s %s result=%s" % [node_id, node.get("type_string", ""), result])

	_context.evaluation_depth -= 1
	return result


func _evaluate_int_to_enum(node_id: String, data: Dictionary) -> String:
	var int_val := evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER, _get_data_int(data, "value", 0))
	var enum_values := _resolve_conversion_enum_values(node_id, data)
	if enum_values.is_empty():
		return ""
	var clamped_index := clampi(int_val, 0, enum_values.size() - 1)
	return str(enum_values[clamped_index])


func _evaluate_string_to_enum(node_id: String, data: Dictionary) -> String:
	var str_val := evaluate_string_input(node_id, StoryFlowHandles.IN_STRING, _get_data_string(data, "value"))
	var enum_values := _resolve_conversion_enum_values(node_id, data)
	if enum_values.has(str_val):
		return str_val
	if enum_values.size() > 0:
		return str(enum_values[0])
	return ""


## Find the enum value list an intToEnum/stringToEnum node converts into.
## The node's own data wins when present, but editor exports store no data on
## conversion nodes at all - mirror the HTML runtime and resolve the values
## from the node the enum output feeds: the target's variable for
## getEnum/setEnum, otherwise the target node's own enumValues.
func _resolve_conversion_enum_values(node_id: String, data: Dictionary) -> Array:
	var own_values: Array = data.get("enumValues", [])
	if own_values.size() > 0:
		return own_values

	if not _context or not _context.current_script:
		return []

	var enum_out_prefix := StoryFlowHandles.source(node_id, StoryFlowHandles.OUT_ENUM)
	for conn in _context.current_script.find_connections_from_node(node_id):
		var source_handle: String = conn.get("source_handle", "")
		if not source_handle.begins_with(enum_out_prefix):
			continue
		var target_node := _context.current_script.get_node(conn.get("target", ""))
		if target_node.is_empty():
			continue
		var target_data: Dictionary = target_node.get("data", {})
		var target_type: StoryFlowTypes.NodeType = target_node.get("type", StoryFlowTypes.NodeType.UNKNOWN)
		if target_type == StoryFlowTypes.NodeType.GET_ENUM or target_type == StoryFlowTypes.NodeType.SET_ENUM:
			var variable := _find_variable(target_data)
			var variable_values: Array = variable.get("enum_values", [])
			if variable_values.size() > 0:
				return variable_values
		var target_values: Array = target_data.get("enumValues", [])
		if target_values.size() > 0:
			return target_values

	return []


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

	if source_type == StoryFlowTypes.NodeType.UNKNOWN:
		_warn_unknown_evaluator_source(source_node)

	# Handle getCharacterVar/setCharacterVar nodes that can return arrays
	if source_type == StoryFlowTypes.NodeType.GET_CHARACTER_VAR or source_type == StoryFlowTypes.NodeType.SET_CHARACTER_VAR:
		var variant := _evaluate_character_variable(source_data, source_id)
		return variant.get_array()

	# mapKeys / mapValues: pure ops that project a map into an array. Recomputed
	# fresh on every pull — maps mutate in place, so a cached output would go
	# stale (the HTML runtime recomputes these inline too). Keys are raw int/
	# String storage keys wrapped into typed variants per the node's keyType;
	# values are already typed StoryFlowVariant entries and pass straight into
	# the result regardless of which typed wrapper the consumer used.
	if source_type == StoryFlowTypes.NodeType.MAP_KEYS or source_type == StoryFlowTypes.NodeType.MAP_VALUES:
		var projected: Array = []
		var map_result := resolve_map_input(source_node, "1")
		var map = map_result.get("map")
		if map is Dictionary:
			var map_key_type := str(source_data.get("keyType", ""))
			for key in map:
				if source_type == StoryFlowTypes.NodeType.MAP_KEYS:
					if map_key_type == "integer":
						projected.append(StoryFlowVariant.from_int(int(key)))
					elif map_key_type == "enum":
						projected.append(StoryFlowVariant.from_enum(str(key)))
					else:
						projected.append(StoryFlowVariant.from_string(str(key)))
				else:
					var entry = map[key]
					projected.append(entry if entry is StoryFlowVariant else StoryFlowVariant.new())
		return projected

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
# Map Evaluation
# =============================================================================

## Source kinds reported by [method resolve_map_input] ("kind" field).
## CHARACTER_VAR and RUN_SCRIPT sources are READ-ONLY per the cross-runtime
## contract: the HTML runtime hands mutators a throwaway/converted Map for both
## (mutations never persist) and setMap SNAPSHOTS rather than aliases.
## SCRIPT_VAR vs GLOBAL_VAR carries the terminal node's scope flag for
## variable-change notifications.
const MAP_SOURCE_UNRESOLVED := "unresolved"
const MAP_SOURCE_SCRIPT_VAR := "script_variable"
const MAP_SOURCE_GLOBAL_VAR := "global_variable"
const MAP_SOURCE_CHARACTER_VAR := "character_variable"
const MAP_SOURCE_RUN_SCRIPT := "run_script_output"


## Resolve the map wired into one of [param node]'s map inputs.
##
## Returns a result Dictionary:
##   "map":       the LIVE entry Dictionary (coerced key -> StoryFlowVariant),
##                or null when unresolved. Maps alias: mutators write through
##                this Dictionary and every later read must observe the change,
##                so this is never a copy. Callers that mutate or alias MUST
##                check "kind" first (read-only sources above); pure reads may
##                ignore it.
##   "kind":      one of the MAP_SOURCE_* strings above.
##   "is_global": the terminal getMap/setMap node's scope flag (only meaningful
##                for SCRIPT_VAR/GLOBAL_VAR kinds; false otherwise).
##   "variable":  the origin variable record Dictionary, for variable-change
##                notifications (script/global kinds only; empty otherwise).
##
## The full target handle is "target-{nodeId}-map-{keyType}-{valueType}-{optionId}";
## K/V come from the node's own data keyType/valueType (catalog map op nodes
## carry them in node data), the caller passes only the option id ("1" pure
## reads, "2" setMap + mutators, "map" forEachMap, "input" setCharacterVar).
##
## Resolution walks upstream through chained mutators (setMapValue/removeMapKey/
## clearMap) to the origin variable: a mutator mutates the origin's live storage
## in place, so its map output IS its own map input ("2") — follow that edge
## until a terminal variable-bound node (hop-bounded against cyclic graphs;
## the HTML recursion has no guard, we fail to unresolved).
func resolve_map_input(node: Dictionary, option_id: String) -> Dictionary:
	if node.is_empty():
		return {"map": null, "kind": MAP_SOURCE_UNRESOLVED, "is_global": false, "variable": {}}

	var data: Dictionary = node.get("data", {})
	var key_type: String = str(data.get("keyType", ""))
	var value_type: String = str(data.get("valueType", ""))
	# Map handles bake the key/value types into the handle ID — without them
	# the input handle cannot be built, so resolution fails to defaults.
	if key_type.is_empty() or value_type.is_empty():
		_warn_missing_map_types(node)
		return {"map": null, "kind": MAP_SOURCE_UNRESOLVED, "is_global": false, "variable": {}}

	return resolve_map_input_by_handle(node, StoryFlowHandles.in_map(key_type, value_type, option_id))


## [method resolve_map_input] with an EXPLICIT target handle suffix instead of
## one built from the node's keyType/valueType data. Needed for runScript map
## parameters, whose handles ("map-param-{id}") carry no K/V types — the
## editor's scriptInterface does not bake them in (mirrors the Unreal port's
## ResolveMapInputVariableByHandle). Same result contract as resolve_map_input.
func resolve_map_input_by_handle(node: Dictionary, handle_suffix: String) -> Dictionary:
	var unresolved := {"map": null, "kind": MAP_SOURCE_UNRESOLVED, "is_global": false, "variable": {}}
	if not _context or not _context.current_script or node.is_empty():
		return unresolved

	var edge := _context.current_script.find_input_edge(node.get("id", ""), handle_suffix)
	if edge.is_empty():
		return unresolved

	var source_node := _context.current_script.get_node(edge.get("source", ""))

	# Walk upstream through chained mutators to the origin variable.
	var hops := 0
	while not source_node.is_empty() and source_node.get("type", -1) in [
		StoryFlowTypes.NodeType.SET_MAP_VALUE,
		StoryFlowTypes.NodeType.REMOVE_MAP_KEY,
		StoryFlowTypes.NodeType.CLEAR_MAP,
	]:
		hops += 1
		if hops > StoryFlowExecutionContext.MAX_EVALUATION_DEPTH:
			push_warning("StoryFlow: Map mutator chain too deep at node %s - possible cycle" % source_node.get("id", ""))
			return unresolved
		var mutator_data: Dictionary = source_node.get("data", {})
		var mutator_key_type: String = str(mutator_data.get("keyType", ""))
		var mutator_value_type: String = str(mutator_data.get("valueType", ""))
		if mutator_key_type.is_empty() or mutator_value_type.is_empty():
			_warn_missing_map_types(source_node)
			return unresolved
		var upstream_edge := _context.current_script.find_input_edge(source_node.get("id", ""), StoryFlowHandles.in_map(mutator_key_type, mutator_value_type, "2"))
		if upstream_edge.is_empty():
			return unresolved
		# Keep the terminal edge — its source_handle carries the runScript
		# "-out-" UUID the RUN_SCRIPT arm below parses.
		edge = upstream_edge
		source_node = _context.current_script.get_node(upstream_edge.get("source", ""))

	if source_node.is_empty():
		return unresolved

	var source_type: StoryFlowTypes.NodeType = source_node.get("type", StoryFlowTypes.NodeType.UNKNOWN)
	var source_data: Dictionary = source_node.get("data", {})

	if source_type == StoryFlowTypes.NodeType.UNKNOWN:
		_warn_unknown_evaluator_source(source_node)

	match source_type:
		StoryFlowTypes.NodeType.GET_MAP, \
		StoryFlowTypes.NodeType.SET_MAP:
			# Resolve the bound variable and return its LIVE map Dictionary.
			var variable := _find_variable(source_data)
			if variable.is_empty() or variable.get("type", -1) != StoryFlowTypes.VariableType.MAP:
				return unresolved
			var value = variable.get("value")
			if not (value is StoryFlowVariant):
				return unresolved
			if not value.is_map():
				# Variable without established map storage — type it so the
				# returned Dictionary is the variable's live storage. set_map
				# reassignment is safe here: a never-map variant cannot be
				# aliased yet.
				value.set_map({})
			var is_global: bool = source_data.get("isGlobal", false)
			return {
				"map": value.get_map(),
				"kind": MAP_SOURCE_GLOBAL_VAR if is_global else MAP_SOURCE_SCRIPT_VAR,
				"is_global": is_global,
				"variable": variable,
			}

		StoryFlowTypes.NodeType.GET_CHARACTER_VAR, \
		StoryFlowTypes.NodeType.SET_CHARACTER_VAR:
			# Map-typed character variables resolve to the character's LIVE
			# runtime variable — fine for pure reads, which are observably
			# identical on live vs copy and stay zero-copy. But charvar-sourced
			# chains are READ-ONLY (kind CHARACTER_VAR): mutators must no-op and
			# setMap must snapshot. Wired character input wins over the inline
			# dropdown path, matching the scalar charvar evaluators.
			if str(source_data.get("variableType", "")) != "map":
				return unresolved
			var character_path: String = source_data.get("characterPath", "")
			var char_edge := _context.current_script.find_input_edge(source_node.get("id", ""), StoryFlowHandles.IN_CHARACTER_INPUT)
			if not char_edge.is_empty():
				var char_source := _context.current_script.get_node(char_edge.get("source", ""))
				if not char_source.is_empty():
					character_path = evaluate_string_from_node(char_source.get("id", ""), char_edge.get("source_handle", ""))
			if character_path.is_empty():
				return unresolved
			var normalized_path := StoryFlowCharacter.normalize_path(character_path)
			if not _characters.has(normalized_path):
				return unresolved
			var character: StoryFlowCharacter = _characters[normalized_path]
			var variable_name: String = source_data.get("variableName", "")
			if variable_name.is_empty() or not character.variables.has(variable_name):
				return unresolved
			var char_variable: Dictionary = character.variables[variable_name]
			if char_variable.get("type", -1) != StoryFlowTypes.VariableType.MAP:
				return unresolved
			var char_value = char_variable.get("value")
			if not (char_value is StoryFlowVariant):
				return unresolved
			if not char_value.is_map():
				char_value.set_map({})
			return {
				"map": char_value.get_map(),
				"kind": MAP_SOURCE_CHARACTER_VAR,
				"is_global": false,
				"variable": {},
			}

		StoryFlowTypes.NodeType.RUN_SCRIPT:
			# Map-typed runScript outputs. The HTML runtime's evaluateMapFromNode
			# reads _outputValues[uuid] and converts the serialized entry array
			# to a FRESH Map at the read site — observably a DETACHED snapshot
			# crossing the call boundary. _handle_end stores map outputs as
			# detached deep copies in the node's output_values (keyed by the
			# scriptInterface output id, with variable-name fallback — the same
			# store the scalar _evaluate_run_script_output_* helpers read), so
			# this arm resolves against that and flags the source READ-ONLY:
			# mutating a dead invocation's output is meaningless (HTML mutations
			# land on the converted fresh Map and are lost). Missing outputs are
			# unresolved — reads return defaults and setMap wipes to a fresh
			# empty map, matching HTML's "missing _outputValues returns an
			# empty Map" pin.
			var rs_state := _context.get_node_state(source_node.get("id", ""))
			if not rs_state.has_output_values:
				return unresolved
			var out_var_id := _extract_run_script_output_var_id(edge.get("source_handle", ""))
			if out_var_id.is_empty() or not rs_state.output_values.has(out_var_id):
				return unresolved
			var out_val = rs_state.output_values[out_var_id]
			if not (out_val is StoryFlowVariant) or not out_val.is_map():
				return unresolved
			return {
				"map": out_val.get_map(),
				"kind": MAP_SOURCE_RUN_SCRIPT,
				"is_global": false,
				"variable": {},
			}

	# Any other terminal node type cannot bind a map variable.
	return unresolved


## Resolve a map op's key: wired key input first ("{keyType}-{optionId}"), else
## the inline node-data "key" fallback (coerced off the declared keyType at
## import). Returns the RAW storage key — int for integer keyType, String
## otherwise — matching the map Dictionary's key coercion, so the result can be
## used directly for has()/[]/erase().
func evaluate_map_op_key_input(node: Dictionary, option_id: String) -> Variant:
	var data: Dictionary = node.get("data", {})
	var key_type: String = str(data.get("keyType", ""))
	var node_id: String = node.get("id", "")
	var handle_suffix := "%s-%s" % [key_type, option_id]
	var inline_key = data.get("key", null)
	if key_type == "integer":
		var fallback_int := 0
		if inline_key is int:
			fallback_int = inline_key
		elif inline_key is float:
			fallback_int = int(inline_key)
		return evaluate_integer_input(node_id, handle_suffix, fallback_int)
	# string and enum keys both flow through the string evaluator; inline keys
	# are raw values — never strings-table keys — and an unwired input returns
	# the fallback verbatim.
	var fallback_str := ""
	if inline_key is String:
		fallback_str = inline_key
	return evaluate_string_input(node_id, handle_suffix, fallback_str)


## Resolve a map op's value: wired value input first ("{valueType}-{optionId}"),
## else the inline node-data "value" fallback (re-typed off the declared
## valueType at import). The returned variant is typed per the node's valueType;
## image/character/audio values flow through the string evaluator like the
## scalar Set* handlers. String values keep the strings-table key verbatim —
## resolution happens at read time, exactly like scalar variables.
func evaluate_map_op_value_input(node: Dictionary, option_id: String) -> StoryFlowVariant:
	var data: Dictionary = node.get("data", {})
	var value_type: String = str(data.get("valueType", ""))
	var node_id: String = node.get("id", "")
	var handle_suffix := "%s-%s" % [value_type, option_id]
	match value_type:
		"boolean":
			return StoryFlowVariant.from_bool(evaluate_boolean_input(node_id, handle_suffix, _get_data_bool(data, "value", false)))
		"integer":
			return StoryFlowVariant.from_int(evaluate_integer_input(node_id, handle_suffix, _get_data_int(data, "value", 0)))
		"float":
			return StoryFlowVariant.from_float(evaluate_float_input(node_id, handle_suffix, _get_data_float(data, "value", 0.0)))
		"enum":
			return StoryFlowVariant.from_enum(evaluate_enum_input(node_id, handle_suffix, _get_data_string(data, "value")))
		_:
			# string, image, character, audio — string-keyed storage
			return StoryFlowVariant.from_string(evaluate_string_input(node_id, handle_suffix, _get_data_string(data, "value")))


## Compute a getMapValue read. The key (input "2" / inline fallback) is
## resolved FIRST, then the map (input "1") is resolved and consumed
## immediately — the HTML runtime actually resolves map-first, but this
## key-first order mirrors the Unreal port's pointer-lifetime rule (no eval
## may run between resolving the live map and using it) and is observably
## equivalent: key and map evaluations don't affect each other. Returns
## { "found": bool, "value": StoryFlowVariant or null } — miss/unresolved
## leaves value null and found=false; the typed evaluator arms apply the
## valueType default.
func _compute_get_map_value(node: Dictionary) -> Dictionary:
	var key = evaluate_map_op_key_input(node, "2")
	var map_result := resolve_map_input(node, "1")
	var map = map_result.get("map")
	if map is Dictionary and map.has(key):
		return {"found": true, "value": map[key]}
	return {"found": false, "value": null}


## Warn (once per node, per execution context) when a map op node is missing
## the keyType/valueType data its input handles are built from. Dedups through
## warned_unknown_nodes with a distinct key prefix.
func _warn_missing_map_types(node: Dictionary) -> void:
	if not _context:
		return
	var dedup_key: String = "map-types:" + str(node.get("id", ""))
	if _context.warned_unknown_nodes.has(dedup_key):
		return
	_context.warned_unknown_nodes[dedup_key] = true
	push_warning("StoryFlow: Map node %s is missing keyType/valueType data - map input unresolved" % node.get("id", ""))


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

		StoryFlowTypes.NodeType.GET_MAP_VALUE, \
		StoryFlowTypes.NodeType.HAS_MAP_KEY:
			# Map reads are never memoized (live map storage mutates in place),
			# so there is nothing to pre-cache — and the default arm's
			# empty-handle evaluation could not discriminate getMapValue's
			# "-isValid" output anyway. Clear any stale cache and let the real
			# read (with the correct source handle) evaluate fresh.
			node_state.cached_output = null

		StoryFlowTypes.NodeType.FOR_EACH_MAP:
			# forEachMap needs the real source handle to discriminate
			# "-key"/"-value" — the default arm's empty-handle evaluation would
			# cache false and poison the real read (the Unreal port's
			# poison-cache fix). No-op: the subsequent evaluate_boolean_from_node
			# (with the correct handle) evaluates fresh — the loop handler clears
			# the evaluation cache at the start of every iteration.
			pass

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
		# Whole numbers in editor JSON import as INTEGER variants (no type
		# hint on inline node values) — coerce like the raw-int branch above.
		if val.type == StoryFlowTypes.VariableType.INTEGER:
			return float(val.get_int())
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


# =============================================================================
# Unknown Node Warning (Private)
# =============================================================================

## Emit a forward-compat warning when an evaluator follows an input edge to a
## node whose type is UNKNOWN (i.e. the plugin does not recognize it). Dedups
## per-execution-context so each unknown source node warns at most once per
## dialogue run. Callers fall through to their existing default-return path;
## this helper does not change return semantics.
func _warn_unknown_evaluator_source(node: Dictionary) -> void:
	if not _context:
		return
	var id: String = node.get("id", "")
	if _context.warned_unknown_nodes.has(id):
		return
	_context.warned_unknown_nodes[id] = true
	push_warning("StoryFlow: Unsupported node type '%s' at node %s, returning default value" % [node.get("type_string", ""), id])
