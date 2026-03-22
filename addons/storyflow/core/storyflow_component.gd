class_name StoryFlowComponent
extends Node

## Main runtime component for executing StoryFlow dialogues.
##
## Add this node to any scene that should run StoryFlow scripts. Configure
## the [member script_path] in the Inspector, then call [method start_dialogue]
## to begin execution.
##
## The global project is loaded automatically from StoryFlowManager (autoload)
## or can be set via the manager before starting dialogue.

# =============================================================================
# Configuration
# =============================================================================

## The script to run (e.g. "npcs/elder" or "main.json")
@export var script_path: String = ""

## Language code for string table lookup (empty = "en")
@export var language_code: String = "en"

## Optional dialogue UI scene; auto-instantiated when dialogue starts, freed when it ends.
@export var dialogue_ui_scene: PackedScene = null

@export_group("Audio")

## Stop any playing dialogue audio when dialogue ends
@export var stop_audio_on_dialogue_end: bool = true

## Audio bus for dialogue audio playback
@export var dialogue_audio_bus: StringName = &"Master"

## Volume in decibels for dialogue audio
@export var dialogue_volume_db: float = 0.0

# =============================================================================
# Signals
# =============================================================================

signal dialogue_started()
signal dialogue_updated(state: StoryFlowDialogueState)
signal dialogue_ended()
signal variable_changed(info: StoryFlowVariableChangeInfo)
signal script_started(script_path_name: String)
signal script_ended(script_path_name: String)
signal error_occurred(message: String)
signal background_image_changed(image_path: String)
signal audio_play_requested(audio_path: String, loop: bool)

# =============================================================================
# Internal State
# =============================================================================

var _context: StoryFlowExecutionContext = null
var _evaluator: StoryFlowEvaluator = null
var _text: StoryFlowTextInterpolator = null
var _audio: StoryFlowAudioController = null
var _dialogue_ui_instance: Control = null
var _is_processing_chain: bool = false
var _dialogue_dirty: bool = false
var _waiting_for_audio_advance: bool = false
var _audio_advance_allow_skip: bool = false

## NodeType enum value -> Callable
var _node_handlers: Dictionary = {}

# =============================================================================
# Lifecycle
# =============================================================================

func _ready() -> void:
	_context = StoryFlowExecutionContext.new()
	_text = StoryFlowTextInterpolator.new()
	_text.set_context(_context)
	_audio = StoryFlowAudioController.new()
	_audio.initialize(self, dialogue_audio_bus, dialogue_volume_db)
	_audio.playback_finished.connect(_on_dialogue_audio_finished)
	_build_dispatch_table()


func _exit_tree() -> void:
	if _audio:
		_audio.stop()
	# Silently clean up without emitting signals or accessing the manager,
	# which may already be freed during tree teardown.
	if _context and _context.is_executing:
		_context.reset()
		_evaluator = null
		if _dialogue_ui_instance and is_instance_valid(_dialogue_ui_instance):
			_dialogue_ui_instance.queue_free()
			_dialogue_ui_instance = null

# =============================================================================
# Control Functions
# =============================================================================

## Start dialogue execution using the configured [member script_path].
func start_dialogue() -> void:
	if script_path.is_empty():
		_report_error("No script configured for StoryFlowComponent")
		return
	start_dialogue_with_script(script_path)


## Start dialogue with a specific script path (overrides [member script_path]).
func start_dialogue_with_script(path: String) -> void:
	if path.is_empty():
		_report_error("start_dialogue_with_script called with empty path")
		return

	var mgr := get_manager()
	if not mgr:
		_report_error("StoryFlowRuntime autoload not found")
		return

	var project: StoryFlowProject = mgr.get_project()
	if not project:
		_report_error("No StoryFlow project loaded. Import a project or set it via StoryFlowRuntime.")
		return

	var script_asset: StoryFlowScript = project.get_storyflow_script(path)
	if not script_asset:
		_report_error("Script not found: %s" % path)
		return

	# Initialize execution context
	_context.reset()
	_context.current_script = script_asset
	_context.current_node_id = "0"
	_context.is_executing = true

	# Copy local variables from script
	_context.local_variables = StoryFlowVariant.deep_copy_variables(script_asset.variables)
	_context.build_variable_name_index(script_asset.variables, false)

	# Build global variable name index
	_context.build_variable_name_index(mgr.get_global_variables(), true)

	# Create evaluator
	_evaluator = StoryFlowEvaluator.new()
	_evaluator.initialize(_context, mgr.get_global_variables(), mgr.get_runtime_characters(), language_code)

	# Wire up text interpolator with manager reference
	_text.set_manager(mgr)
	_text.set_language_code(language_code)

	# Register with manager
	mgr.register_dialogue_start()

	# Create dialogue UI (use built-in default if none assigned)
	var ui_scene: PackedScene = dialogue_ui_scene
	if not ui_scene:
		ui_scene = load("res://addons/storyflow/ui/storyflow_dialogue_ui.tscn") as PackedScene
	if ui_scene:
		if _dialogue_ui_instance:
			_dialogue_ui_instance.queue_free()
			_dialogue_ui_instance = null
		_dialogue_ui_instance = ui_scene.instantiate() as Control
		if _dialogue_ui_instance:
			# Try to connect it if it has an initialize method
			if _dialogue_ui_instance.has_method("initialize_with_component"):
				_dialogue_ui_instance.call("initialize_with_component", self)
			add_child(_dialogue_ui_instance)

	# Broadcast start events
	dialogue_started.emit()
	script_started.emit(path)

	# Find start node and begin execution
	var start_node: Dictionary = script_asset.get_start_node()
	if not start_node.is_empty():
		_process_node(start_node)
	else:
		_report_error("Start node (id=0) not found in script")


## Select a dialogue option by ID.
func select_option(option_id: String) -> void:
	if not _context.is_executing or not _context.is_waiting_for_input:
		return

	var state := _context.current_dialogue_state
	if not state:
		return

	# Validate option exists
	if not state.find_option(option_id):
		return

	# Mark once-only options as used
	var dialogue_node_id: String = state.node_id
	var current_node: Dictionary = _context.current_script.get_node(dialogue_node_id)
	if not current_node.is_empty():
		var data: Dictionary = current_node.get("data", {})
		var node_options: Array = data.get("options", [])
		for choice in node_options:
			if choice.get("id", "") == option_id and choice.get("onceOnly", false):
				var option_key := dialogue_node_id + "-" + option_id
				var mgr := get_manager()
				if mgr:
					mgr.mark_option_used(option_key)
				break

	# Save current dialogue node ID for potential re-render
	var saved_dialogue_node_id := dialogue_node_id

	# Clear waiting state
	_context.is_waiting_for_input = false

	# Clear evaluation cache for fresh evaluation
	if _evaluator:
		_evaluator.clear_cache()

	# Clear cached node outputs
	_context.clear_cached_outputs()

	# Begin processing chain — defer variable-change re-renders
	_is_processing_chain = true
	_dialogue_dirty = false

	# Continue from the selected option
	var source_handle := StoryFlowHandles.source(dialogue_node_id, option_id)
	_process_next_node(source_handle)

	# End processing chain — flush any deferred re-render
	_is_processing_chain = false
	_flush_deferred_dialogue_update()

	# If no edge was found (dead end) and we're still executing but not waiting for input,
	# return to the current dialogue to re-render
	if not _context.is_waiting_for_input and _context.is_executing:
		var node: Dictionary = _context.current_script.get_node(saved_dialogue_node_id)
		if not node.is_empty() and node.get("type", -1) == StoryFlowTypes.NodeType.DIALOGUE:
			_context.current_dialogue_state = _build_dialogue_state(node)
			_context.is_waiting_for_input = true
			dialogue_updated.emit(_context.current_dialogue_state)


## Advance a narrative-only dialogue (no options defined). Uses the header output edge.
func advance_dialogue() -> void:
	if not _context.is_executing or not _context.is_waiting_for_input:
		return

	if not _context.current_dialogue_state:
		return

	# Audio advance-on-end: block manual advance if skip is not allowed
	if _waiting_for_audio_advance and not _audio_advance_allow_skip:
		return

	# Audio advance-on-end with skip: stop audio and proceed
	if _waiting_for_audio_advance and _audio_advance_allow_skip:
		if _audio:
			_audio.stop()
		_waiting_for_audio_advance = false
		_audio_advance_allow_skip = false

	var dialogue_node_id: String = _context.current_dialogue_state.node_id
	var current_node: Dictionary = _context.current_script.get_node(dialogue_node_id)
	if current_node.is_empty() or current_node.get("type", -1) != StoryFlowTypes.NodeType.DIALOGUE:
		return

	# Only advance if there are no defined options (use select_option for those)
	var data: Dictionary = current_node.get("data", {})
	if data.get("options", []).size() > 0:
		return

	var header_handle := StoryFlowHandles.source(dialogue_node_id)
	var edge: Dictionary = _context.current_script.find_connection_by_source_handle(header_handle)
	if edge.is_empty():
		return

	_context.is_waiting_for_input = false

	if _evaluator:
		_evaluator.clear_cache()

	_is_processing_chain = true
	_dialogue_dirty = false
	_process_next_node(header_handle)
	_is_processing_chain = false
	_flush_deferred_dialogue_update()


