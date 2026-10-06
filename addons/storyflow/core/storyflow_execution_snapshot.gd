extends RefCounted

## Only explicitly owned runtime types may cross this bounded cloning boundary.
## Immutable scripts, Resources, Nodes and arbitrary host objects never enter history.
const Value = preload("res://addons/storyflow/core/storyflow_variant.gd")
const NodeState = preload("res://addons/storyflow/core/storyflow_node_runtime_state.gd")
const LoopFrame = preload("res://addons/storyflow/core/storyflow_loop_frame.gd")
const CallFrame = preload("res://addons/storyflow/core/storyflow_call_frame.gd")
const MAX_BYTES := 32 * 1024 * 1024
## Equal-shaped native containers expose only pairwise identity. Bound that work too.
const MAX_MEMO_COMPARISONS := 200000
const VALUE_FIELDS := ["type", "_bool_value", "_int_value", "_float_value", "_string_value", "string_key", "string_is_literal", "_array_storage", "_map_storage"]
const NODE_FIELDS := ["cached_output", "detached_map_output", "loop_index", "loop_array", "loop_initialized", "loop_keys", "loop_values", "loop_key", "loop_value", "loop_text_is_resolved", "output_values", "output_arrays", "output_types", "has_output_values"]
const CALL_FIELDS := ["script_path", "return_node_id", "saved_variables", "saved_flow_stack", "saved_loop_stack", "saved_node_runtime_states"]
var bytes: int = 0
var failure: String = ""
var _visited: int = 0
var _sources: Array = []
var _copies: Array = []
var _active: Array = []
var _objects: Dictionary = {}
var _buckets: Dictionary = {}
var memo_comparisons: int = 0

func copy(value: Variant, depth: int = 0) -> Variant:
	if not failure.is_empty():
		return null
	_visited += 1
	bytes += 16
	if bytes > MAX_BYTES or _visited > 1000000:
		failure = "budget"
		return null
	if depth > 128:
		failure = "unsupportedState"
		return null
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT:
			return value
		TYPE_FLOAT:
			if not is_finite(value):
				failure = "unsupportedState"
			return value
		TYPE_STRING_NAME:
			return copy(String(value), depth)
		TYPE_STRING:
			# UTF-32 is a conservative retained-payload estimate and requires no encoding copy.
			bytes += value.length() * 4
			if bytes > MAX_BYTES:
				failure = "budget"
			return value
		TYPE_ARRAY, TYPE_DICTIONARY:
			# Refuse obviously oversized containers before building even a partial copy.
			if value.size() > (MAX_BYTES - bytes) / 16:
				failure = "budget"
				return null
			var bucket_key := _container_bucket(value)
			var bucket: Array = _buckets.get(bucket_key, [])
			for i in bucket:
				memo_comparisons += 1
				if memo_comparisons > MAX_MEMO_COMPARISONS:
					failure = "budget"
					return null
				if is_same(value, _sources[i]):
					if _active[i]:
						failure = "unsupportedState"
					return _copies[i]
			var result = [] if value is Array else {}
			var index := _sources.size()
			_sources.append(value)
			_copies.append(result)
			_active.append(true)
			bucket.append(index)
			_buckets[bucket_key] = bucket
			for key in value:
				if not failure.is_empty():
					break
				if value is Array:
					result.append(copy(key, depth + 1))
				else:
					if typeof(key) not in [TYPE_STRING, TYPE_STRING_NAME, TYPE_INT]:
						failure = "unsupportedState"
						break
					result[copy(key, depth + 1)] = copy(value[key], depth + 1)
			_active[index] = false
			return result
		TYPE_OBJECT:
			if not is_instance_valid(value):
				failure = "unsupportedState"
				return null
			var id: int = value.get_instance_id()
			if _objects.has(id):
				if _objects[id] == null:
					failure = "unsupportedState"
				return _objects[id]
			var fields: Array
			var result: RefCounted
			if value is Value:
				if value.get_script() != Value or value.type < 0 or value.type > 10:
					failure = "unsupportedState"
					return null
				fields = VALUE_FIELDS
				result = Value.new()
			elif value is NodeState:
				if value.get_script() != NodeState:
					failure = "unsupportedState"
					return null
				fields = NODE_FIELDS
				result = NodeState.new()
			elif value is LoopFrame:
				if value.get_script() != LoopFrame:
					failure = "unsupportedState"
					return null
				fields = ["node_id", "type", "current_index"]
				result = LoopFrame.new()
			elif value is CallFrame:
				if value.get_script() != CallFrame:
					failure = "unsupportedState"
					return null
				fields = CALL_FIELDS
				result = CallFrame.new()
			else:
				failure = "unsupportedState"
				return null
			_objects[id] = null
			for field in fields:
				var cloned = copy(value.get(field), depth + 1)
				if not failure.is_empty():
					return null
				# assign preserves the typed stack declarations on 4.3 as well as 4.6.
				if field in ["saved_flow_stack", "saved_loop_stack"]:
					result.get(field).assign(cloned)
				else:
					result.set(field, cloned)
			_objects[id] = result
			return result
	failure = "unsupportedState"
	return null

# Bounded, shallow fingerprint only. Never recursively hash unvalidated contents.
func _container_bucket(value: Variant) -> int:
	var shape := [typeof(value), value.size()]
	var sampled := 0
	for key in value:
		shape.append(_shallow_hash(key))
		if value is Dictionary:
			shape.append(_shallow_hash(value[key]))
		sampled += 1
		if sampled == 3:
			break
	return hash(shape)

func _shallow_hash(value: Variant) -> int:
	match typeof(value):
		TYPE_ARRAY, TYPE_DICTIONARY:
			return hash([typeof(value), value.size()])
		TYPE_OBJECT:
			return value.get_instance_id() if is_instance_valid(value) else 0
		TYPE_STRING, TYPE_STRING_NAME:
			var string := String(value)
			return hash([typeof(value), string.length(), string.substr(0, 32)])
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT:
			return hash(value)
	return typeof(value)
