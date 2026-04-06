class_name StoryFlowExecutionContext
extends RefCounted

# =============================================================================
# Depth Limits
# =============================================================================

const MAX_EVALUATION_DEPTH := 100
const MAX_PROCESSING_DEPTH := 1000
const MAX_SCRIPT_DEPTH := 20
const MAX_FLOW_DEPTH := 50

# =============================================================================
# Current Execution State
# =============================================================================

var current_script: StoryFlowScript = null
var current_node_id: String = ""
var is_waiting_for_input: bool = false
var is_executing: bool = false
var is_paused: bool = false
var entering_dialogue_via_edge: bool = false

## Tracks node we came from (for Set* return-to-dialogue)
var previous_node_id: String = ""
var previous_node_type: StoryFlowTypes.NodeType = StoryFlowTypes.NodeType.UNKNOWN

# =============================================================================
# Stacks
# =============================================================================

## RunScript nesting
var call_stack: Array[StoryFlowCallFrame] = []

## RunFlow nesting (depth only): flow IDs
var flow_call_stack: Array[String] = []

## forEach nesting
var loop_stack: Array[StoryFlowLoopFrame] = []

# =============================================================================
# Variables
# =============================================================================

## Script-local variables: id → variable Dictionary
var local_variables: Dictionary = {}

## Name → ID index for local variables
var local_variable_name_index: Dictionary = {}

## Name → ID index for global variables
var global_variable_name_index: Dictionary = {}

# =============================================================================
# Current Display State
# =============================================================================

## Current dialogue state (typed)
var current_dialogue_state: StoryFlowDialogueState = null

## Persistent background image path
var persistent_background_image: String = ""

## Persistent dialogue image (carries over between dialogues unless reset)
var persistent_image: String = ""
## Cached resolved Texture2D for cross-script persistence (asset IDs are per-file)
var persistent_image_texture: Texture2D = null

# =============================================================================
# Recursion Protection
# =============================================================================

var evaluation_depth: int = 0
var processing_depth: int = 0

## node_id → StoryFlowNodeRuntimeState
var node_runtime_states: Dictionary = {}  # String → StoryFlowNodeRuntimeState

# =============================================================================
# Input Option Values
# =============================================================================

## Dialogue node input values: option_id → StoryFlowVariant
var input_option_values: Dictionary = {}

# =============================================================================
# Methods
# =============================================================================

func get_node_state(node_id: String) -> StoryFlowNodeRuntimeState:
	if not node_runtime_states.has(node_id):
		node_runtime_states[node_id] = StoryFlowNodeRuntimeState.new()
	return node_runtime_states[node_id]


func clear_cached_outputs() -> void:
	for node_id in node_runtime_states:
		var state: StoryFlowNodeRuntimeState = node_runtime_states[node_id]
		state.cached_output = null


func build_variable_name_index(variables: Dictionary, is_global: bool) -> void:
	var index: Dictionary = {}
	for var_id in variables:
		var v: Dictionary = variables[var_id]
		if v.has("name"):
			index[v["name"]] = var_id
	if is_global:
		global_variable_name_index = index
	else:
		local_variable_name_index = index


func find_variable_by_name(name: String) -> Dictionary:
	# Check local first, then global
	if local_variable_name_index.has(name):
		var var_id: String = local_variable_name_index[name]
		if local_variables.has(var_id):
			return {"id": var_id, "variable": local_variables[var_id], "is_global": false}

	if global_variable_name_index.has(name):
		return {"id": global_variable_name_index[name], "is_global": true}

	return {}


func reset() -> void:
	current_script = null
	current_node_id = ""
	is_waiting_for_input = false
	is_executing = false
	is_paused = false
	entering_dialogue_via_edge = false
	previous_node_id = ""
	previous_node_type = StoryFlowTypes.NodeType.UNKNOWN
	call_stack.clear()
	flow_call_stack.clear()
	loop_stack.clear()
	local_variables.clear()
	local_variable_name_index.clear()
	global_variable_name_index.clear()
	current_dialogue_state = null
	persistent_background_image = ""
	persistent_image = ""
	persistent_image_texture = null
	evaluation_depth = 0
	processing_depth = 0
	node_runtime_states.clear()
	input_option_values.clear()