## Stop dialogue execution.
func stop_dialogue() -> void:
	if not _context.is_executing:
		return

	_waiting_for_audio_advance = false
	_audio_advance_allow_skip = false

	if stop_audio_on_dialogue_end and _audio:
		_audio.stop()

	var current_script_path := ""
	if _context.current_script:
		current_script_path = _context.current_script.script_path

	_context.reset()
	_evaluator = null

	var mgr := get_manager()
	if mgr:
		mgr.register_dialogue_end()

	script_ended.emit(current_script_path)
	dialogue_ended.emit()

	# Destroy dialogue UI after broadcasting so it receives dialogue_ended
	if _dialogue_ui_instance:
		_dialogue_ui_instance.queue_free()
		_dialogue_ui_instance = null


## Pause dialogue execution.
func pause_dialogue() -> void:
	_context.is_paused = true


## Resume paused dialogue execution.
func resume_dialogue() -> void:
	if not _context.is_paused:
		return
	_context.is_paused = false
	if _context.is_waiting_for_input:
		dialogue_updated.emit(_context.current_dialogue_state)

# =============================================================================
# State Access
# =============================================================================

## Get the current dialogue state.
func get_current_dialogue() -> StoryFlowDialogueState:
	return _context.current_dialogue_state


## Check if dialogue is currently active.
func is_dialogue_active() -> bool:
	return _context.is_executing


## Check if dialogue is waiting for player input.
func is_waiting_for_input() -> bool:
	return _context.is_waiting_for_input


## Check if dialogue is paused.
func is_paused() -> bool:
	return _context.is_paused


## Get the StoryFlowManager autoload singleton.
func get_manager() -> Node:
	return get_node_or_null("/root/StoryFlowRuntime")

# =============================================================================
# Variable Access (by display name)
# =============================================================================

func get_bool_variable(variable_name: String) -> bool:
	var result := _find_variable_by_display_name(variable_name)
	if result.is_empty():
		return false
	var v: Dictionary = result["variable"]
	var val = v.get("value", null)
	if val is StoryFlowVariant:
		return val.get_bool()
	return false


func set_bool_variable(variable_name: String, value: bool) -> void:
	var result := _find_variable_by_display_name(variable_name)
	if result.is_empty():
		return
	var variant := StoryFlowVariant.new()
	variant.set_bool(value)
	_set_variable_from_result(result, variant)


func get_int_variable(variable_name: String) -> int:
	var result := _find_variable_by_display_name(variable_name)
	if result.is_empty():
		return 0
	var v: Dictionary = result["variable"]
	var val = v.get("value", null)
	if val is StoryFlowVariant:
		return val.get_int()
	return 0


func set_int_variable(variable_name: String, value: int) -> void:
	var result := _find_variable_by_display_name(variable_name)
	if result.is_empty():
		return
	var variant := StoryFlowVariant.new()
	variant.set_int(value)
	_set_variable_from_result(result, variant)


func get_float_variable(variable_name: String) -> float:
	var result := _find_variable_by_display_name(variable_name)
	if result.is_empty():
		return 0.0
	var v: Dictionary = result["variable"]
	var val = v.get("value", null)
	if val is StoryFlowVariant:
		return val.get_float()
	return 0.0


func set_float_variable(variable_name: String, value: float) -> void:
	var result := _find_variable_by_display_name(variable_name)
	if result.is_empty():
		return
	var variant := StoryFlowVariant.new()
	variant.set_float(value)
	_set_variable_from_result(result, variant)


func get_string_variable(variable_name: String) -> String:
	var result := _find_variable_by_display_name(variable_name)
	if result.is_empty():
		return ""
	var v: Dictionary = result["variable"]
	var val = v.get("value", null)
	if val is StoryFlowVariant:
		return val.get_string()
	return ""


func set_string_variable(variable_name: String, value: String) -> void:
	var result := _find_variable_by_display_name(variable_name)
	if result.is_empty():
		return
	var variant := StoryFlowVariant.new()
	variant.set_string(value)
	_set_variable_from_result(result, variant)


func get_enum_variable(variable_name: String) -> String:
	return get_string_variable(variable_name)


func set_enum_variable(variable_name: String, value: String) -> void:
	var result := _find_variable_by_display_name(variable_name)
	if result.is_empty():
		return
	var variant := StoryFlowVariant.new()
	variant.set_enum(value)
	_set_variable_from_result(result, variant)

# =============================================================================
# Character Variable Access
# =============================================================================

func get_character_variable(character_path: String, variable_name: String) -> StoryFlowVariant:
	var mgr := get_manager()
	if not mgr:
		return StoryFlowVariant.new()
	var character: StoryFlowCharacter = mgr.get_runtime_character(character_path)
	if not character:
		return StoryFlowVariant.new()
	var v: Dictionary = character.variables.get(variable_name, {})
	var val = v.get("value", null)
	if val is StoryFlowVariant:
		return val
	return StoryFlowVariant.new()


func set_character_variable(character_path: String, variable_name: String, value: StoryFlowVariant) -> void:
	var mgr := get_manager()
	if not mgr:
		return
	var character: StoryFlowCharacter = mgr.get_runtime_character(character_path)
	if not character or not character.variables.has(variable_name):
		return
	character.variables[variable_name]["value"] = value

# =============================================================================
# Utility Functions
# =============================================================================

## Reset all local variables to their initial values from the current script.
func reset_variables() -> void:
	if _context.current_script:
		_context.local_variables = StoryFlowVariant.deep_copy_variables(_context.current_script.variables)
		_context.build_variable_name_index(_context.current_script.variables, false)


## Get a localized string by key from the current script or global strings.
func get_localized_string(key: String) -> String:
	return _text.get_string(key, language_code)

# =============================================================================
# Dispatch Table
# =============================================================================

