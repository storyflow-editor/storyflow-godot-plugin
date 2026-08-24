class_name StoryFlowExecutionContext
extends RefCounted

# Preloaded by path so parsing never depends on the global class name cache,
# which can be stale or mid-rewrite when the game launches (godotengine/godot#75388).
const StoryFlowCallFrame = preload("res://addons/storyflow/core/storyflow_call_frame.gd")
const StoryFlowDialogueState = preload("res://addons/storyflow/core/storyflow_dialogue_state.gd")
const StoryFlowLoopFrame = preload("res://addons/storyflow/core/storyflow_loop_frame.gd")
const StoryFlowNodeRuntimeState = preload("res://addons/storyflow/core/storyflow_node_runtime_state.gd")
const StoryFlowScript = preload("res://addons/storyflow/core/storyflow_script.gd")
const StoryFlowTypes = preload("res://addons/storyflow/core/storyflow_types.gd")

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
# Data Assets
# =============================================================================

## NON-OWNING references to StoryFlowManager's .sfd seed and session overlay (engine contract
## 3), handed over at dialogue start. The manager mutates both in place forever, so these stay
## valid for the life of the dialogue.
##
## REBIND these, never clear() them: the dictionaries belong to the manager, so clearing one
## through this reference would wipe the whole game's data-asset state. reset() below rebinds
## to fresh empties, which is the "no store" state every accessor checks.
var data_asset_seed: Dictionary = {}
var data_asset_overlay: Dictionary = {}

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
# Unknown Node Warning Dedup
# =============================================================================

## Set of node ids already warned about (forward-compat unsupported types).
## Resets on reset() so warnings can fire again on a new dialogue run.
var warned_unknown_nodes: Dictionary = {}

# =============================================================================
# Data Asset Warning Latch
# =============================================================================

## Claimed "node_id|reason" keys for the degraded-accessor ladder (engine contract 6:
## each condition warns ONCE PER NODE, re-armed on game reset). Keyed by REASON as well
## as node so an accessor that is first unwired and later dead-referenced still names the
## second problem once.
##
## This dictionary and the counter below are INSPECTABLE ON PURPOSE, and that is the only
## reason they are two things instead of one: Godot's push_warning cannot be captured from
## a SceneTree test, so the tests cannot assert on the warning TEXT at all. The latch dict
## proves which reasons fired, and the counter proves HOW MANY TIMES — which is what
## separates a working once-per-node latch from one that re-warns on every read (a latch
## implemented as a plain Add would keep the dict identical and only move the counter).
var warned_data_asset_nodes: Dictionary = {}

## Total data-asset warnings actually emitted this run. See above.
var data_asset_warnings_emitted: int = 0

# =============================================================================
# Methods
# =============================================================================

## Claim the warn latch for one (node, reason) pair (engine contract 6).
##
## Returns true exactly once per pair per run. The CALLER formats the message and calls
## push_warning INSIDE the if, which is what keeps the suppressed path — the common one, since
## option conditions re-evaluate on every render — off the expensive allocation: the warning
## text interpolates an asset id, a variable id and a node id, and is never built at all once
## the latch is claimed. The composite key below is still built per call; a nested
## node -> reason -> true Dictionary would avoid even that, and was judged not worth the
## lookup indirection and the less legible test assertions for a path that only runs while a
## graph is broken.
func should_warn_data_asset(node_id: String, reason: String) -> bool:
	var key := "%s|%s" % [node_id, reason]
	if warned_data_asset_nodes.has(key):
		return false
	warned_data_asset_nodes[key] = true
	data_asset_warnings_emitted += 1
	return true

func get_node_state(node_id: String) -> StoryFlowNodeRuntimeState:
	if not node_runtime_states.has(node_id):
		node_runtime_states[node_id] = StoryFlowNodeRuntimeState.new()
	return node_runtime_states[node_id]


func clear_cached_outputs() -> void:
	for node_id in node_runtime_states:
		var state: StoryFlowNodeRuntimeState = node_runtime_states[node_id]
		state.cached_output = null


## Drop ONLY the memoized derived booleans, leaving every other node output standing.
##
## THE MID-CHAIN INVALIDATION. A .sfd write changes what an option condition should answer, so
## the booleans computed above an accessor have to be recomputed - but clear_cached_outputs is
## indiscriminate, and mid-chain that is a bug rather than a cost. It nulls every cached_output
## there is, and two other things live in that field: an array forEach's current ELEMENT, and
## every array op's RESULT PIN. Both used to vanish when a .sfd Set ran anywhere earlier in the
## same exec chain, silently, with an identical trace.
##
## StoryFlowTypes.is_boolean_memo_node is the whole scope, and its header carries the reasoning
## for every inclusion and exclusion. The reference runtime's clearNotBoolCache has the same
## reach for the same reason.
##
## NOT a replacement for clear_cached_outputs at CHAIN BOUNDARIES - option selection, dialogue
## advance, loop iteration. Those legitimately want everything gone, because the chain that
## produced those outputs is over.
func clear_boolean_memo() -> void:
	for node_id in node_runtime_states:
		var node := current_script.get_node(node_id) if current_script else {}
		if node.is_empty():
			continue
		if StoryFlowTypes.is_boolean_memo_node(node.get("type", StoryFlowTypes.NodeType.UNKNOWN)):
			node_runtime_states[node_id].cached_output = null


## Re-stamp the current element of every ACTIVE array forEach onto its node's cached_output.
##
## CURRENTLY UNCALLED, and kept on purpose. It was the .sfd write path's repair until
## clear_boolean_memo made the damage impossible to do in the first place - no forEach type is a
## boolean memo type, so a selective clear cannot reach a loop element. What still needs it is
## every remaining BLUNT clear_cached_outputs that can run inside a loop body: a dialogue node in
## a forEach body loses its loop element on option selection or advance today, which is a
## separate open item.
##
## Call this after any clear_cached_outputs that happens INSIDE a loop body. An array forEach
## publishes its current element through cached_output, which clear_cached_outputs nulls along
## with everything else, so a mid-body clear leaves the loop-element pin reading nothing for the
## rest of the iteration. MAP loops are immune because loop_key/loop_value are dedicated fields
## for precisely this reason; array loops never got the same treatment, and this is the cheaper
## half of that fix.
##
## The frames on loop_stack are exactly the live iterations, innermost last, and the current
## frame is already pushed while its body runs - so this restores the innermost element too, not
## only the enclosing ones. Map frames carry an empty loop_array and are skipped by the bounds
## check, which is why one guard covers both loop kinds.
func restore_live_loop_outputs() -> void:
	for frame in loop_stack:
		var state: StoryFlowNodeRuntimeState = get_node_state(frame.node_id)
		if state.loop_initialized and state.loop_index < state.loop_array.size():
			state.cached_output = state.loop_array[state.loop_index]


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
	# REBOUND, not cleared - these point at manager-owned dictionaries (see above).
	data_asset_seed = {}
	data_asset_overlay = {}
	current_dialogue_state = null
	persistent_background_image = ""
	persistent_image = ""
	persistent_image_texture = null
	evaluation_depth = 0
	processing_depth = 0
	node_runtime_states.clear()
	input_option_values.clear()
	warned_unknown_nodes.clear()
	# RE-ARM the degraded-accessor warnings for the new run (engine contract 6).
	warned_data_asset_nodes.clear()
	data_asset_warnings_emitted = 0