func _build_dispatch_table() -> void:
	var NT := StoryFlowTypes.NodeType

	# Control flow
	_node_handlers[NT.START] = _handle_start
	_node_handlers[NT.END] = _handle_end
	_node_handlers[NT.BRANCH] = _handle_branch
	_node_handlers[NT.DIALOGUE] = _handle_dialogue
	_node_handlers[NT.RUN_SCRIPT] = _handle_run_script
	_node_handlers[NT.RUN_FLOW] = _handle_run_flow
	_node_handlers[NT.ENTRY_FLOW] = _handle_entry_flow

	# Variable get (data nodes that produce output)
	_node_handlers[NT.GET_BOOL] = _handle_get_bool
	_node_handlers[NT.GET_INT] = _handle_get_int
	_node_handlers[NT.GET_FLOAT] = _handle_get_float
	_node_handlers[NT.GET_STRING] = _handle_get_string
	_node_handlers[NT.GET_ENUM] = _handle_get_enum

	# Variable set (flow nodes)
	_node_handlers[NT.SET_BOOL] = _handle_set_bool
	_node_handlers[NT.SET_INT] = _handle_set_int
	_node_handlers[NT.SET_FLOAT] = _handle_set_float
	_node_handlers[NT.SET_STRING] = _handle_set_string
	_node_handlers[NT.SET_ENUM] = _handle_set_enum

	# Enum / random
	_node_handlers[NT.SWITCH_ON_ENUM] = _handle_switch_on_enum
	_node_handlers[NT.RANDOM_BRANCH] = _handle_random_branch

	# Logic nodes (no-op at execution, evaluated lazily)
	var logic_handler := _handle_logic_node
	for t in [
		NT.AND_BOOL, NT.OR_BOOL, NT.NOT_BOOL, NT.EQUAL_BOOL,
		NT.GREATER_THAN, NT.GREATER_THAN_OR_EQUAL, NT.LESS_THAN, NT.LESS_THAN_OR_EQUAL, NT.EQUAL_INT,
		NT.PLUS, NT.MINUS, NT.MULTIPLY, NT.DIVIDE, NT.RANDOM,
		NT.GREATER_THAN_FLOAT, NT.GREATER_THAN_OR_EQUAL_FLOAT,
		NT.LESS_THAN_FLOAT, NT.LESS_THAN_OR_EQUAL_FLOAT, NT.EQUAL_FLOAT,
		NT.PLUS_FLOAT, NT.MINUS_FLOAT, NT.MULTIPLY_FLOAT, NT.DIVIDE_FLOAT, NT.RANDOM_FLOAT,
		NT.CONCATENATE_STRING, NT.EQUAL_STRING, NT.CONTAINS_STRING,
		NT.TO_UPPER_CASE, NT.TO_LOWER_CASE, NT.LENGTH_STRING,
		NT.EQUAL_ENUM, NT.ENUM_TO_STRING,
		NT.INT_TO_BOOLEAN, NT.FLOAT_TO_BOOLEAN,
		NT.BOOLEAN_TO_INT, NT.BOOLEAN_TO_FLOAT,
		NT.INT_TO_STRING, NT.FLOAT_TO_STRING,
		NT.STRING_TO_INT, NT.STRING_TO_FLOAT,
		NT.INT_TO_ENUM, NT.STRING_TO_ENUM,
		NT.INT_TO_FLOAT, NT.FLOAT_TO_INT,
	]:
		_node_handlers[t] = logic_handler

	# Array set handlers (whole array or element)
	var array_set_handler := _handle_array_set
	for t in [
		NT.SET_BOOL_ARRAY, NT.SET_INT_ARRAY, NT.SET_FLOAT_ARRAY, NT.SET_STRING_ARRAY,
		NT.SET_IMAGE_ARRAY, NT.SET_CHARACTER_ARRAY, NT.SET_AUDIO_ARRAY,
		NT.SET_BOOL_ARRAY_ELEMENT, NT.SET_INT_ARRAY_ELEMENT, NT.SET_FLOAT_ARRAY_ELEMENT,
		NT.SET_STRING_ARRAY_ELEMENT, NT.SET_IMAGE_ARRAY_ELEMENT,
		NT.SET_CHARACTER_ARRAY_ELEMENT, NT.SET_AUDIO_ARRAY_ELEMENT,
	]:
		_node_handlers[t] = array_set_handler

	# Array modify handlers (add, remove, clear)
	var array_modify_handler := _handle_array_modify
	for t in [
		NT.ADD_TO_BOOL_ARRAY, NT.ADD_TO_INT_ARRAY, NT.ADD_TO_FLOAT_ARRAY,
		NT.ADD_TO_STRING_ARRAY, NT.ADD_TO_IMAGE_ARRAY,
		NT.ADD_TO_CHARACTER_ARRAY, NT.ADD_TO_AUDIO_ARRAY,
		NT.REMOVE_FROM_BOOL_ARRAY, NT.REMOVE_FROM_INT_ARRAY, NT.REMOVE_FROM_FLOAT_ARRAY,
		NT.REMOVE_FROM_STRING_ARRAY, NT.REMOVE_FROM_IMAGE_ARRAY,
		NT.REMOVE_FROM_CHARACTER_ARRAY, NT.REMOVE_FROM_AUDIO_ARRAY,
		NT.CLEAR_BOOL_ARRAY, NT.CLEAR_INT_ARRAY, NT.CLEAR_FLOAT_ARRAY,
		NT.CLEAR_STRING_ARRAY, NT.CLEAR_IMAGE_ARRAY,
		NT.CLEAR_CHARACTER_ARRAY, NT.CLEAR_AUDIO_ARRAY,
	]:
		_node_handlers[t] = array_modify_handler

	# Array get handlers (data nodes, no-op)
	for t in [
		NT.GET_BOOL_ARRAY, NT.GET_INT_ARRAY, NT.GET_FLOAT_ARRAY,
		NT.GET_STRING_ARRAY, NT.GET_IMAGE_ARRAY,
		NT.GET_CHARACTER_ARRAY, NT.GET_AUDIO_ARRAY,
		NT.GET_BOOL_ARRAY_ELEMENT, NT.GET_INT_ARRAY_ELEMENT, NT.GET_FLOAT_ARRAY_ELEMENT,
		NT.GET_STRING_ARRAY_ELEMENT, NT.GET_IMAGE_ARRAY_ELEMENT,
		NT.GET_CHARACTER_ARRAY_ELEMENT, NT.GET_AUDIO_ARRAY_ELEMENT,
		NT.GET_RANDOM_BOOL_ARRAY_ELEMENT, NT.GET_RANDOM_INT_ARRAY_ELEMENT,
		NT.GET_RANDOM_FLOAT_ARRAY_ELEMENT, NT.GET_RANDOM_STRING_ARRAY_ELEMENT,
		NT.GET_RANDOM_IMAGE_ARRAY_ELEMENT, NT.GET_RANDOM_CHARACTER_ARRAY_ELEMENT,
		NT.GET_RANDOM_AUDIO_ARRAY_ELEMENT,
		NT.ARRAY_LENGTH_BOOL, NT.ARRAY_LENGTH_INT, NT.ARRAY_LENGTH_FLOAT,
		NT.ARRAY_LENGTH_STRING, NT.ARRAY_LENGTH_IMAGE,
		NT.ARRAY_LENGTH_CHARACTER, NT.ARRAY_LENGTH_AUDIO,
		NT.ARRAY_CONTAINS_BOOL, NT.ARRAY_CONTAINS_INT, NT.ARRAY_CONTAINS_FLOAT,
		NT.ARRAY_CONTAINS_STRING, NT.ARRAY_CONTAINS_IMAGE,
		NT.ARRAY_CONTAINS_CHARACTER, NT.ARRAY_CONTAINS_AUDIO,
		NT.FIND_IN_BOOL_ARRAY, NT.FIND_IN_INT_ARRAY, NT.FIND_IN_FLOAT_ARRAY,
		NT.FIND_IN_STRING_ARRAY, NT.FIND_IN_IMAGE_ARRAY,
		NT.FIND_IN_CHARACTER_ARRAY, NT.FIND_IN_AUDIO_ARRAY,
	]:
		_node_handlers[t] = logic_handler

	# ForEach loop handlers
	var for_each_handler := _handle_for_each_loop
	for t in [
		NT.FOR_EACH_BOOL_LOOP, NT.FOR_EACH_INT_LOOP, NT.FOR_EACH_FLOAT_LOOP,
		NT.FOR_EACH_STRING_LOOP, NT.FOR_EACH_IMAGE_LOOP,
		NT.FOR_EACH_CHARACTER_LOOP, NT.FOR_EACH_AUDIO_LOOP,
	]:
		_node_handlers[t] = for_each_handler

	# Media get handlers (data nodes)
	_node_handlers[NT.GET_IMAGE] = logic_handler
	_node_handlers[NT.GET_AUDIO] = logic_handler
	_node_handlers[NT.GET_CHARACTER] = logic_handler

	# Media set handlers
	_node_handlers[NT.SET_IMAGE] = _handle_set_image
	_node_handlers[NT.SET_BACKGROUND_IMAGE] = _handle_set_background_image
	_node_handlers[NT.SET_AUDIO] = _handle_set_audio
	_node_handlers[NT.PLAY_AUDIO] = _handle_play_audio
	_node_handlers[NT.SET_CHARACTER] = _handle_set_character

	# Character variable handlers
	_node_handlers[NT.GET_CHARACTER_VAR] = logic_handler
	_node_handlers[NT.SET_CHARACTER_VAR] = _handle_set_character_var

# =============================================================================
# Core Processing
# =============================================================================

func _process_node(node: Dictionary) -> void:
	if node.is_empty():
		return
	if not _context.is_executing:
		return
	if _context.is_paused:
		return

	# Processing depth protection against cyclic graphs
	if _context.processing_depth >= StoryFlowExecutionContext.MAX_PROCESSING_DEPTH:
		_report_error("Max processing depth exceeded (%d) - possible cyclic graph" % StoryFlowExecutionContext.MAX_PROCESSING_DEPTH)
		stop_dialogue()
		return
	_context.processing_depth += 1

	_context.current_node_id = node.get("id", "")

	var node_type: StoryFlowTypes.NodeType = node.get("type", StoryFlowTypes.NodeType.UNKNOWN)
	if _node_handlers.has(node_type):
		var handler: Callable = _node_handlers[node_type]
		handler.call(node)
	else:
		# Unknown node type - try to follow default output
		_process_next_node(StoryFlowHandles.source(node.get("id", "")))

	_context.processing_depth -= 1


func _process_next_node(source_handle: String) -> void:
	var edge: Dictionary = _context.current_script.find_connection_by_source_handle(source_handle)
	if edge.is_empty():
		return

	var target_id: String = edge.get("target", "")
	var target_node: Dictionary = _context.current_script.get_node(target_id)
	if target_node.is_empty():
		_report_error("Target node not found: %s" % target_id)
		return

	# Mark that we're entering via edge (fresh entry)
	if target_node.get("type", -1) == StoryFlowTypes.NodeType.DIALOGUE:
		_context.entering_dialogue_via_edge = true

	_process_node(target_node)

# =============================================================================
# Node Handlers - Control Flow
# =============================================================================

func _handle_start(node: Dictionary) -> void:
	_process_next_node(StoryFlowHandles.source(node["id"]))


func _handle_end(node: Dictionary) -> void:
	var exit_flow_id := ""

	# Pop flow call stack and check if it's an exit flow
	if _context.flow_call_stack.size() > 0:
		var popped_flow_id: String = _context.flow_call_stack.pop_back()

		# If we're in a nested script, check if this flow is an exit route
		if _context.call_stack.size() > 0 and popped_flow_id != "":
			var script_asset: StoryFlowScript = _context.current_script
			if script_asset:
				for fid in script_asset.flows:
					var flow_def: Dictionary = script_asset.flows[fid]
					if flow_def.get("id", "") == popped_flow_id and flow_def.get("is_exit", false):
						exit_flow_id = popped_flow_id
						break

	# Clean up any active loop state for the ending script
	_context.loop_stack.clear()

	# Check if we're in a nested script (runScript call)
	if _context.call_stack.size() > 0:
		# If exit flow, check if exit handle is connected in calling script BEFORE popping
		if exit_flow_id != "":
			var top_frame: StoryFlowCallFrame = _context.call_stack.back()
			if top_frame.script_asset:
				var exit_handle := "source-%s-exit-%s" % [top_frame.return_node_id, exit_flow_id]
				var check_edge: Dictionary = top_frame.script_asset.find_connection_by_source_handle(exit_handle)
				if check_edge.is_empty():
					# Exit handle not connected - stay in called script
					return

		# Gather output variable values BEFORE popping
		var output_values: Dictionary = {}
		for var_id in _context.local_variables:
			var v: Dictionary = _context.local_variables[var_id]
			if v.get("is_output", false):
				output_values[v.get("name", "")] = v.get("value", null)

		# Pop call stack
		var frame: StoryFlowCallFrame = _context.call_stack.pop_back()
		var ended_script_path := ""
		if _context.current_script:
			ended_script_path = _context.current_script.script_path
		script_ended.emit(ended_script_path)

		if frame.script_asset:
			_context.current_script = frame.script_asset
			_context.local_variables = frame.saved_variables
			_context.build_variable_name_index(_context.local_variables, false)

			# Restore flow call stack
			_context.flow_call_stack = frame.saved_flow_stack.duplicate()

			# Store output values on the RunScript node's runtime state
			if output_values.size() > 0:
				var rs_state: StoryFlowNodeRuntimeState = _context.get_node_state(frame.return_node_id)
				rs_state.output_values = output_values
				rs_state.has_output_values = true

			# Route: exit handle if exit flow, otherwise default output
			var handle := ""
			if exit_flow_id != "":
				handle = "source-%s-exit-%s" % [frame.return_node_id, exit_flow_id]
			else:
				handle = StoryFlowHandles.source(frame.return_node_id, StoryFlowHandles.OUT_OUTPUT)

			var edge: Dictionary = _context.current_script.find_connection_by_source_handle(handle)
			if not edge.is_empty():
				_process_next_node(handle)
	else:
		# Main script complete
		stop_dialogue()


func _handle_branch(node: Dictionary) -> void:
	# Process boolean chain to cache results
	if _evaluator:
		_evaluator.process_boolean_chain(node.get("id", ""))

	# Evaluate condition
	var data: Dictionary = node.get("data", {})
	var default_val := false
	var inline_value = data.get("value", null)
	if inline_value is StoryFlowVariant:
		default_val = inline_value.get_bool(false)
	elif inline_value is bool:
		default_val = inline_value

	var condition := default_val
	if _evaluator:
		condition = _evaluator.evaluate_boolean_input(node.get("id", ""), StoryFlowHandles.IN_BOOLEAN_CONDITION, default_val)

	# Continue based on condition
	var suffix: String = StoryFlowHandles.OUT_TRUE if condition else StoryFlowHandles.OUT_FALSE
	var handle := StoryFlowHandles.source(node["id"], suffix)

	var edge: Dictionary = _context.current_script.find_connection_by_source_handle(handle)
	if not edge.is_empty():
		_process_next_node(handle)
	else:
		# No edge for taken branch - check forEach loop
		if _context.loop_stack.size() > 0:
			var loop_frame: StoryFlowLoopFrame = _context.loop_stack.back()
			if loop_frame.type == StoryFlowTypes.LoopType.FOR_EACH:
				_continue_for_each_loop(loop_frame.node_id)


func _handle_dialogue(node: Dictionary) -> void:
	# Check if this is a fresh entry or returning from a Set* node
	var is_fresh_entry := _context.entering_dialogue_via_edge
	_context.entering_dialogue_via_edge = false

	# Clear evaluation cache for fresh option visibility evaluation
	if _evaluator:
		_evaluator.clear_cache()

	# Build dialogue state
	_context.current_dialogue_state = _build_dialogue_state(node)
	_context.is_waiting_for_input = true

	# Handle dialogue audio only on fresh entry
	if is_fresh_entry and _audio:
		var data: Dictionary = node.get("data", {})
		if _context.current_dialogue_state.audio:
			var audio_loop: bool = data.get("audioLoop", false)
			_audio.play(_context.current_dialogue_state.audio, audio_loop)

			# Set advance-on-end state (only for non-looped audio that actually played)
			var advance_on_end: bool = data.get("audioAdvanceOnEnd", false)
			_waiting_for_audio_advance = advance_on_end and not audio_loop and _audio.is_playing()
			_audio_advance_allow_skip = _waiting_for_audio_advance and data.get("audioAllowSkip", false)

			# If audio was expected to play but didn't, clear flags
			if advance_on_end and not _audio.is_playing():
				_waiting_for_audio_advance = false
				_audio_advance_allow_skip = false
		elif data.get("audioReset", false):
			_audio.stop()
			_waiting_for_audio_advance = false
			_audio_advance_allow_skip = false

	# Broadcast update
	dialogue_updated.emit(_context.current_dialogue_state)

# =============================================================================
# Node Handlers - Script / Flow
# =============================================================================

func _handle_run_script(node: Dictionary) -> void:
	if _context.call_stack.size() >= StoryFlowExecutionContext.MAX_SCRIPT_DEPTH:
		_report_error("Max script nesting depth exceeded (%d)" % StoryFlowExecutionContext.MAX_SCRIPT_DEPTH)
		return

	var data: Dictionary = node.get("data", {})
	var target_script_path: String = data.get("script", "")
	if target_script_path.is_empty():
		_report_error("RunScript node has no script path")
		return

	var mgr := get_manager()
	if not mgr:
		return

	var project: StoryFlowProject = mgr.get_project()
	if not project:
		return

	var target_script: StoryFlowScript = project.get_storyflow_script(target_script_path)
	if not target_script:
		_report_error("Script not found: %s" % target_script_path)
		return

	# Evaluate parameter values BEFORE pushing (while still in calling script context)
	var param_values: Dictionary = {}
	var script_params: Array = data.get("scriptParameters", [])
	if _evaluator and script_params.size() > 0:
		for param in script_params:
			var param_type: String = param.get("type", "")
			var param_id: String = param.get("id", "")
			var param_name: String = param.get("name", "")
			var handle_suffix := param_type + "-param-" + param_id

			if _context.current_script.find_input_edge(node["id"], handle_suffix).is_empty():
				continue

			if param_type == "boolean":
				param_values[param_name] = StoryFlowVariant.from_bool(
					_evaluator.evaluate_boolean_input(node.get("id", ""), handle_suffix, false)
				)
			elif param_type == "integer":
				param_values[param_name] = StoryFlowVariant.from_int(
					_evaluator.evaluate_integer_input(node.get("id", ""), handle_suffix, 0)
				)
			elif param_type == "float":
				param_values[param_name] = StoryFlowVariant.from_float(
					_evaluator.evaluate_float_input(node.get("id", ""), handle_suffix, 0.0)
				)
			else:
				param_values[param_name] = StoryFlowVariant.from_string(
					_evaluator.evaluate_string_input(node.get("id", ""), handle_suffix, "")
				)

	# Push current state
	var call_frame := StoryFlowCallFrame.new()
	call_frame.script_path = _context.current_script.script_path if _context.current_script else ""
	call_frame.return_node_id = node["id"]
	call_frame.script_asset = _context.current_script
	call_frame.saved_variables = StoryFlowVariant.deep_copy_variables(_context.local_variables)
	call_frame.saved_flow_stack = _context.flow_call_stack.duplicate()
	_context.call_stack.push_back(call_frame)

	# Switch to target script
	_context.current_script = target_script
	_context.local_variables = StoryFlowVariant.deep_copy_variables(target_script.variables)
	_context.build_variable_name_index(target_script.variables, false)
	_context.flow_call_stack.clear()

	script_started.emit(target_script_path)

	# Apply parameter values to the called script's local variables
	for param_name in param_values:
		for var_id in _context.local_variables:
			if _context.local_variables[var_id].get("name", "") == param_name:
				_context.local_variables[var_id]["value"] = param_values[param_name]
				break

	# Start from node 0 in new script
	var start_node: Dictionary = target_script.get_start_node()
	if not start_node.is_empty():
		_process_node(start_node)
	else:
		_report_error("Start node not found in script: %s" % target_script_path)


func _handle_run_flow(node: Dictionary) -> void:
	var data: Dictionary = node.get("data", {})
	var flow_id: String = data.get("flowId", "")
	if flow_id.is_empty():
		_report_error("RunFlow node has no flow ID")
		return

	if _context.flow_call_stack.size() >= StoryFlowExecutionContext.MAX_FLOW_DEPTH:
		_report_error("Too many nested flows - possible infinite loop")
		return

	var script_asset: StoryFlowScript = _context.current_script
	if not script_asset:
		return

	# Check if this is an exit flow
	for fid in script_asset.flows:
		var flow_def: Dictionary = script_asset.flows[fid]
		if flow_def.get("id", "") == flow_id and flow_def.get("is_exit", false):
			# Exit flow: push onto stack so end handler detects it, then trigger end
			_context.flow_call_stack.push_back(flow_id)
			_handle_end(node)
			return

	# Special case: calling the main "Start" flow
	if flow_id.to_lower() == "start":
		_context.flow_call_stack.push_back(flow_id)
		var start_node: Dictionary = script_asset.get_start_node()
		if not start_node.is_empty():
			_process_node(start_node)
		return

	# Find entryFlow node with matching flowId
	for node_id in script_asset.nodes:
		var n: Dictionary = script_asset.nodes[node_id]
		if n.get("type", -1) == StoryFlowTypes.NodeType.ENTRY_FLOW:
			var n_data: Dictionary = n.get("data", {})
			if n_data.get("flowId", "") == flow_id:
				_context.flow_call_stack.push_back(flow_id)
				_process_node(n)
				return

	_report_error("EntryFlow not found for flowId: %s" % flow_id)


func _handle_entry_flow(node: Dictionary) -> void:
	_process_next_node(StoryFlowHandles.source(node["id"]))

# =============================================================================
# Node Handlers - Variable Get (data nodes, just continue to typed output)
# =============================================================================

func _handle_get_bool(node: Dictionary) -> void:
	_process_next_node(StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_BOOLEAN))


func _handle_get_int(node: Dictionary) -> void:
	_process_next_node(StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_INTEGER))


func _handle_get_float(node: Dictionary) -> void:
	_process_next_node(StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_FLOAT))


func _handle_get_string(node: Dictionary) -> void:
	_process_next_node(StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_STRING))


func _handle_get_enum(node: Dictionary) -> void:
	_process_next_node(StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_ENUM))

# =============================================================================
# Node Handlers - Variable Set
# =============================================================================

func _handle_set_bool(node: Dictionary) -> void:
	var data: Dictionary = node.get("data", {})
	var default_val := false
	var inline_value = data.get("value", null)
	if inline_value is StoryFlowVariant:
		default_val = inline_value.get_bool(false)
	elif inline_value is bool:
		default_val = inline_value

	var new_value := default_val
	if _evaluator:
		new_value = _evaluator.evaluate_boolean_input(node.get("id", ""), StoryFlowHandles.IN_BOOLEAN, default_val)

	var variant := StoryFlowVariant.new()
	variant.set_bool(new_value)
	_set_variable_on_node(node, variant)
	_handle_set_node_end(node, StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_FLOW))


func _handle_set_int(node: Dictionary) -> void:
	var data: Dictionary = node.get("data", {})
	var default_val := 0
	var inline_value = data.get("value", null)
	if inline_value is StoryFlowVariant:
		default_val = inline_value.get_int(0)
	elif inline_value is int:
		default_val = inline_value

	var new_value := default_val
	if _evaluator:
		new_value = _evaluator.evaluate_integer_input(node.get("id", ""), StoryFlowHandles.IN_INTEGER, default_val)

	var variant := StoryFlowVariant.new()
	variant.set_int(new_value)
	_set_variable_on_node(node, variant)
	_handle_set_node_end(node, StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_FLOW))


func _handle_set_float(node: Dictionary) -> void:
	var data: Dictionary = node.get("data", {})
	var default_val := 0.0
	var inline_value = data.get("value", null)
	if inline_value is StoryFlowVariant:
		default_val = inline_value.get_float(0.0)
	elif inline_value is float:
		default_val = inline_value

	var new_value := default_val
	if _evaluator:
		new_value = _evaluator.evaluate_float_input(node.get("id", ""), StoryFlowHandles.IN_FLOAT, default_val)

	var variant := StoryFlowVariant.new()
	variant.set_float(new_value)
	_set_variable_on_node(node, variant)
	_handle_set_node_end(node, StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_FLOW))


func _handle_set_string(node: Dictionary) -> void:
	var data: Dictionary = node.get("data", {})
	var inline_value = data.get("value", null)
	var default_val := ""
	if inline_value is StoryFlowVariant:
		default_val = _text.get_string(inline_value.get_string(""), language_code)
	elif inline_value is String:
		default_val = _text.get_string(inline_value, language_code)

	var new_value := default_val
	if _evaluator:
		new_value = _evaluator.evaluate_string_input(node.get("id", ""), StoryFlowHandles.IN_STRING, default_val)

	var variant := StoryFlowVariant.new()
	variant.set_string(new_value)
	_set_variable_on_node(node, variant)
	_handle_set_node_end(node, StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_FLOW))


func _handle_set_enum(node: Dictionary) -> void:
	var data: Dictionary = node.get("data", {})
	var inline_value = data.get("value", null)
	var default_val := ""
	if inline_value is StoryFlowVariant:
		default_val = inline_value.get_string("")
	elif inline_value is String:
		default_val = inline_value

	var new_value := default_val
	if _evaluator:
		new_value = _evaluator.evaluate_enum_input(node.get("id", ""), StoryFlowHandles.IN_ENUM, default_val)

	var variant := StoryFlowVariant.new()
	variant.set_enum(new_value)
	_set_variable_on_node(node, variant)
	_handle_set_node_end(node, StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_FLOW))

# =============================================================================
# Node Handlers - Logic (no-op, evaluated lazily)
# =============================================================================

func _handle_logic_node(node: Dictionary) -> void:
	_process_next_node(StoryFlowHandles.source(node["id"]))

# =============================================================================
# Node Handlers - Enum / Random
# =============================================================================

func _handle_switch_on_enum(node: Dictionary) -> void:
	var data: Dictionary = node.get("data", {})
	var var_id: String = data.get("variable", "")
	var is_global: bool = data.get("isGlobal", false)

	var enum_value := ""
	var variable: Dictionary = _find_variable(var_id, is_global)
	if not variable.is_empty():
		var val = variable.get("value", null)
		if val is StoryFlowVariant:
			enum_value = val.get_string("")

	var source_handle := StoryFlowHandles.source(node["id"], enum_value)
	var edge: Dictionary = _context.current_script.find_connection_by_source_handle(source_handle)
	if not edge.is_empty():
		_process_next_node(source_handle)


func _handle_random_branch(node: Dictionary) -> void:
	var data: Dictionary = node.get("data", {})
	var options: Array = data.get("randomBranchOptions", [])
	if options.size() == 0:
		return

	# Calculate total weight (resolve connected integer handles per option)
	var resolved_weights: Array[int] = []
	var total_weight := 0
	for option in options:
		var option_id: String = option.get("id", "")
		var default_weight: int = option.get("weight", 1)
		var w := default_weight
		if _evaluator:
			w = _evaluator.evaluate_integer_input(node.get("id", ""), "integer-" + option_id, default_weight)
		w = maxi(0, w)
		resolved_weights.append(w)
		total_weight += w

	# If all weights are zero, fall back to first option
	if total_weight <= 0:
		var first_option: Dictionary = options[0]
		var source_handle := StoryFlowHandles.source(node["id"], first_option.get("id", ""))
		var edge: Dictionary = _context.current_script.find_connection_by_source_handle(source_handle)
		if not edge.is_empty():
			_process_next_node(source_handle)
		return

	# Pick a random value in [0, total_weight)
	var roll := randi() % total_weight

	# Find selected option using cumulative weight
	var cumulative := 0
	var selected_index := 0
	for i in range(options.size()):
		cumulative += resolved_weights[i]
		if roll < cumulative:
			selected_index = i
			break

	var selected_option: Dictionary = options[selected_index]
	var source_handle := StoryFlowHandles.source(node["id"], selected_option.get("id", ""))
	var edge: Dictionary = _context.current_script.find_connection_by_source_handle(source_handle)
	if not edge.is_empty():
		_process_next_node(source_handle)

# =============================================================================
# Node Handlers - Array Set
# =============================================================================

func _handle_array_set(node: Dictionary) -> void:
	var data: Dictionary = node.get("data", {})
	var var_id: String = data.get("variable", "")
	var is_global: bool = data.get("isGlobal", false)
	var variable: Dictionary = _find_variable(var_id, is_global)
	if variable.is_empty():
		_handle_set_node_end(node, StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_FLOW))
		return

	var node_type: StoryFlowTypes.NodeType = node.get("type", StoryFlowTypes.NodeType.UNKNOWN)
	var NT := StoryFlowTypes.NodeType

	# Determine if this is a SetArrayElement
	var is_set_element := node_type in [
		NT.SET_BOOL_ARRAY_ELEMENT, NT.SET_INT_ARRAY_ELEMENT, NT.SET_FLOAT_ARRAY_ELEMENT,
		NT.SET_STRING_ARRAY_ELEMENT, NT.SET_IMAGE_ARRAY_ELEMENT,
		NT.SET_CHARACTER_ARRAY_ELEMENT, NT.SET_AUDIO_ARRAY_ELEMENT,
	]

	var val = variable.get("value", null)
	if not val is StoryFlowVariant:
		_handle_set_node_end(node, StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_FLOW))
		return

	var variant: StoryFlowVariant = val

	if is_set_element and _evaluator:
		var inline_value = data.get("value", null)
		var default_index := 0
		if inline_value is StoryFlowVariant:
			default_index = inline_value.get_int(0)
		var idx: int = _evaluator.evaluate_integer_input(node.get("id", ""), StoryFlowHandles.IN_INTEGER, default_index)
		var arr: Array = variant.get_array()
		if idx >= 0 and idx < arr.size():
			var elem: StoryFlowVariant = arr[idx] if arr[idx] is StoryFlowVariant else StoryFlowVariant.new()
			match node_type:
				NT.SET_BOOL_ARRAY_ELEMENT:
					var dv := false
					if inline_value is StoryFlowVariant:
						dv = inline_value.get_bool(false)
					elem.set_bool(_evaluator.evaluate_boolean_input(node.get("id", ""), StoryFlowHandles.IN_BOOLEAN, dv))
				NT.SET_INT_ARRAY_ELEMENT:
					var dv := 0
					if inline_value is StoryFlowVariant:
						dv = inline_value.get_int(0)
					elem.set_int(_evaluator.evaluate_integer_input(node.get("id", ""), StoryFlowHandles.IN_INTEGER_VALUE, dv))
				NT.SET_FLOAT_ARRAY_ELEMENT:
					var dv := 0.0
					if inline_value is StoryFlowVariant:
						dv = inline_value.get_float(0.0)
					elem.set_float(_evaluator.evaluate_float_input(node.get("id", ""), StoryFlowHandles.IN_FLOAT, dv))
				NT.SET_STRING_ARRAY_ELEMENT:
					var dv := ""
					if inline_value is StoryFlowVariant:
						dv = _text.get_string(inline_value.get_string(""), language_code)
					elem.set_string(_evaluator.evaluate_string_input(node.get("id", ""), StoryFlowHandles.IN_STRING, dv))
				_:
					var dv := ""
					if inline_value is StoryFlowVariant:
						dv = inline_value.get_string("")
					elem.set_string(_evaluator.evaluate_string_input(node.get("id", ""), StoryFlowHandles.IN_STRING, dv))
			arr[idx] = elem
	elif not is_set_element and _evaluator:
		# Set whole array from connected input
		var new_array: Array = []
		match node_type:
			NT.SET_BOOL_ARRAY:
				new_array = _evaluator.evaluate_bool_array_input(node.get("id", ""), StoryFlowHandles.IN_BOOL_ARRAY)
			NT.SET_INT_ARRAY:
				new_array = _evaluator.evaluate_int_array_input(node.get("id", ""), StoryFlowHandles.IN_INT_ARRAY)
			NT.SET_FLOAT_ARRAY:
				new_array = _evaluator.evaluate_float_array_input(node.get("id", ""), StoryFlowHandles.IN_FLOAT_ARRAY)
			NT.SET_STRING_ARRAY:
				new_array = _evaluator.evaluate_string_array_input(node.get("id", ""), StoryFlowHandles.IN_STRING_ARRAY)
			NT.SET_IMAGE_ARRAY:
				new_array = _evaluator.evaluate_image_array_input(node.get("id", ""), StoryFlowHandles.IN_IMAGE_ARRAY)
			NT.SET_CHARACTER_ARRAY:
				new_array = _evaluator.evaluate_character_array_input(node.get("id", ""), StoryFlowHandles.IN_CHARACTER_ARRAY)
			NT.SET_AUDIO_ARRAY:
				new_array = _evaluator.evaluate_audio_array_input(node.get("id", ""), StoryFlowHandles.IN_AUDIO_ARRAY)
		variant.set_array(new_array)

	_notify_variable_changed(variable, is_global)
	_handle_set_node_end(node, StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_FLOW))

# =============================================================================
# Node Handlers - Array Modify (add, remove, clear)
# =============================================================================

func _handle_array_modify(node: Dictionary) -> void:
	var data: Dictionary = node.get("data", {})
	var var_id: String = data.get("variable", "")
	var is_global: bool = data.get("isGlobal", false)
	var variable: Dictionary = _find_variable(var_id, is_global)
	if variable.is_empty():
		_handle_set_node_end(node, StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_FLOW))
		return

	var val = variable.get("value", null)
	if not val is StoryFlowVariant:
		_handle_set_node_end(node, StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_FLOW))
		return

	var variant: StoryFlowVariant = val
	var arr: Array = variant.get_array()
	var node_type: StoryFlowTypes.NodeType = node.get("type", StoryFlowTypes.NodeType.UNKNOWN)
	var NT := StoryFlowTypes.NodeType

	var inline_value = data.get("value", null)

	match node_type:
		# Add operations
		NT.ADD_TO_BOOL_ARRAY:
			var dv := false
			if inline_value is StoryFlowVariant:
				dv = inline_value.get_bool(false)
			var elem := StoryFlowVariant.new()
			elem.set_bool(_evaluator.evaluate_boolean_input(node.get("id", ""), StoryFlowHandles.IN_BOOLEAN, dv) if _evaluator else dv)
			arr.append(elem)
		NT.ADD_TO_INT_ARRAY:
			var dv := 0
			if inline_value is StoryFlowVariant:
				dv = inline_value.get_int(0)
			var elem := StoryFlowVariant.new()
			elem.set_int(_evaluator.evaluate_integer_input(node.get("id", ""), StoryFlowHandles.IN_INTEGER, dv) if _evaluator else dv)
			arr.append(elem)
		NT.ADD_TO_FLOAT_ARRAY:
			var dv := 0.0
			if inline_value is StoryFlowVariant:
				dv = inline_value.get_float(0.0)
			var elem := StoryFlowVariant.new()
			elem.set_float(_evaluator.evaluate_float_input(node.get("id", ""), StoryFlowHandles.IN_FLOAT, dv) if _evaluator else dv)
			arr.append(elem)
		NT.ADD_TO_STRING_ARRAY:
			var dv := ""
			if inline_value is StoryFlowVariant:
				dv = _text.get_string(inline_value.get_string(""), language_code)
			var elem := StoryFlowVariant.new()
			elem.set_string(_evaluator.evaluate_string_input(node.get("id", ""), StoryFlowHandles.IN_STRING, dv) if _evaluator else dv)
			arr.append(elem)
		NT.ADD_TO_IMAGE_ARRAY, NT.ADD_TO_CHARACTER_ARRAY, NT.ADD_TO_AUDIO_ARRAY:
			var dv := ""
			if inline_value is StoryFlowVariant:
				dv = inline_value.get_string("")
			var elem := StoryFlowVariant.new()
			elem.set_string(_evaluator.evaluate_string_input(node.get("id", ""), StoryFlowHandles.IN_STRING, dv) if _evaluator else dv)
			arr.append(elem)

		# Remove operations
		NT.REMOVE_FROM_BOOL_ARRAY, NT.REMOVE_FROM_INT_ARRAY, NT.REMOVE_FROM_FLOAT_ARRAY, \
		NT.REMOVE_FROM_STRING_ARRAY, NT.REMOVE_FROM_IMAGE_ARRAY, \
		NT.REMOVE_FROM_CHARACTER_ARRAY, NT.REMOVE_FROM_AUDIO_ARRAY:
			var dv := 0
			if inline_value is StoryFlowVariant:
				dv = inline_value.get_int(0)
			var idx: int = _evaluator.evaluate_integer_input(node.get("id", ""), StoryFlowHandles.IN_INTEGER, dv) if _evaluator else dv
			if idx >= 0 and idx < arr.size():
				arr.remove_at(idx)

		# Clear operations
		NT.CLEAR_BOOL_ARRAY, NT.CLEAR_INT_ARRAY, NT.CLEAR_FLOAT_ARRAY, \
		NT.CLEAR_STRING_ARRAY, NT.CLEAR_IMAGE_ARRAY, \
		NT.CLEAR_CHARACTER_ARRAY, NT.CLEAR_AUDIO_ARRAY:
			arr.clear()

	_notify_variable_changed(variable, is_global)
	_handle_set_node_end(node, StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_FLOW))

# =============================================================================
# Node Handlers - ForEach Loop
# =============================================================================

func _handle_for_each_loop(node: Dictionary) -> void:
	var node_id: String = node["id"]
	var node_state: StoryFlowNodeRuntimeState = _context.get_node_state(node_id)
	var node_type: StoryFlowTypes.NodeType = node.get("type", StoryFlowTypes.NodeType.UNKNOWN)
	var NT := StoryFlowTypes.NodeType

	# Initialize loop on first entry
	if not node_state.loop_initialized:
		var loop_array: Array = []
		if _evaluator:
			match node_type:
				NT.FOR_EACH_BOOL_LOOP:
					loop_array = _evaluator.evaluate_bool_array_input(node.get("id", ""), StoryFlowHandles.IN_BOOL_ARRAY)
				NT.FOR_EACH_INT_LOOP:
					loop_array = _evaluator.evaluate_int_array_input(node.get("id", ""), StoryFlowHandles.IN_INT_ARRAY)
				NT.FOR_EACH_FLOAT_LOOP:
					loop_array = _evaluator.evaluate_float_array_input(node.get("id", ""), StoryFlowHandles.IN_FLOAT_ARRAY)
				NT.FOR_EACH_STRING_LOOP:
					loop_array = _evaluator.evaluate_string_array_input(node.get("id", ""), StoryFlowHandles.IN_STRING_ARRAY)
				NT.FOR_EACH_IMAGE_LOOP:
					loop_array = _evaluator.evaluate_image_array_input(node.get("id", ""), StoryFlowHandles.IN_IMAGE_ARRAY)
				NT.FOR_EACH_CHARACTER_LOOP:
					loop_array = _evaluator.evaluate_character_array_input(node.get("id", ""), StoryFlowHandles.IN_CHARACTER_ARRAY)
				NT.FOR_EACH_AUDIO_LOOP:
					loop_array = _evaluator.evaluate_audio_array_input(node.get("id", ""), StoryFlowHandles.IN_AUDIO_ARRAY)

		node_state.loop_array = loop_array
		node_state.loop_index = 0
		node_state.loop_initialized = true

		# Push loop context
		var loop_frame := StoryFlowLoopFrame.new()
		loop_frame.node_id = node_id
		loop_frame.type = StoryFlowTypes.LoopType.FOR_EACH
		_context.loop_stack.push_back(loop_frame)

	if node_state.loop_index < node_state.loop_array.size():
		# Set current element as cached output
		node_state.cached_output = node_state.loop_array[node_state.loop_index]

		# Execute loop body
		_process_next_node(StoryFlowHandles.source(node_id, StoryFlowHandles.OUT_LOOP_BODY))
	else:
		# Loop complete - cleanup
		node_state.loop_initialized = false
		node_state.loop_array = []
		node_state.cached_output = null

		if _context.loop_stack.size() > 0:
			_context.loop_stack.pop_back()

		# Continue after loop
		_process_next_node(StoryFlowHandles.source(node_id, StoryFlowHandles.OUT_LOOP_COMPLETED))


func _continue_for_each_loop(node_id: String) -> void:
	var loop_node: Dictionary = _context.current_script.get_node(node_id)
	if loop_node.is_empty():
		return

	var node_state: StoryFlowNodeRuntimeState = _context.get_node_state(node_id)
	if not node_state.loop_initialized:
		return

	# Increment loop index
	node_state.loop_index += 1

	# Pop the loop context that was pushed for this iteration
	if _context.loop_stack.size() > 0:
		_context.loop_stack.pop_back()

	# Re-process the loop node to continue
	_process_node(loop_node)

# =============================================================================
# Node Handlers - Media Set
# =============================================================================

func _handle_set_image(node: Dictionary) -> void:
	var data: Dictionary = node.get("data", {})
	var inline_value = data.get("value", null)
	var default_val := ""
	if inline_value is StoryFlowVariant:
		default_val = inline_value.get_string("")
	elif inline_value is String:
		default_val = inline_value

	var new_value := default_val
	if _evaluator:
		new_value = _evaluator.evaluate_string_input(node.get("id", ""), "image", default_val)

	var variant := StoryFlowVariant.new()
	variant.set_string(new_value)
	_set_variable_on_node(node, variant)
	_handle_set_node_end(node, StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_FLOW))


func _handle_set_background_image(node: Dictionary) -> void:
	var data: Dictionary = node.get("data", {})
	var inline_value = data.get("value", null)
	var image_path := ""
	if inline_value is StoryFlowVariant:
		image_path = inline_value.get_string("")
	elif inline_value is String:
		image_path = inline_value

	if _evaluator:
		var edge: Dictionary = _context.current_script.find_input_edge(node["id"], StoryFlowHandles.IN_IMAGE_INPUT)
		if not edge.is_empty():
			var source_node: Dictionary = _context.current_script.get_node(edge.get("source", ""))
			if not source_node.is_empty():
				image_path = _evaluator.evaluate_string_from_node(source_node.get("id", ""), edge.get("source_handle", ""))

	background_image_changed.emit(image_path)
	_handle_set_node_end(node, StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_OUTPUT))


func _handle_set_audio(node: Dictionary) -> void:
	var data: Dictionary = node.get("data", {})
	var inline_value = data.get("value", null)
	var default_val := ""
	if inline_value is StoryFlowVariant:
		default_val = inline_value.get_string("")
	elif inline_value is String:
		default_val = inline_value

	var new_value := default_val
	if _evaluator:
		new_value = _evaluator.evaluate_string_input(node.get("id", ""), "audio", default_val)

	var variant := StoryFlowVariant.new()
	variant.set_string(new_value)
	_set_variable_on_node(node, variant)
	_handle_set_node_end(node, StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_FLOW))


func _handle_play_audio(node: Dictionary) -> void:
	var data: Dictionary = node.get("data", {})
	var inline_value = data.get("value", null)
	var audio_path := ""
	if inline_value is StoryFlowVariant:
		audio_path = inline_value.get_string("")
	elif inline_value is String:
		audio_path = inline_value

	if _evaluator:
		var edge: Dictionary = _context.current_script.find_input_edge(node["id"], StoryFlowHandles.IN_AUDIO_INPUT)
		if not edge.is_empty():
			var source_node: Dictionary = _context.current_script.get_node(edge.get("source", ""))
			if not source_node.is_empty():
				audio_path = _evaluator.evaluate_string_from_node(source_node.get("id", ""), edge.get("source_handle", ""))

	var loop: bool = data.get("audioLoop", false)
	audio_play_requested.emit(audio_path, loop)
	_handle_set_node_end(node, StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_OUTPUT))


func _handle_set_character(node: Dictionary) -> void:
	var data: Dictionary = node.get("data", {})
	var inline_value = data.get("value", null)
	var default_val := ""
	if inline_value is StoryFlowVariant:
		default_val = inline_value.get_string("")
	elif inline_value is String:
		default_val = inline_value

	var new_value := default_val
	if _evaluator:
		new_value = _evaluator.evaluate_string_input(node.get("id", ""), "character", default_val)

	var variant := StoryFlowVariant.new()
	variant.set_string(new_value)
	_set_variable_on_node(node, variant)
	_handle_set_node_end(node, StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_FLOW))

# =============================================================================
# Node Handlers - Character Variables
# =============================================================================

func _handle_set_character_var(node: Dictionary) -> void:
	var data: Dictionary = node.get("data", {})
	var character_path: String = data.get("characterPath", "")
	var variable_name: String = data.get("variableName", "")
	var variable_type: String = data.get("variableType", "")

	# Check for connected character input
	var char_edge: Dictionary = _context.current_script.find_input_edge(node["id"], StoryFlowHandles.IN_CHARACTER_INPUT)
	if not char_edge.is_empty() and _evaluator:
		var char_node: Dictionary = _context.current_script.get_node(char_edge.get("source", ""))
		if not char_node.is_empty():
			character_path = _evaluator.evaluate_string_from_node(char_node.get("id", ""), char_edge.get("source_handle", ""))

	if character_path.is_empty():
		_handle_set_node_end(node, StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_FLOW))
		return

	# Get the value to set
	var new_value := StoryFlowVariant.new()
	var input_handle_suffix := variable_type + "-input"
	var input_edge: Dictionary = _context.current_script.find_input_edge(node["id"], input_handle_suffix)

	if not input_edge.is_empty() and _evaluator:
		var source_node: Dictionary = _context.current_script.get_node(input_edge.get("source", ""))
		if not source_node.is_empty():
			var source_handle: String = input_edge.get("source_handle", "")
			if variable_type == "boolean":
				new_value.set_bool(_evaluator.evaluate_boolean_from_node(source_node.get("id", ""), source_handle))
			elif variable_type == "integer":
				new_value.set_int(_evaluator.evaluate_integer_from_node(source_node.get("id", ""), source_handle))
			elif variable_type == "float":
				new_value.set_float(_evaluator.evaluate_float_from_node(source_node.get("id", ""), source_handle))
			else:
				new_value.set_string(_evaluator.evaluate_string_from_node(source_node.get("id", ""), source_handle))
	else:
		# Use inline value
		var inline_value = data.get("value", null)
		if variable_type == "string":
			var str_key := ""
			if inline_value is StoryFlowVariant:
				str_key = inline_value.get_string("")
			elif inline_value is String:
				str_key = inline_value
			new_value.set_string(_text.get_string(str_key, language_code))
		else:
			if inline_value is StoryFlowVariant:
				new_value = inline_value.duplicate_variant()
			elif inline_value is bool:
				new_value.set_bool(inline_value)
			elif inline_value is int:
				new_value.set_int(inline_value)
			elif inline_value is float:
				new_value.set_float(inline_value)
			elif inline_value is String:
				new_value.set_string(inline_value)

	# Set the character variable via the manager
	var mgr := get_manager()
	if mgr:
		var character: StoryFlowCharacter = mgr.get_runtime_character(character_path)
		if character:
			# Handle built-in "Name" field
			if variable_name.to_lower() == "name":
				character.character_name = new_value.get_string("")
			# Handle built-in "Image" field
			elif variable_name.to_lower() == "image":
				character.image_key = new_value.get_string("")
			# Custom variable
			elif character.variables.has(variable_name):
				character.variables[variable_name]["value"] = new_value

	_handle_set_node_end(node, StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_FLOW))

# =============================================================================
# Set Node End Handling (special no-outgoing-edge behavior)
# =============================================================================

func _handle_set_node_end(node: Dictionary, source_handle: String) -> void:
	# Check if there's an outgoing edge
	var out_edge: Dictionary = _context.current_script.find_connection_by_source_handle(source_handle)
	if not out_edge.is_empty():
		_process_next_node(source_handle)
		return

	# No outgoing edge - check for special cases

	# First: If we're in a forEach loop body, continue the loop
	if _context.loop_stack.size() > 0:
		var loop_frame: StoryFlowLoopFrame = _context.loop_stack.back()
		if loop_frame.type == StoryFlowTypes.LoopType.FOR_EACH:
			_continue_for_each_loop(loop_frame.node_id)
			return

	# Second: If we came from a dialogue via flow edge, go back to re-render it
	var incoming: Array = _context.current_script.find_connections_to_node(node.get("id", ""))
	for conn in incoming:
		var sh: String = conn.get("source_handle", "")
		# Check if this is a flow edge (not a data edge)
		if not StoryFlowHandles.is_data_handle(sh):
			var source_id: String = conn.get("source", "")
			var source_node: Dictionary = _context.current_script.get_node(source_id)
			if not source_node.is_empty() and source_node.get("type", -1) == StoryFlowTypes.NodeType.DIALOGUE:
				_process_node(source_node)
				return

# =============================================================================
# Build Dialogue State
# =============================================================================

func _build_dialogue_state(dialogue_node: Dictionary) -> StoryFlowDialogueState:
	var state := StoryFlowDialogueState.new()
	state.is_valid = true
	state.node_id = dialogue_node.get("id", "")

	var data: Dictionary = dialogue_node.get("data", {})
	var mgr := get_manager()
	var project: StoryFlowProject = mgr.get_project() if mgr else null

	# IMPORTANT: Resolve character FIRST so {Character.Name} interpolation works
	var character_path: String = data.get("character", "")
	if character_path != "" and mgr:
		var character: StoryFlowCharacter = mgr.get_runtime_character(character_path)
		if character:
			var char_data := StoryFlowCharacterData.new()
			char_data.name = _text.get_string(character.character_name, language_code)

			# Resolve character portrait to actual Texture2D
			if character.image_key != "":
				char_data.image = _resolve_image_asset(character.image_key, null, character)

			# Build character variables for interpolation
			for vname in character.variables:
				var v: Dictionary = character.variables[vname]
				var val = v.get("value", null)
				if val is StoryFlowVariant:
					char_data.variables[vname] = val.to_display_string()

			state.character = char_data

	# Update context character for interpolation BEFORE text processing
	# (create a temporary state so _interpolate_text can access character data)
	if not _context.current_dialogue_state:
		_context.current_dialogue_state = StoryFlowDialogueState.new()
	_context.current_dialogue_state.character = state.character

	# Get title and text from string table, then interpolate variables
	var title_key: String = data.get("title", "")
	var text_key: String = data.get("text", "")

	state.title = _text.get_string(title_key, language_code)
	state.text = _text.interpolate(_text.get_string(text_key, language_code))

	# Resolve image asset with persistence logic
	var image_key: String = data.get("image", "")
	if image_key != "":
		state.image_key = image_key
		state.image = _resolve_image_asset(image_key, project, null)
		_context.persistent_image = image_key
	elif data.get("imageReset", false):
		state.image = null
		state.image_key = ""
		_context.persistent_image = ""
	else:
		state.image_key = _context.persistent_image
		if _context.persistent_image != "":
			state.image = _resolve_image_asset(_context.persistent_image, project, null)

	# Resolve audio asset
	var audio_key: String = data.get("audio", "")
	if audio_key != "":
		state.audio_key = audio_key
		state.audio = _audio.resolve_audio_asset(audio_key, _context.current_script, mgr)

	# Build text blocks (non-interactive, always visible)
	var text_blocks_data: Array = data.get("textBlocks", [])
	for block in text_blocks_data:
		var block_text: String = block.get("text", "")
		var tb := StoryFlowTextBlock.new()
		tb.id = block.get("id", "")
		tb.text = _text.interpolate(_text.get_string(block_text, language_code))
		state.text_blocks.append(tb)

	# Build visible options (filtered by once-only and visibility)
	var node_options: Array = data.get("options", [])
	for choice in node_options:
		var choice_id: String = choice.get("id", "")

		# Check once-only
		var once_only_key: String = str(dialogue_node["id"]) + "-" + choice_id
		if choice.get("onceOnly", false):
			if mgr and mgr.is_option_used(once_only_key):
				continue

		# Check visibility
		if _evaluator and not _evaluator.evaluate_option_visibility(choice, dialogue_node.get("id", "")):
			continue

		var option_text: String = choice.get("text", "")
		var opt := StoryFlowDialogueOption.new()
		opt.id = choice_id
		opt.text = _text.interpolate(_text.get_string(option_text, language_code))
		state.options.append(opt)

	# Can advance: node defines ZERO options AND header output handle has an edge
	if node_options.size() == 0:
		var header_handle := StoryFlowHandles.source(dialogue_node["id"])
		var header_edge: Dictionary = _context.current_script.find_connection_by_source_handle(header_handle)
		state.can_advance = not header_edge.is_empty()

	# Audio advance-on-end flags for UI
	var audio_advance: bool = data.get("audioAdvanceOnEnd", false) and not data.get("audioLoop", false)
	state.audio_advance_on_end = audio_advance
	state.audio_allow_skip = audio_advance and data.get("audioAllowSkip", false)

	return state

# =============================================================================
# Variable Helpers
# =============================================================================

func _find_variable_by_display_name(display_name: String) -> Dictionary:
	# Check local first
	var result := _context.find_variable_by_name(display_name)
	if not result.is_empty():
		if result.get("is_global", false):
			# Need to look up from manager
			var mgr := get_manager()
			if mgr:
				var var_id: String = result["id"]
				var globals: Dictionary = mgr.get_global_variables()
				if globals.has(var_id):
					return {"id": var_id, "variable": globals[var_id], "is_global": true}
		else:
			return result
	return {}


func _find_variable(var_id: String, is_global: bool) -> Dictionary:
	if is_global:
		var mgr := get_manager()
		if mgr:
			var globals: Dictionary = mgr.get_global_variables()
			if globals.has(var_id):
				return globals[var_id]
	else:
		if _context.local_variables.has(var_id):
			return _context.local_variables[var_id]
	return {}


func _set_variable_on_node(node: Dictionary, value: StoryFlowVariant) -> void:
	var data: Dictionary = node.get("data", {})
	var var_id: String = data.get("variable", "")
	var is_global: bool = data.get("isGlobal", false)

	if is_global:
		var mgr := get_manager()
		if mgr:
			mgr.set_global_variable(var_id, value)
			var variable: Dictionary = mgr.get_global_variable(var_id)
			if not variable.is_empty():
				_notify_variable_changed(variable, true)
	else:
		if _context.local_variables.has(var_id):
			_context.local_variables[var_id]["value"] = value
			_notify_variable_changed(_context.local_variables[var_id], false)


func _set_variable_from_result(result: Dictionary, value: StoryFlowVariant) -> void:
	var is_global: bool = result.get("is_global", false)
	var var_id: String = result.get("id", "")

	if is_global:
		var mgr := get_manager()
		if mgr:
			mgr.set_global_variable(var_id, value)
			var variable: Dictionary = mgr.get_global_variable(var_id)
			_notify_variable_changed(variable, true)
	else:
		if _context.local_variables.has(var_id):
			_context.local_variables[var_id]["value"] = value
			_notify_variable_changed(_context.local_variables[var_id], false)


# =============================================================================
# Notification Helpers
# =============================================================================

func _notify_variable_changed(variable: Dictionary, is_global: bool) -> void:
	var info := StoryFlowVariableChangeInfo.new()
	info.id = variable.get("id", variable.get("name", ""))
	info.name = variable.get("name", "")
	info.value = variable.get("value", null) as StoryFlowVariant
	info.is_global = is_global
	variable_changed.emit(info)

	# Live variable interpolation: If dialogue is active, re-interpolate text and update UI
	if _context.is_waiting_for_input and _context.current_dialogue_state and _context.current_dialogue_state.is_valid:
		if _is_processing_chain:
			# Defer re-render until the chain finishes
			_dialogue_dirty = true
		else:
			_rebuild_and_emit_dialogue()


func _rebuild_and_emit_dialogue() -> void:
	var dialogue_node_id: String = _context.current_dialogue_state.node_id
	var current_node: Dictionary = _context.current_script.get_node(dialogue_node_id)
	if not current_node.is_empty() and current_node.get("type", -1) == StoryFlowTypes.NodeType.DIALOGUE:
		_context.current_dialogue_state = _build_dialogue_state(current_node)
		dialogue_updated.emit(_context.current_dialogue_state)


func _flush_deferred_dialogue_update() -> void:
	if _dialogue_dirty and _context.is_waiting_for_input and _context.current_dialogue_state and _context.current_dialogue_state.is_valid:
		_rebuild_and_emit_dialogue()
	_dialogue_dirty = false


func _on_dialogue_audio_finished() -> void:
	if _waiting_for_audio_advance:
		_waiting_for_audio_advance = false
		_audio_advance_allow_skip = false
		advance_dialogue()


func _report_error(message: String) -> void:
	push_error("[StoryFlow] %s" % message)
	error_occurred.emit(message)

# =============================================================================
# Asset Resolution
# =============================================================================

func _resolve_image_asset(image_key: String, project: StoryFlowProject, character: StoryFlowCharacter) -> Texture2D:
	# Check character resolved assets first
	if character and character.resolved_assets.has(image_key):
		var res = _try_load_asset(character.resolved_assets, image_key)
		if res is Texture2D:
			return res

	# Check script resolved assets
	if _context.current_script and _context.current_script.resolved_assets.has(image_key):
		var res = _try_load_asset(_context.current_script.resolved_assets, image_key)
		if res is Texture2D:
			return res

	# Check project resolved assets
	if not project:
		var mgr := get_manager()
		if mgr:
			project = mgr.get_project()
	if project and project.resolved_assets.has(image_key):
		var res = _try_load_asset(project.resolved_assets, image_key)
		if res is Texture2D:
			return res

	return null


## Try to get a loaded Resource from the assets dict. If the stored value is a
## string path (fallback from import), load it and cache the result.
func _try_load_asset(assets: Dictionary, key: String) -> Resource:
	var val = assets[key]
	if val is Resource:
		return val
	if val is String and not val.is_empty():
		var loaded = ResourceLoader.load(val)
		if loaded is Resource:
			assets[key] = loaded
			return loaded
	return null
