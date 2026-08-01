class_name StoryFlowComponent
extends Node

# Preloaded by path so parsing never depends on the global class name cache,
# which can be stale or mid-rewrite when the game launches (godotengine/godot#75388).
const StoryFlowAudioController = preload("res://addons/storyflow/core/storyflow_audio_controller.gd")
const StoryFlowCallFrame = preload("res://addons/storyflow/core/storyflow_call_frame.gd")
const StoryFlowCharacter = preload("res://addons/storyflow/core/storyflow_character.gd")
const StoryFlowCharacterData = preload("res://addons/storyflow/core/storyflow_character_data.gd")
const StoryFlowDialogueOption = preload("res://addons/storyflow/core/storyflow_dialogue_option.gd")
const StoryFlowDialogueState = preload("res://addons/storyflow/core/storyflow_dialogue_state.gd")
const StoryFlowEvaluator = preload("res://addons/storyflow/core/storyflow_evaluator.gd")
const StoryFlowExecutionContext = preload("res://addons/storyflow/core/storyflow_execution_context.gd")
const StoryFlowHandles = preload("res://addons/storyflow/core/storyflow_handles.gd")
const StoryFlowLoopFrame = preload("res://addons/storyflow/core/storyflow_loop_frame.gd")
const StoryFlowNodeRuntimeState = preload("res://addons/storyflow/core/storyflow_node_runtime_state.gd")
const StoryFlowProject = preload("res://addons/storyflow/core/storyflow_project.gd")
const StoryFlowScript = preload("res://addons/storyflow/core/storyflow_script.gd")
const StoryFlowTextBlock = preload("res://addons/storyflow/core/storyflow_text_block.gd")
const StoryFlowTextInterpolator = preload("res://addons/storyflow/core/storyflow_text_interpolator.gd")
const StoryFlowTypes = preload("res://addons/storyflow/core/storyflow_types.gd")
const StoryFlowVariableChangeInfo = preload("res://addons/storyflow/core/storyflow_variable_change_info.gd")
const StoryFlowVariant = preload("res://addons/storyflow/core/storyflow_variant.gd")

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

## Optional parent for the dialogue UI; overrides type-based routing when set.
@export_node_path("Node") var dialogue_ui_parent: NodePath = NodePath()

@export_group("Debug")

## Enable execution trace logging for cross-runtime comparison.
## Output format: [SF-TRACE] <event type> <details>
@export var trace_enabled: bool = true

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
signal dialogue_tag_reached(tag: String)
signal variable_changed(info: StoryFlowVariableChangeInfo)
signal character_variable_changed(character_path: String, variable_name: String, value: StoryFlowVariant)
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
var _dialogue_ui_instance: Node = null
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
	_evaluator.initialize(_context, mgr.get_global_variables(), mgr.get_runtime_characters(), language_code, project.global_strings)
	_evaluator.set_trace(_sf_trace)

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
		var ui_root: Node = ui_scene.instantiate()
		if ui_root:
			if ui_root.has_method("initialize_with_component"):
				ui_root.call("initialize_with_component", self)
			_dialogue_ui_instance = ui_root
			var ui_parent: Node = _resolve_dialogue_ui_parent(ui_root)
			ui_parent.add_child(ui_root)
		else:
			push_warning("StoryFlow: failed to instantiate dialogue UI scene for '%s'" % path)

	# Broadcast start events
	dialogue_started.emit()
	script_started.emit(path)

	# Find start node and begin execution
	var start_node: Dictionary = script_asset.get_start_node()
	if not start_node.is_empty():
		_process_node(start_node)
	else:
		_report_error("Start node (id=0) not found in script")


## Resolve the node the dialogue UI attaches under, routed by the UI root's type.
## Worldspace UIs parent to the component's CanvasItem/Node3D parent (a sibling
## of the entity's visuals) so they inherit the entity transform.
func _resolve_dialogue_ui_parent(ui_root: Node) -> Node:
	# Explicit override wins when it resolves to a valid node.
	if not dialogue_ui_parent.is_empty():
		var override := get_node_or_null(dialogue_ui_parent)
		if override:
			return override
		push_warning("StoryFlow: dialogue_ui_parent '%s' did not resolve; falling back to type-based routing" % dialogue_ui_parent)

	# Control UIs render in screen space; keep today's behavior (child of self).
	if ui_root is Control:
		return self

	var parent := get_parent()

	# 2D worldspace UI: sibling of the entity's CanvasItem visuals.
	if ui_root is Node2D:
		if parent is CanvasItem:
			return parent
		push_warning("StoryFlow: Node2D dialogue UI has no CanvasItem parent; it will not follow the entity transform")
		return self

	# 3D worldspace UI: sibling under the entity's Node3D.
	if ui_root is Node3D:
		if parent is Node3D:
			return parent
		push_warning("StoryFlow: Node3D dialogue UI has no Node3D parent; it will not follow the entity transform")
		return self

	return self


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
		return _resolve_string(val.get_string())
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

## Read a variable that lives on a character.
##
## Built-in fields are handled symmetrically:
##   "Name"  → returns the localized display name (string-table key resolved).
##   "Image" → returns the current portrait asset key.
## Any other name resolves through the character's custom variables map.
## Returns an empty StoryFlowVariant if the character or variable is missing.
func get_character_variable(character_path: String, variable_name: String) -> StoryFlowVariant:
	var mgr := get_manager()
	if not mgr:
		return StoryFlowVariant.new()
	var character: StoryFlowCharacter = mgr.get_runtime_character(character_path)
	if not character:
		return StoryFlowVariant.new()

	# Handle built-in "Name" field (stored as string-table key, resolve it)
	if variable_name.to_lower() == "name":
		return StoryFlowVariant.from_string(_resolve_string(character.character_name))

	# Handle built-in "Image" field (current portrait asset key)
	if variable_name.to_lower() == "image":
		return StoryFlowVariant.from_string(character.image_key)

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


## Return the live runtime character object for a path.
## Useful when you want to read several fields without separate variable calls.
## Returns null if no character is registered at that path.
func get_character(character_path: String) -> StoryFlowCharacter:
	var mgr := get_manager()
	if not mgr:
		return null
	return mgr.get_runtime_character(character_path)


## Return the names of all custom variables defined on a character.
## Does not include the built-in "Name" and "Image" fields, which are always
## available via [method get_character_variable] regardless of declaration.
func get_character_variables(character_path: String) -> Array[String]:
	var out: Array[String] = []
	var mgr := get_manager()
	if not mgr:
		return out
	var character: StoryFlowCharacter = mgr.get_runtime_character(character_path)
	if not character:
		return out
	for var_name in character.variables:
		out.append(str(var_name))
	return out


## Resolve a character's portrait to a Texture2D.
## When [param asset_key] is empty (default), uses the character's current
## image_key, which reflects any runtime mutations from setCharacterVar("Image", ...).
## Pass a non-empty asset_key to resolve an alternate pose, e.g. one stored in a
## custom image-typed character variable.
## Walks the standard three asset pools in priority order: character → script → project.
## Returns null if nothing resolves.
func get_character_portrait(character_path: String, asset_key: String = "") -> Texture2D:
	var mgr := get_manager()
	if not mgr:
		return null
	var character: StoryFlowCharacter = mgr.get_runtime_character(character_path)
	if not character:
		return null
	var key := asset_key if not asset_key.is_empty() else character.image_key
	if key.is_empty():
		return null
	return _resolve_image_asset(key, mgr.get_project(), character)


# =============================================================================
# Array Variable Access
# =============================================================================

## Read a script or global variable of type character-array.
##
## Returns the array of character paths stored in the variable. Each path is
## suitable for [method get_character], [method get_character_variable], or
## [method get_character_portrait]. Returns an empty array if the variable is
## missing or is not a character array.
##
## Note: this reads a *script variable whose element type is character*, which
## is distinct from [method get_character_variable], which reads a variable
## that lives *on* a character.
func get_character_array_variable(variable_name: String) -> Array[String]:
	var out: Array[String] = []
	var result := _find_variable_by_display_name(variable_name)
	if result.is_empty():
		return out
	var v: Dictionary = result["variable"]
	if not v.get("is_array", false):
		push_warning("StoryFlow: Variable '%s' is not an array" % variable_name)
		return out
	if v.get("type", -1) != StoryFlowTypes.VariableType.CHARACTER:
		push_warning("StoryFlow: Variable '%s' is not a character array" % variable_name)
		return out
	var val = v.get("value", null)
	if not (val is StoryFlowVariant):
		return out
	var arr: Array = val.get_array()
	for elem in arr:
		if elem is StoryFlowVariant:
			out.append(elem.get_string(""))
	return out


## Read any array variable by display name.
##
## Returns the elements as StoryFlowVariant copies so callers can use the typed
## getters (get_bool, get_int, get_float, get_string). String and enum element
## values are routed through the string table, so callers receive localized
## text rather than raw keys. Image, audio, and character elements are stored
## as plain strings (asset keys / paths) so they pass through unchanged.
## Returns an empty array if the variable is missing or is not an array.
func get_array_variable(variable_name: String) -> Array[StoryFlowVariant]:
	var out: Array[StoryFlowVariant] = []
	var result := _find_variable_by_display_name(variable_name)
	if result.is_empty():
		return out
	var v: Dictionary = result["variable"]
	if not v.get("is_array", false):
		push_warning("StoryFlow: Variable '%s' is not an array" % variable_name)
		return out
	var val = v.get("value", null)
	if not (val is StoryFlowVariant):
		return out
	var arr: Array = val.get_array()
	for elem in arr:
		if not (elem is StoryFlowVariant):
			continue
		var copy: StoryFlowVariant = elem.duplicate_variant()
		if copy.type == StoryFlowTypes.VariableType.STRING:
			copy.set_string(_resolve_string(copy.get_string("")))
		elif copy.type == StoryFlowTypes.VariableType.ENUM:
			copy.set_enum(_resolve_string(copy.get_string("")))
		out.append(copy)
	return out


## Write a boolean array variable by display name.
##
## Replaces the variable's elements and emits [signal variable_changed], like
## the scalar setters; if a dialogue is currently showing, its text re-renders
## with the new values. Searches local script variables first (during
## dialogue), then globals. Mirrors the Unity and Unreal plugins'
## Set*ArrayVariable API.
func set_bool_array_variable(variable_name: String, values: Array[bool]) -> void:
	var elements: Array = []
	for value in values:
		elements.append(StoryFlowVariant.from_bool(value))
	_apply_array_variable(variable_name, elements)


## Write an integer array variable by display name. See
## [method set_bool_array_variable] for the shared rules.
func set_int_array_variable(variable_name: String, values: Array[int]) -> void:
	var elements: Array = []
	for value in values:
		elements.append(StoryFlowVariant.from_int(value))
	_apply_array_variable(variable_name, elements)


## Write a float array variable by display name. See
## [method set_bool_array_variable] for the shared rules.
func set_float_array_variable(variable_name: String, values: Array[float]) -> void:
	var elements: Array = []
	for value in values:
		elements.append(StoryFlowVariant.from_float(value))
	_apply_array_variable(variable_name, elements)


## Write a string array variable by display name. Elements are stored
## verbatim — no string-table key is created, so they are language-locked and
## bypass localization. See [method set_bool_array_variable] for the shared
## rules.
func set_string_array_variable(variable_name: String, values: Array[String]) -> void:
	var elements: Array = []
	for value in values:
		elements.append(StoryFlowVariant.from_string(value))
	_apply_array_variable(variable_name, elements)


## Write an enum array variable by display name. Values are enum option
## strings; they are stored verbatim without validation against the variable's
## option list. See [method set_bool_array_variable] for the shared rules.
func set_enum_array_variable(variable_name: String, values: Array[String]) -> void:
	var elements: Array = []
	for value in values:
		elements.append(StoryFlowVariant.from_enum(value))
	_apply_array_variable(variable_name, elements)


## Write an image array variable by display name. Each entry is an asset key
## resolvable through the standard asset pools. Stored as plain strings,
## matching how imported arrays hold their elements. See
## [method set_bool_array_variable] for the shared rules.
func set_image_array_variable(variable_name: String, asset_keys: Array[String]) -> void:
	var elements: Array = []
	for key in asset_keys:
		elements.append(StoryFlowVariant.from_string(key))
	_apply_array_variable(variable_name, elements)


## Write an audio array variable by display name. Each entry is an asset key.
## See [method set_bool_array_variable] for the shared rules.
func set_audio_array_variable(variable_name: String, asset_keys: Array[String]) -> void:
	var elements: Array = []
	for key in asset_keys:
		elements.append(StoryFlowVariant.from_string(key))
	_apply_array_variable(variable_name, elements)


## Write a character array variable by display name. Each entry is a character
## path. See [method set_bool_array_variable] for the shared rules.
func set_character_array_variable(variable_name: String, character_paths: Array[String]) -> void:
	var elements: Array = []
	for path in character_paths:
		elements.append(StoryFlowVariant.from_string(path))
	_apply_array_variable(variable_name, elements)


## Shared tail of the set_*_array_variable family: find the variable, replace
## its value with an array variant, and notify (which also live-refreshes the
## current dialogue, like every variable change).
func _apply_array_variable(variable_name: String, elements: Array) -> void:
	var result := _find_variable_by_display_name(variable_name)
	if result.is_empty():
		return
	_set_variable_from_result(result, StoryFlowVariant.from_array(elements))


## Read any map variable by display name.
##
## Returns a Dictionary of key -> StoryFlowVariant value, in insertion order.
## Keys are raw int (integer key type) or String (string/enum key types) and
## are NEVER routed through the string table — the runtime-wide map rule:
## values localize, keys are identifiers. String and enum VALUES are resolved
## through the string table like [method get_array_variable] elements; image,
## audio, and character values pass through unchanged (asset keys / paths).
##
## The returned Dictionary and its values are COPIES, never the live storage:
## map variables can share storage with each other (setMap aliasing), so
## handing out the live Dictionary would let game code corrupt every aliased
## variable at once. Returns an empty Dictionary if the variable is missing
## or is not a map.
func get_map_variable(variable_name: String) -> Dictionary:
	var out := {}
	var result := _find_variable_by_display_name(variable_name)
	if result.is_empty():
		return out
	var v: Dictionary = result["variable"]
	if v.get("type", -1) != StoryFlowTypes.VariableType.MAP:
		push_warning("StoryFlow: Variable '%s' is not a map" % variable_name)
		return out
	var val = v.get("value", null)
	if not (val is StoryFlowVariant):
		return out
	var map: Dictionary = val.get_map()
	for key in map:
		var entry = map[key]
		if not (entry is StoryFlowVariant):
			continue
		var copy: StoryFlowVariant = entry.duplicate_variant()
		if copy.type == StoryFlowTypes.VariableType.STRING:
			copy.set_string(_resolve_string(copy.get_string("")))
		elif copy.type == StoryFlowTypes.VariableType.ENUM:
			copy.set_enum(_resolve_string(copy.get_string("")))
		out[key] = copy
	return out


# =============================================================================
# Typed Map Variable Access (by display name)
# =============================================================================
# Game-facing typed get/set for map variables, following the set_*_array_variable
# family above. The full key-type x value-type matrix collapses to NATIVE Godot
# types: enum keys are strings and string/enum/image/audio/character values are
# strings, leaving 2 key families (String, int) x 4 value families
# (bool, int, float, String) = 8 get/set signatures.
#
# Rules:
#   - KEYS are returned RAW — never routed through the string table. The
#     runtime-wide map rule is "values localize, keys are identifiers".
#   - String and enum VALUES resolve through the string table, like
#     get_array_variable / get_map_variable elements.
#   - Image / audio / character VALUES pass through RAW (asset keys / paths).
#   - Getters unwrap StoryFlowVariant to native values and return a COPY of the
#     map (map variables can share storage via setMap aliasing). Setters wrap
#     native values back into StoryFlowVariant and reuse _notify_variable_changed
#     so a live dialogue re-renders.
#   - A missing / non-map / wrong-key-family / wrong-value-family variable
#     pushes a warning and yields an empty Dictionary (getters) or a no-op
#     (setters), like the array helpers.
#
# No separate get_map_keys_in_order helper is needed: Dictionary.keys() is
# already in insertion order, which is the contractual map ordering, so the
# typed getters' keys() carry it directly.

# String-keyed map signatures accept STRING or ENUM key types (enum keys are
# stored as String). Int-keyed signatures accept INTEGER. The value family
# arrays say which variant types a signature accepts and returns natively.
const _MAP_KEY_FAMILY_STRING: Array = [
	StoryFlowTypes.VariableType.STRING, StoryFlowTypes.VariableType.ENUM,
]
const _MAP_KEY_FAMILY_INT: Array = [StoryFlowTypes.VariableType.INTEGER]
const _MAP_VALUE_FAMILY_BOOL: Array = [StoryFlowTypes.VariableType.BOOLEAN]
const _MAP_VALUE_FAMILY_INT: Array = [StoryFlowTypes.VariableType.INTEGER]
const _MAP_VALUE_FAMILY_FLOAT: Array = [StoryFlowTypes.VariableType.FLOAT]
# string/enum/image/audio/character all serialize to String storage
const _MAP_VALUE_FAMILY_STRING: Array = [
	StoryFlowTypes.VariableType.STRING, StoryFlowTypes.VariableType.ENUM,
	StoryFlowTypes.VariableType.IMAGE, StoryFlowTypes.VariableType.AUDIO,
	StoryFlowTypes.VariableType.CHARACTER,
]


## Read a String-keyed, boolean-valued map. See the section header for rules.
func get_string_to_bool_map(variable_name: String, is_global: bool = false) -> Dictionary:
	return _get_native_map(variable_name, is_global, _MAP_KEY_FAMILY_STRING, _MAP_VALUE_FAMILY_BOOL)


## Read a String-keyed, integer-valued map.
func get_string_to_int_map(variable_name: String, is_global: bool = false) -> Dictionary:
	return _get_native_map(variable_name, is_global, _MAP_KEY_FAMILY_STRING, _MAP_VALUE_FAMILY_INT)


## Read a String-keyed, float-valued map.
func get_string_to_float_map(variable_name: String, is_global: bool = false) -> Dictionary:
	return _get_native_map(variable_name, is_global, _MAP_KEY_FAMILY_STRING, _MAP_VALUE_FAMILY_FLOAT)


## Read a String-keyed, String-valued map. Covers string, enum, image, audio,
## and character value types; string/enum values are localized, asset values
## are returned raw.
func get_string_to_string_map(variable_name: String, is_global: bool = false) -> Dictionary:
	return _get_native_map(variable_name, is_global, _MAP_KEY_FAMILY_STRING, _MAP_VALUE_FAMILY_STRING)


## Read an int-keyed, boolean-valued map.
func get_int_to_bool_map(variable_name: String, is_global: bool = false) -> Dictionary:
	return _get_native_map(variable_name, is_global, _MAP_KEY_FAMILY_INT, _MAP_VALUE_FAMILY_BOOL)


## Read an int-keyed, integer-valued map.
func get_int_to_int_map(variable_name: String, is_global: bool = false) -> Dictionary:
	return _get_native_map(variable_name, is_global, _MAP_KEY_FAMILY_INT, _MAP_VALUE_FAMILY_INT)


## Read an int-keyed, float-valued map.
func get_int_to_float_map(variable_name: String, is_global: bool = false) -> Dictionary:
	return _get_native_map(variable_name, is_global, _MAP_KEY_FAMILY_INT, _MAP_VALUE_FAMILY_FLOAT)


## Read an int-keyed, String-valued map (string/enum/image/audio/character).
func get_int_to_string_map(variable_name: String, is_global: bool = false) -> Dictionary:
	return _get_native_map(variable_name, is_global, _MAP_KEY_FAMILY_INT, _MAP_VALUE_FAMILY_STRING)


## Write a String-keyed, boolean-valued map. Replaces all entries and notifies
## (live-refreshing any active dialogue), like the array setters.
func set_string_to_bool_map(variable_name: String, values: Dictionary, is_global: bool = false) -> void:
	_apply_map_variable(variable_name, values, is_global, _MAP_KEY_FAMILY_STRING, _MAP_VALUE_FAMILY_BOOL)


## Write a String-keyed, integer-valued map.
func set_string_to_int_map(variable_name: String, values: Dictionary, is_global: bool = false) -> void:
	_apply_map_variable(variable_name, values, is_global, _MAP_KEY_FAMILY_STRING, _MAP_VALUE_FAMILY_INT)


## Write a String-keyed, float-valued map.
func set_string_to_float_map(variable_name: String, values: Dictionary, is_global: bool = false) -> void:
	_apply_map_variable(variable_name, values, is_global, _MAP_KEY_FAMILY_STRING, _MAP_VALUE_FAMILY_FLOAT)


## Write a String-keyed, String-valued map. Values are stored verbatim as the
## variable's declared value type (string/enum/image/audio/character); strings
## bypass localization (no string-table key is created), matching the array
## setters.
func set_string_to_string_map(variable_name: String, values: Dictionary, is_global: bool = false) -> void:
	_apply_map_variable(variable_name, values, is_global, _MAP_KEY_FAMILY_STRING, _MAP_VALUE_FAMILY_STRING)


## Write an int-keyed, boolean-valued map.
func set_int_to_bool_map(variable_name: String, values: Dictionary, is_global: bool = false) -> void:
	_apply_map_variable(variable_name, values, is_global, _MAP_KEY_FAMILY_INT, _MAP_VALUE_FAMILY_BOOL)


## Write an int-keyed, integer-valued map.
func set_int_to_int_map(variable_name: String, values: Dictionary, is_global: bool = false) -> void:
	_apply_map_variable(variable_name, values, is_global, _MAP_KEY_FAMILY_INT, _MAP_VALUE_FAMILY_INT)


## Write an int-keyed, float-valued map.
func set_int_to_float_map(variable_name: String, values: Dictionary, is_global: bool = false) -> void:
	_apply_map_variable(variable_name, values, is_global, _MAP_KEY_FAMILY_INT, _MAP_VALUE_FAMILY_FLOAT)


## Write an int-keyed, String-valued map (string/enum/image/audio/character).
func set_int_to_string_map(variable_name: String, values: Dictionary, is_global: bool = false) -> void:
	_apply_map_variable(variable_name, values, is_global, _MAP_KEY_FAMILY_INT, _MAP_VALUE_FAMILY_STRING)


# -----------------------------------------------------------------------------
# Typed map helpers (shared by the 16 functions above)
# -----------------------------------------------------------------------------

## Shared body of the typed map getters: find + validate the variable against
## the expected key/value families, then unwrap each entry to a native value
## (string/enum values localized, everything else raw). Returns a COPY; an
## invalid variable yields an empty Dictionary (warning already pushed).
func _get_native_map(variable_name: String, is_global: bool, key_family: Array, value_family: Array) -> Dictionary:
	var out := {}
	var result := _find_map_variable_for_access(variable_name, is_global, key_family, value_family)
	if result.is_empty():
		return out
	var v: Dictionary = result["variable"]
	var val = v.get("value", null)
	if not (val is StoryFlowVariant):
		return out
	var map: Dictionary = val.get_map()
	for key in map:
		var entry = map[key]
		if not (entry is StoryFlowVariant):
			continue
		out[key] = _unwrap_map_value(entry)
	return out


## Unwrap a value variant to a native GDScript value. String and enum values
## route through the string table (localized like get_map_variable); image,
## audio, and character values are returned raw; bool/int/float pass through.
func _unwrap_map_value(entry: StoryFlowVariant):
	match entry.type:
		StoryFlowTypes.VariableType.BOOLEAN:
			return entry.get_bool()
		StoryFlowTypes.VariableType.INTEGER:
			return entry.get_int()
		StoryFlowTypes.VariableType.FLOAT:
			return entry.get_float()
		StoryFlowTypes.VariableType.STRING, StoryFlowTypes.VariableType.ENUM:
			return _resolve_string(entry.get_string(""))
		_:
			# image / audio / character store an asset key / path as a String;
			# return it untouched (no localization).
			return entry.get_string("")


## Shared tail of the typed map setters: find + validate, wrap each native value
## into a StoryFlowVariant typed per the variable's declared value type, then
## set + notify (live-refreshing the current dialogue). A wrong/missing variable
## is a no-op (warning already pushed).
func _apply_map_variable(variable_name: String, values: Dictionary, is_global: bool, key_family: Array, value_family: Array) -> void:
	var result := _find_map_variable_for_access(variable_name, is_global, key_family, value_family)
	if result.is_empty():
		return
	var v: Dictionary = result["variable"]
	var value_type: int = v.get("value_type", StoryFlowTypes.VariableType.NONE)
	var entries := {}
	for key in values:
		entries[key] = _wrap_map_value(values[key], value_type)
	_set_variable_from_result(result, StoryFlowVariant.from_map(entries))


## Wrap a native value into a StoryFlowVariant typed as the variable's declared
## value type, so the stored entry round-trips and interpolates correctly. The
## inverse of _unwrap_map_value: image/audio/character are stored as plain
## String variants, matching how the importer holds them.
func _wrap_map_value(value, value_type: int) -> StoryFlowVariant:
	match value_type:
		StoryFlowTypes.VariableType.BOOLEAN:
			return StoryFlowVariant.from_bool(value)
		StoryFlowTypes.VariableType.INTEGER:
			return StoryFlowVariant.from_int(value)
		StoryFlowTypes.VariableType.FLOAT:
			return StoryFlowVariant.from_float(value)
		StoryFlowTypes.VariableType.ENUM:
			return StoryFlowVariant.from_enum(str(value))
		_:
			# string / image / audio / character all serialize to a String variant
			return StoryFlowVariant.from_string(str(value))


## Find a map variable for the typed accessors and validate its shape: scope the
## lookup by is_global, require the variable to exist, be a MAP, and have a
## key_type/value_type in the requested native families. Pushes a warning and
## returns {} on any mismatch; otherwise returns the _find_variable_by_display_name
## result dict.
func _find_map_variable_for_access(variable_name: String, is_global: bool, key_family: Array, value_family: Array) -> Dictionary:
	var result := _find_map_scoped(variable_name, is_global)
	if result.is_empty():
		return {}
	var v: Dictionary = result["variable"]
	if v.get("type", -1) != StoryFlowTypes.VariableType.MAP:
		push_warning("StoryFlow: Variable '%s' is not a map" % variable_name)
		return {}
	if not key_family.has(v.get("key_type", StoryFlowTypes.VariableType.NONE)):
		push_warning("StoryFlow: Map variable '%s' has a different key type than requested" % variable_name)
		return {}
	if not value_family.has(v.get("value_type", StoryFlowTypes.VariableType.NONE)):
		push_warning("StoryFlow: Map variable '%s' has a different value type than requested" % variable_name)
		return {}
	return result


## Resolve a variable by display name, honoring the is_global selector. When
## is_global is true the lookup is restricted to globals; otherwise it uses the
## default locals-then-globals scoping of _find_variable_by_display_name.
func _find_map_scoped(variable_name: String, is_global: bool) -> Dictionary:
	if not is_global:
		return _find_variable_by_display_name(variable_name)
	var mgr := get_manager()
	if mgr:
		var globals: Dictionary = mgr.get_global_variables()
		for var_id in globals:
			var v: Dictionary = globals[var_id]
			if v.get("name", "") == variable_name:
				return {"id": var_id, "variable": v, "is_global": true}
	push_warning("StoryFlow: Global variable '%s' not found" % variable_name)
	return {}


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
	return _resolve_string(key)

# =============================================================================
# Trace Logging
# =============================================================================

func _sf_trace(msg: String) -> void:
	if trace_enabled:
		print("[SF-TRACE] " + msg)


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
		NT.PLUS, NT.MINUS, NT.MULTIPLY, NT.DIVIDE, NT.MODULO, NT.RANDOM,
		NT.GREATER_THAN_FLOAT, NT.GREATER_THAN_OR_EQUAL_FLOAT,
		NT.LESS_THAN_FLOAT, NT.LESS_THAN_OR_EQUAL_FLOAT, NT.EQUAL_FLOAT,
		NT.PLUS_FLOAT, NT.MINUS_FLOAT, NT.MULTIPLY_FLOAT, NT.DIVIDE_FLOAT, NT.MODULO_FLOAT, NT.RANDOM_FLOAT,
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

	# Map variable handlers
	_node_handlers[NT.SET_MAP] = _handle_set_map
	var map_modify_handler := _handle_map_modify
	for t in [NT.SET_MAP_VALUE, NT.REMOVE_MAP_KEY, NT.CLEAR_MAP]:
		_node_handlers[t] = map_modify_handler

	# Map pure reads (evaluated lazily on data pull; handler only routes exec)
	var map_pure_handler := _handle_map_pure_node
	for t in [NT.GET_MAP, NT.GET_MAP_VALUE, NT.HAS_MAP_KEY, NT.MAP_SIZE, NT.MAP_KEYS, NT.MAP_VALUES]:
		_node_handlers[t] = map_pure_handler

	# Map entry iteration (snapshot-at-init semantics — see _handle_for_each_map)
	_node_handlers[NT.FOR_EACH_MAP] = _handle_for_each_map

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
	# Trace parity: the HTML runtime never processes start nodes — every entry
	# point (initial load, runScript, flows) follows the edge out of "0" and
	# processes its TARGET directly, so HTML traces contain no start hop. Godot
	# routes through the start node; suppress its NODE line (and the matching
	# EDGE line in _process_next_node) so traces diff 1:1 against the
	# map-trace-fixture. The wire-name (type_string) is traced, not the
	# SCREAMING enum key — the fixture pins e.g. "setMapValue".
	if node_type != StoryFlowTypes.NodeType.START:
		_sf_trace("NODE %s %s" % [node.get("id", ""), node.get("type_string", "")])

	if _node_handlers.has(node_type):
		var handler: Callable = _node_handlers[node_type]
		handler.call(node)
	else:
		# Unknown node type - log and follow default output so newer scripts
		# do not freeze on plugin versions that predate the node type.
		push_warning("StoryFlow: Unsupported node type '%s' at node %s, skipping" % [node.get("type_string", ""), node.get("id", "")])
		_process_next_node(StoryFlowHandles.source(node.get("id", "")))

	_context.processing_depth -= 1


func _process_next_node(source_handle: String) -> void:
	var edge: Dictionary = _context.current_script.find_connection_by_source_handle(source_handle)
	if edge.is_empty():
		return

	var target_id: String = edge.get("target", "")
	var source_node_id: String = edge.get("source", "")
	# Trace parity: suppress the edge OUT of a start node — the HTML runtime
	# follows it without tracing (see the matching NODE gate in _process_node).
	var edge_source_node: Dictionary = _context.current_script.get_node(source_node_id)
	if edge_source_node.get("type", -1) != StoryFlowTypes.NodeType.START:
		_sf_trace("EDGE %s:%s -> %s" % [source_node_id, source_handle, target_id])

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

		# Gather output variable values from the called script (by name for mapping).
		# Map-typed outputs DETACH (duplicate_variant deep-copies the entries):
		# the callee's live variant may alias other storage (setMap), and the
		# HTML runtime converts _outputValues entry arrays to a fresh Map at the
		# read site — the call boundary is observably a snapshot both ways.
		var output_by_name: Dictionary = {}
		for var_id in _context.local_variables:
			var v: Dictionary = _context.local_variables[var_id]
			if v.get("is_output", false):
				var var_name: String = v.get("name", "")
				if not var_name.is_empty():
					var out_val = v.get("value", null)
					if out_val is StoryFlowVariant and out_val.is_map():
						out_val = out_val.duplicate_variant()
					output_by_name[var_name] = out_val

		# Pop call stack
		var frame: StoryFlowCallFrame = _context.call_stack.pop_back()
		var ended_script_path := ""
		if _context.current_script:
			ended_script_path = _context.current_script.script_path
		_sf_trace('SCRIPT RETURN "%s"' % ended_script_path)
		script_ended.emit(ended_script_path)

		if frame.script_asset:
			_context.current_script = frame.script_asset
			_context.local_variables = frame.saved_variables
			_context.build_variable_name_index(_context.local_variables, false)

			# Restore flow call stack
			_context.flow_call_stack = frame.saved_flow_stack.duplicate()

			# Map output values using the RunScript node's scriptOutputs.
			# Edge handles use scriptInterface output IDs, not variable IDs.
			# We match by name: scriptOutputs entry name ↔ variable name.
			var output_values: Dictionary = {}
			if output_by_name.size() > 0:
				var rs_node: Dictionary = _context.current_script.get_node(frame.return_node_id)
				var rs_data: Dictionary = rs_node.get("data", {})
				var si_outputs: Array = rs_data.get("scriptOutputs", [])
				for out_entry in si_outputs:
					if out_entry is Dictionary:
						var out_id: String = out_entry.get("id", "")
						var out_name: String = out_entry.get("name", "")
						if not out_id.is_empty() and output_by_name.has(out_name):
							output_values[out_id] = output_by_name[out_name]
				# Also store by variable name as fallback
				for var_name in output_by_name:
					output_values[var_name] = output_by_name[var_name]

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

	_sf_trace("BRANCH %s condition=%s" % [node.get("id", ""), str(condition).to_lower()])

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

	var data: Dictionary = node.get("data", {})

	# Handle dialogue background image (three-state logic matching HTML runtime):
	#   Has image → emit background_image_changed with the image key
	#   No image + imageReset=true → emit with empty string to clear
	#   No image + imageReset=false → do nothing (previous background persists)
	var dialogue_image_key: String = data.get("image", "")
	if dialogue_image_key != "":
		_sf_trace('IMAGE "%s"' % dialogue_image_key)
		background_image_changed.emit(dialogue_image_key)
	elif data.get("imageReset", false):
		_sf_trace('IMAGE ""')
		background_image_changed.emit("")

	# Handle dialogue audio only on fresh entry
	if is_fresh_entry and _audio:
		if _context.current_dialogue_state.audio:
			var audio_loop: bool = data.get("audioLoop", false)
			_sf_trace('AUDIO "%s"' % _context.current_dialogue_state.audio_key)
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

	# Snapshot the tags BEFORE any event fires — a handler bound to dialogue_updated
	# (not just the tag event) may synchronously stop_dialogue(), nulling
	# current_dialogue_state under us.
	var tags_snapshot: Array = _context.current_dialogue_state.tags.duplicate() if is_fresh_entry else []

	# Broadcast update
	dialogue_updated.emit(_context.current_dialogue_state)

	# Fire dialogue tags — presentation cues emitted once per tag, in authored
	# order, but ONLY on a fresh entry into this node. Returning here to re-render
	# (e.g. after a Set* node) is not a fresh entry, so tags do not re-fire.
	#
	# Re-entrancy contract: a handler may synchronously advance/select/stop/restart
	# the dialogue. The entered node's tag list is snapshot BEFORE any event fires,
	# and the whole snapshot fires even if a handler transitions mid-loop (this may
	# interleave with the next node's events, which is accepted). dialogue_updated
	# is emitted FIRST above so the current node's update is never lost or emitted
	# from a swapped context.
	for tag in tags_snapshot:
		_sf_trace('TAG "%s"' % tag)
		dialogue_tag_reached.emit(tag)

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
			var is_array: bool = param.get("isArray", false)

			if is_array:
				# Array parameters use "{type}-array-param-{id}" handle suffix
				var handle_suffix := param_type + "-array-param-" + param_id
				if _context.current_script.find_input_edge(node["id"], handle_suffix).is_empty():
					continue
				var arr: Array = []
				match param_type:
					"boolean": arr = _evaluator.evaluate_bool_array_input(node.get("id", ""), handle_suffix)
					"integer": arr = _evaluator.evaluate_int_array_input(node.get("id", ""), handle_suffix)
					"float": arr = _evaluator.evaluate_float_array_input(node.get("id", ""), handle_suffix)
					"string": arr = _evaluator.evaluate_string_array_input(node.get("id", ""), handle_suffix)
					"image": arr = _evaluator.evaluate_image_array_input(node.get("id", ""), handle_suffix)
					"character": arr = _evaluator.evaluate_character_array_input(node.get("id", ""), handle_suffix)
					"audio": arr = _evaluator.evaluate_audio_array_input(node.get("id", ""), handle_suffix)
				var variant := StoryFlowVariant.new()
				variant.set_array(arr)
				param_values[param_name] = variant
			else:
				# Scalar parameters use "{type}-param-{id}" handle suffix
				var handle_suffix := param_type + "-param-" + param_id
				if _context.current_script.find_input_edge(node["id"], handle_suffix).is_empty():
					continue

				if param_type == "map":
					# Map parameters resolve by EXPLICIT handle ("map-param-{id}"):
					# the editor's scriptInterface carries no key/value types for
					# map params, so unlike map op handles none are baked into the
					# handle ID. Maps cross the call boundary BY VALUE (HTML's
					# getTypedInput hands over `new Map(...)`): snapshot the
					# entries so the callee's variable never aliases the caller's.
					# Wired-but-unresolved passes an empty map (HTML's getMapInput
					# empty-Map fallback); from_map types the variant explicitly.
					var map_result: Dictionary = _evaluator.resolve_map_input_by_handle(node, handle_suffix)
					var source_map = map_result.get("map")
					var entries: Dictionary = {}
					if source_map is Dictionary:
						entries = _snapshot_map_entries(source_map)
					param_values[param_name] = StoryFlowVariant.from_map(entries)
				elif param_type == "boolean":
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

	# Push current state. saved_variables intentionally SHARES the live local
	# records (the HTML runtime's call frames save gameState.variables.slice(),
	# i.e. live variable references): map aliasing established before a
	# runScript call must survive the call and restore — a deep copy here would
	# detach aliased map storage. The called script REASSIGNS
	# _context.local_variables below, so the saved Dictionary is never mutated
	# during the call.
	var call_frame := StoryFlowCallFrame.new()
	call_frame.script_path = _context.current_script.script_path if _context.current_script else ""
	call_frame.return_node_id = node["id"]
	call_frame.script_asset = _context.current_script
	call_frame.saved_variables = _context.local_variables
	call_frame.saved_flow_stack = _context.flow_call_stack.duplicate()
	_context.call_stack.push_back(call_frame)

	_sf_trace('SCRIPT CALL "%s"' % target_script_path)

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

	_sf_trace('SCRIPT CALL "%s"' % flow_id)

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
	# Data node — just continue. No VAR GET trace here: the HTML runtime emits
	# VAR GET on data-pull EVALUATION of get/set variable nodes (see the
	# evaluator arms), never when a get node sits in the exec chain.
	_process_next_node(StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_BOOLEAN))


func _handle_get_int(node: Dictionary) -> void:
	# No VAR GET trace — see _handle_get_bool
	_process_next_node(StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_INTEGER))


func _handle_get_float(node: Dictionary) -> void:
	# No VAR GET trace — see _handle_get_bool
	_process_next_node(StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_FLOAT))


func _handle_get_string(node: Dictionary) -> void:
	# No VAR GET trace — see _handle_get_bool
	_process_next_node(StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_STRING))


func _handle_get_enum(node: Dictionary) -> void:
	# No VAR GET trace — see _handle_get_bool
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
	var var_name := _get_variable_name_from_node(node)
	var is_global: bool = data.get("isGlobal", false)
	_sf_trace('VAR SET "%s" global=%s value=%s' % [var_name, str(is_global).to_lower(), str(new_value).to_lower()])
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
	var var_name := _get_variable_name_from_node(node)
	var is_global: bool = data.get("isGlobal", false)
	_sf_trace('VAR SET "%s" global=%s value=%s' % [var_name, str(is_global).to_lower(), str(new_value)])
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
	var var_name := _get_variable_name_from_node(node)
	var is_global: bool = data.get("isGlobal", false)
	_sf_trace('VAR SET "%s" global=%s value=%s' % [var_name, str(is_global).to_lower(), str(new_value)])
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
	var var_name := _get_variable_name_from_node(node)
	var is_global: bool = data.get("isGlobal", false)
	_sf_trace('VAR SET "%s" global=%s value=%s' % [var_name, str(is_global).to_lower(), new_value])
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
	var var_name := _get_variable_name_from_node(node)
	var is_global: bool = data.get("isGlobal", false)
	_sf_trace('VAR SET "%s" global=%s value=%s' % [var_name, str(is_global).to_lower(), new_value])
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
		# The export dialect renames set*ArrayElement's inline fallbacks: the .sfe "index"
		# is exported as "value1" and "value" as "value2" (json-export-strategy.ts; the
		# importer parses both at _parse_node_data). add/remove ops use plain "value".
		var inline_index = data.get("value1", null)
		var inline_value = data.get("value2", null)
		var default_index := 0
		if inline_index is StoryFlowVariant:
			default_index = inline_index.get_int(0)
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

	var _arr_var_name: String = variable.get("name", var_id)
	_sf_trace('VAR SET "%s" global=%s value=%s' % [_arr_var_name, str(is_global).to_lower(), variant.to_display_string()])
	_notify_variable_changed(variable, is_global)
	_handle_set_node_end(node, StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_FLOW))

# =============================================================================
# Node Handlers - Array Modify (add, remove, clear)
# =============================================================================

func _handle_array_modify(node: Dictionary) -> void:
	var data: Dictionary = node.get("data", {})
	var node_id: String = node.get("id", "")
	var node_type: StoryFlowTypes.NodeType = node.get("type", StoryFlowTypes.NodeType.UNKNOWN)
	var NT := StoryFlowTypes.NodeType

	# Determine the array handle suffix based on element type (matches HTML runtime's '{type}-array-2')
	var array_handle_suffix: String = _get_array_handle_suffix(node_type)

	# Get the array via the input edge (same as HTML's getArrayInput)
	var arr: Array = []
	if _evaluator and not array_handle_suffix.is_empty():
		arr = _evaluator.evaluate_string_array_input(node_id, array_handle_suffix)
		# Use type-specific evaluator based on element type
		match node_type:
			NT.ADD_TO_BOOL_ARRAY, NT.REMOVE_FROM_BOOL_ARRAY, NT.CLEAR_BOOL_ARRAY:
				arr = _evaluator.evaluate_bool_array_input(node_id, StoryFlowHandles.IN_BOOL_ARRAY)
			NT.ADD_TO_INT_ARRAY, NT.REMOVE_FROM_INT_ARRAY, NT.CLEAR_INT_ARRAY:
				arr = _evaluator.evaluate_int_array_input(node_id, StoryFlowHandles.IN_INT_ARRAY)
			NT.ADD_TO_FLOAT_ARRAY, NT.REMOVE_FROM_FLOAT_ARRAY, NT.CLEAR_FLOAT_ARRAY:
				arr = _evaluator.evaluate_float_array_input(node_id, StoryFlowHandles.IN_FLOAT_ARRAY)
			NT.ADD_TO_STRING_ARRAY, NT.REMOVE_FROM_STRING_ARRAY, NT.CLEAR_STRING_ARRAY:
				arr = _evaluator.evaluate_string_array_input(node_id, StoryFlowHandles.IN_STRING_ARRAY)
			NT.ADD_TO_IMAGE_ARRAY, NT.REMOVE_FROM_IMAGE_ARRAY, NT.CLEAR_IMAGE_ARRAY:
				arr = _evaluator.evaluate_image_array_input(node_id, StoryFlowHandles.IN_IMAGE_ARRAY)
			NT.ADD_TO_CHARACTER_ARRAY, NT.REMOVE_FROM_CHARACTER_ARRAY, NT.CLEAR_CHARACTER_ARRAY:
				arr = _evaluator.evaluate_character_array_input(node_id, StoryFlowHandles.IN_CHARACTER_ARRAY)
			NT.ADD_TO_AUDIO_ARRAY, NT.REMOVE_FROM_AUDIO_ARRAY, NT.CLEAR_AUDIO_ARRAY:
				arr = _evaluator.evaluate_audio_array_input(node_id, StoryFlowHandles.IN_AUDIO_ARRAY)

	var inline_value = data.get("value", null)

	match node_type:
		# Add operations
		NT.ADD_TO_BOOL_ARRAY:
			var dv := false
			if inline_value is StoryFlowVariant:
				dv = inline_value.get_bool(false)
			elif inline_value is bool:
				dv = inline_value
			var elem := StoryFlowVariant.new()
			elem.set_bool(_evaluator.evaluate_boolean_input(node_id, StoryFlowHandles.IN_BOOLEAN, dv) if _evaluator else dv)
			arr.append(elem)
		NT.ADD_TO_INT_ARRAY:
			var dv := 0
			if inline_value is StoryFlowVariant:
				dv = inline_value.get_int(0)
			elif inline_value is int or inline_value is float:
				dv = int(inline_value)
			var elem := StoryFlowVariant.new()
			elem.set_int(_evaluator.evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER, dv) if _evaluator else dv)
			arr.append(elem)
		NT.ADD_TO_FLOAT_ARRAY:
			var dv := 0.0
			if inline_value is StoryFlowVariant:
				dv = inline_value.get_float(0.0)
			elif inline_value is int or inline_value is float:
				dv = float(inline_value)
			var elem := StoryFlowVariant.new()
			elem.set_float(_evaluator.evaluate_float_input(node_id, StoryFlowHandles.IN_FLOAT, dv) if _evaluator else dv)
			arr.append(elem)
		NT.ADD_TO_STRING_ARRAY:
			var dv := ""
			if inline_value is StoryFlowVariant:
				var raw: String = inline_value.get_string("")
				dv = _resolve_string(raw)
			elif inline_value is String:
				dv = _resolve_string(inline_value)
			var eval_result: String = _evaluator.evaluate_string_input(node_id, StoryFlowHandles.IN_STRING, dv) if _evaluator else dv
			# If evaluator returned empty but we have a resolved default, use the default
			# (the input edge may evaluate a localization key that the string evaluator can't resolve)
			if eval_result.is_empty() and not dv.is_empty():
				eval_result = dv
			var elem := StoryFlowVariant.new()
			elem.set_string(eval_result)
			arr.append(elem)
		NT.ADD_TO_IMAGE_ARRAY, NT.ADD_TO_CHARACTER_ARRAY, NT.ADD_TO_AUDIO_ARRAY:
			var dv := ""
			if inline_value is StoryFlowVariant:
				dv = inline_value.get_string("")
			elif inline_value is String:
				dv = inline_value
			var elem := StoryFlowVariant.new()
			elem.set_string(_evaluator.evaluate_string_input(node_id, StoryFlowHandles.IN_STRING, dv) if _evaluator else dv)
			arr.append(elem)

		# Remove operations
		NT.REMOVE_FROM_BOOL_ARRAY, NT.REMOVE_FROM_INT_ARRAY, NT.REMOVE_FROM_FLOAT_ARRAY, \
		NT.REMOVE_FROM_STRING_ARRAY, NT.REMOVE_FROM_IMAGE_ARRAY, \
		NT.REMOVE_FROM_CHARACTER_ARRAY, NT.REMOVE_FROM_AUDIO_ARRAY:
			var dv := 0
			if inline_value is StoryFlowVariant:
				dv = inline_value.get_int(0)
			var idx: int = _evaluator.evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER, dv) if _evaluator else dv
			if idx >= 0 and idx < arr.size():
				arr.remove_at(idx)

		# Clear operations
		NT.CLEAR_BOOL_ARRAY, NT.CLEAR_INT_ARRAY, NT.CLEAR_FLOAT_ARRAY, \
		NT.CLEAR_STRING_ARRAY, NT.CLEAR_IMAGE_ARRAY, \
		NT.CLEAR_CHARACTER_ARRAY, NT.CLEAR_AUDIO_ARRAY:
			arr.clear()

	# Store the result array on this node's cached output (matches HTML's setNodeOutputValue).
	# Downstream nodes connected to this array modify node's output can read the result.
	var result_variant := StoryFlowVariant.new()
	result_variant.set_array(arr)
	var node_state := _context.get_node_state(node_id)
	node_state.cached_output = result_variant

	# Write back: trace the array input edge to find the source variable and update it
	# (matches HTML runtime's updateConnectedArrayVariable)
	_update_connected_array_variable(node, array_handle_suffix, arr)

	_handle_set_node_end(node, StoryFlowHandles.source(node_id, StoryFlowHandles.OUT_FLOW))


## Trace the array input edge back to the source node to find and update the variable.
## Matches HTML runtime's updateConnectedArrayVariable(node, handleSuffix, newArray).
func _update_connected_array_variable(node: Dictionary, array_handle_suffix: String, new_array: Array) -> void:
	if not _context or not _context.current_script:
		return
	var node_id: String = node.get("id", "")
	var edge := _context.current_script.find_input_edge(node_id, array_handle_suffix)
	if edge.is_empty():
		return

	var source_id: String = edge.get("source", "")
	var source_node := _context.current_script.get_node(source_id)
	if source_node.is_empty():
		return

	var source_data: Dictionary = source_node.get("data", {})
	var source_type: StoryFlowTypes.NodeType = source_node.get("type", StoryFlowTypes.NodeType.UNKNOWN)

	# Handle character variable arrays
	if source_type == StoryFlowTypes.NodeType.GET_CHARACTER_VAR or source_type == StoryFlowTypes.NodeType.SET_CHARACTER_VAR:
		var char_path: String = source_data.get("characterPath", "")
		var var_name: String = source_data.get("variableName", "")
		var mgr := get_manager()
		if mgr and not char_path.is_empty() and not var_name.is_empty():
			var character: StoryFlowCharacter = mgr.get_runtime_character(char_path)
			if character and character.variables.has(var_name):
				var cv: Dictionary = character.variables[var_name]
				var val = cv.get("value", null)
				if val is StoryFlowVariant:
					val.set_array(new_array)
					_sf_trace('VAR SET "%s.%s" global=true value=[%d elements]' % [char_path, var_name, new_array.size()])
		return

	# Handle local/global script variable arrays
	var is_global: bool = source_data.get("isGlobal", false)
	var var_name: String = source_data.get("variableName", "")
	if var_name.is_empty():
		var_name = source_data.get("variable", "")

	# Find the variable by name in the appropriate scope
	if is_global:
		var mgr := get_manager()
		if mgr:
			var globals: Dictionary = mgr.get_global_variables()
			for gid in globals:
				var gv: Dictionary = globals[gid]
				if gv.get("name", "") == var_name:
					var val = gv.get("value", null)
					if val is StoryFlowVariant:
						val.set_array(new_array)
						_sf_trace('VAR SET "%s" global=true value=[%d elements]' % [var_name, new_array.size()])
						_notify_variable_changed(gv, true)
					return
	else:
		for lid in _context.local_variables:
			var lv: Dictionary = _context.local_variables[lid]
			if lv.get("name", "") == var_name:
				var val = lv.get("value", null)
				if val is StoryFlowVariant:
					val.set_array(new_array)
					_sf_trace('VAR SET "%s" global=false value=[%d elements]' % [var_name, new_array.size()])
					_notify_variable_changed(lv, false)
				return


## Get the array input handle suffix for a given array modify node type.
func _get_array_handle_suffix(node_type: StoryFlowTypes.NodeType) -> String:
	var NT := StoryFlowTypes.NodeType
	match node_type:
		NT.ADD_TO_BOOL_ARRAY, NT.REMOVE_FROM_BOOL_ARRAY, NT.CLEAR_BOOL_ARRAY:
			return StoryFlowHandles.IN_BOOL_ARRAY
		NT.ADD_TO_INT_ARRAY, NT.REMOVE_FROM_INT_ARRAY, NT.CLEAR_INT_ARRAY:
			return StoryFlowHandles.IN_INT_ARRAY
		NT.ADD_TO_FLOAT_ARRAY, NT.REMOVE_FROM_FLOAT_ARRAY, NT.CLEAR_FLOAT_ARRAY:
			return StoryFlowHandles.IN_FLOAT_ARRAY
		NT.ADD_TO_STRING_ARRAY, NT.REMOVE_FROM_STRING_ARRAY, NT.CLEAR_STRING_ARRAY:
			return StoryFlowHandles.IN_STRING_ARRAY
		NT.ADD_TO_IMAGE_ARRAY, NT.REMOVE_FROM_IMAGE_ARRAY, NT.CLEAR_IMAGE_ARRAY:
			return StoryFlowHandles.IN_IMAGE_ARRAY
		NT.ADD_TO_CHARACTER_ARRAY, NT.REMOVE_FROM_CHARACTER_ARRAY, NT.CLEAR_CHARACTER_ARRAY:
			return StoryFlowHandles.IN_CHARACTER_ARRAY
		NT.ADD_TO_AUDIO_ARRAY, NT.REMOVE_FROM_AUDIO_ARRAY, NT.CLEAR_AUDIO_ARRAY:
			return StoryFlowHandles.IN_AUDIO_ARRAY
	return ""

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

	if node_state.loop_index < node_state.loop_array.size():
		# Clear evaluation caches from previous iteration so boolean chains re-evaluate
		_context.clear_cached_outputs()

		# Restore cached outputs for all active outer loops (nested forEach support)
		for frame in _context.loop_stack:
			var outer_state := _context.get_node_state(frame.node_id)
			if outer_state.loop_initialized and outer_state.loop_index < outer_state.loop_array.size():
				outer_state.cached_output = outer_state.loop_array[outer_state.loop_index]

		# Set current element as cached output
		node_state.cached_output = node_state.loop_array[node_state.loop_index]

		var _loop_element: StoryFlowVariant = node_state.loop_array[node_state.loop_index]
		_sf_trace("LOOP %s index=%d value=%s" % [node_id, node_state.loop_index, _loop_element.to_display_string() if _loop_element else "null"])

		# Push loop context for this iteration
		var loop_frame := StoryFlowLoopFrame.new()
		loop_frame.node_id = node_id
		loop_frame.type = StoryFlowTypes.LoopType.FOR_EACH
		_context.loop_stack.push_back(loop_frame)

		# Execute loop body
		_process_next_node(StoryFlowHandles.source(node_id, StoryFlowHandles.OUT_LOOP_BODY))
	else:
		# Loop complete - cleanup
		node_state.loop_initialized = false
		node_state.loop_array = []
		node_state.cached_output = null

		if _context.loop_stack.size() > 0 and _context.loop_stack.back().node_id == node_id:
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
	if _context.loop_stack.size() > 0 and _context.loop_stack.back().node_id == node_id:
		_context.loop_stack.pop_back()

	# Re-process the loop node to continue
	_process_node(loop_node)

# =============================================================================
# Node Handlers - Map Variables
# =============================================================================

func _handle_set_map(node: Dictionary) -> void:
	# Mirrors the HTML runtime's setMap → updateMapVariable: resolve the wired
	# map input ("2") and ALIAS the bound variable's storage to the origin
	# variable's live Dictionary — set_map() stores the REFERENCE, so after
	# setMap(b ← chain from getMap(a)) a later clearMap(a) also empties b.
	# Copy-on-set would break the cross-runtime aliasing pin.
	var data: Dictionary = node.get("data", {})
	var var_id: String = data.get("variable", "")
	var is_global: bool = data.get("isGlobal", false)
	var flow_handle := StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_FLOW)

	var variable: Dictionary = _find_variable(var_id, is_global)
	var val = variable.get("value", null)
	if variable.is_empty() or variable.get("type", -1) != StoryFlowTypes.VariableType.MAP or not (val is StoryFlowVariant):
		# HTML returns early without trace/dispatch but still continues exec
		_handle_set_node_end(node, flow_handle)
		return

	var variant: StoryFlowVariant = val
	var key_type: String = str(data.get("keyType", ""))
	var value_type: String = str(data.get("valueType", ""))

	# Missing K/V types: the map input handle cannot be built — behave as
	# disconnected (keep the current value, still trace and dispatch).
	# Informational divergence: HTML falls back to the bound variable's own
	# keyType/valueType to build the handle here; Godot treats the node as
	# disconnected instead. Unreachable via real editor exports (catalog map
	# nodes always carry keyType/valueType in node data).
	if _evaluator and not key_type.is_empty() and not value_type.is_empty():
		var handle_suffix := StoryFlowHandles.in_map(key_type, value_type, "2")
		var edge: Dictionary = _context.current_script.find_input_edge(node["id"], handle_suffix)
		if not edge.is_empty():
			var map_result: Dictionary = _evaluator.resolve_map_input(node, "2")
			var kind: String = map_result.get("kind", "")
			var source_map = map_result.get("map")
			if source_map is Dictionary:
				if kind == StoryFlowEvaluator.MAP_SOURCE_CHARACTER_VAR or kind == StoryFlowEvaluator.MAP_SOURCE_RUN_SCRIPT:
					# Read-only-terminal chain (charvar or runScript output):
					# HTML's setMap SNAPSHOTS the entries into a fresh Map —
					# never aliases live charvar/runScript storage. Entry
					# values are deep-duplicated to fully detach the copy.
					variant.set_map(_snapshot_map_entries(source_map))
				else:
					# Wired and resolved: share the origin variable's live
					# Dictionary. set_map stores the reference — this IS the alias.
					variant.set_map(source_map)
			else:
				# Wired but unresolved: HTML assigns a fresh empty Map
				variant.set_map({})
		# No edge: keep the current value (maps have no inline fallback)

	# Trace shape pinned by the cross-runtime fixture: size=, not value=
	_sf_trace('VAR SET "%s" global=%s size=%d' % [variable.get("name", var_id), str(is_global).to_lower(), variant.get_map().size()])
	_notify_variable_changed(variable, is_global)
	_handle_set_node_end(node, flow_handle)


func _handle_map_modify(node: Dictionary) -> void:
	# setMapValue / removeMapKey / clearMap — one handler, three ops (mirrors
	# the HTML runtime's map mutator handlers). Mutates the ORIGIN variable's
	# live map Dictionary IN PLACE so every alias observes the change, then
	# fires the variable's change notification the way the array write-back
	# does. NOTE: HTML mutators emit NO "VAR SET" trace line — only setMap does
	# (see the map-trace-fixture) — so none is emitted here.
	var data: Dictionary = node.get("data", {})
	var node_type: StoryFlowTypes.NodeType = node.get("type", StoryFlowTypes.NodeType.UNKNOWN)
	var flow_handle := StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_FLOW)

	# Missing K/V types: HTML skips the mutation but still continues exec
	if not _evaluator or str(data.get("keyType", "")).is_empty() or str(data.get("valueType", "")).is_empty():
		_handle_set_node_end(node, flow_handle)
		return

	# Resolve ALL non-map inputs FIRST, THEN the live map: key (input "3"), and
	# for setMapValue the typed value (input "4" with the inline fallback).
	# The HTML runtime actually resolves the map FIRST — this key/value-first
	# order mirrors the Unreal port's pointer-lifetime rule (no eval may run
	# between resolving the live map and mutating it) and is observably
	# equivalent: key/value evaluations cannot change which map resolves.
	var key = null
	if node_type != StoryFlowTypes.NodeType.CLEAR_MAP:
		key = _evaluator.evaluate_map_op_key_input(node, "3")

	var new_value: StoryFlowVariant = null
	if node_type == StoryFlowTypes.NodeType.SET_MAP_VALUE:
		new_value = _evaluator.evaluate_map_op_value_input(node, "4")

	var map_result: Dictionary = _evaluator.resolve_map_input(node, "2")
	var kind: String = map_result.get("kind", "")
	var map = map_result.get("map")
	if not (map is Dictionary):
		# Unresolved map: HTML mutates a throwaway empty Map — no effect, no
		# dispatch. Silent no-op is HTML parity; leave a verbose breadcrumb.
		print_verbose("StoryFlow: Map mutator node %s could not resolve its map input - mutation skipped" % node.get("id", ""))
		_handle_set_node_end(node, flow_handle)
		return

	if kind == StoryFlowEvaluator.MAP_SOURCE_CHARACTER_VAR or kind == StoryFlowEvaluator.MAP_SOURCE_RUN_SCRIPT:
		# Read-only-terminal chain (charvar or runScript output): HTML hands the
		# mutator a THROWAWAY fresh Map — the stored variable is observably
		# unchanged and no variable-change dispatch fires. Skip mutation AND
		# notify (observable no-op): use setCharacterVar to write charvars.
		print_verbose("StoryFlow: Map mutator node %s resolves to a read-only map source (character variable or runScript output) - mutation skipped" % node.get("id", ""))
		_handle_set_node_end(node, flow_handle)
		return

	match node_type:
		StoryFlowTypes.NodeType.SET_MAP_VALUE:
			# Godot Dictionaries keep an existing key's position on overwrite
			# and append new keys — exactly JS Map insertion-order semantics.
			map[key] = new_value
		StoryFlowTypes.NodeType.REMOVE_MAP_KEY:
			map.erase(key)
		StoryFlowTypes.NodeType.CLEAR_MAP:
			# In-place clear ON THE LIVE Dictionary — deliberate and contractual:
			# aliases created by setMap must observe the wipe (the fixture pins
			# clearMap(inv) emptying the aliased inv2). Do NOT reassign here.
			map.clear()

	var origin_variable: Dictionary = map_result.get("variable", {})
	if not origin_variable.is_empty():
		_notify_variable_changed(origin_variable, map_result.get("is_global", false))
	_handle_set_node_end(node, flow_handle)


func _handle_map_pure_node(node: Dictionary) -> void:
	# Pure map reads are evaluated lazily on data pull (map reads are never
	# memoized — see the evaluator). This handler only routes exec, mirroring
	# the HTML handlers' continuation handles: getMapValue flows on via its
	# typed value output; hasMapKey/mapSize via their typed data outputs.
	# getMap (no exec ports — HTML registers no handler) and mapKeys/mapValues
	# (HTML handlers end without processNextNode) dead-end deliberately.
	var node_type: StoryFlowTypes.NodeType = node.get("type", StoryFlowTypes.NodeType.UNKNOWN)
	var data: Dictionary = node.get("data", {})
	match node_type:
		StoryFlowTypes.NodeType.GET_MAP_VALUE:
			var value_type: String = str(data.get("valueType", ""))
			if value_type.is_empty():
				value_type = "string"
			_process_next_node(StoryFlowHandles.source(node["id"], "%s-value" % value_type))
		StoryFlowTypes.NodeType.HAS_MAP_KEY:
			_process_next_node(StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_BOOLEAN))
		StoryFlowTypes.NodeType.MAP_SIZE:
			_process_next_node(StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_INTEGER))
		_:
			pass


func _handle_for_each_map(node: Dictionary) -> void:
	# Mirrors the HTML runtime's processForEachMap: iterate map entries (key +
	# value) in insertion order. Entries are SNAPSHOT once at loop init — body
	# mutations (even removeMapKey of the current key) land on the live map but
	# neither skip, repeat, nor extend iteration. _continue_for_each_loop
	# re-enters here via the dispatch table (it reuses loop_index/
	# loop_initialized).
	var node_id: String = node["id"]
	var data: Dictionary = node.get("data", {})

	# Missing K/V types: the map input handle cannot be built — HTML follows
	# "completed" immediately with zero iterations (and no LOOP trace).
	if str(data.get("keyType", "")).is_empty() or str(data.get("valueType", "")).is_empty():
		_process_next_node(StoryFlowHandles.source(node_id, StoryFlowHandles.OUT_LOOP_COMPLETED))
		return

	var node_state: StoryFlowNodeRuntimeState = _context.get_node_state(node_id)

	# Initialize loop on first entry: resolve the live map (input "map") and
	# snapshot its entries immediately into parallel key/value arrays. An
	# empty or unresolved map yields zero iterations.
	if not node_state.loop_initialized:
		var keys: Array = []
		var values: Array = []
		if _evaluator:
			var map_result: Dictionary = _evaluator.resolve_map_input(node, "map")
			var map = map_result.get("map")
			if map is Dictionary:
				for k in map:
					keys.append(k)
					values.append(map[k])
		node_state.loop_keys = keys
		node_state.loop_values = values
		node_state.loop_index = 0
		node_state.loop_initialized = true

	if node_state.loop_index < node_state.loop_keys.size():
		# Clear evaluation caches from previous iteration so boolean chains
		# re-evaluate. loop_key/loop_value live outside the cache and survive.
		_context.clear_cached_outputs()

		# Restore cached outputs for all active outer ARRAY loops (nested
		# forEach support — mirrors _handle_for_each_loop). Outer MAP loops need
		# no restore: their loop_key/loop_value are not wiped by the cache clear.
		for frame in _context.loop_stack:
			var outer_state := _context.get_node_state(frame.node_id)
			if outer_state.loop_initialized and outer_state.loop_index < outer_state.loop_array.size():
				outer_state.cached_output = outer_state.loop_array[outer_state.loop_index]

		# Expose the current entry's key/value (read by the typed evaluators
		# via the "-key"/"-value" source handle suffixes)
		node_state.loop_key = node_state.loop_keys[node_state.loop_index]
		var entry_value = node_state.loop_values[node_state.loop_index]
		node_state.loop_value = entry_value if entry_value is StoryFlowVariant else null

		var value_str: String = node_state.loop_value.to_display_string() if node_state.loop_value else ""
		_sf_trace("LOOP %s index=%d key=%s value=%s" % [node_id, node_state.loop_index, str(node_state.loop_key), value_str])

		# Push loop context for this iteration
		var loop_frame := StoryFlowLoopFrame.new()
		loop_frame.node_id = node_id
		loop_frame.type = StoryFlowTypes.LoopType.FOR_EACH
		_context.loop_stack.push_back(loop_frame)

		# Execute loop body
		_process_next_node(StoryFlowHandles.source(node_id, StoryFlowHandles.OUT_LOOP_BODY))
	else:
		# Loop complete - cleanup all loop state
		node_state.loop_initialized = false
		node_state.loop_keys = []
		node_state.loop_values = []
		node_state.loop_key = null
		node_state.loop_value = null
		node_state.cached_output = null

		if _context.loop_stack.size() > 0 and _context.loop_stack.back().node_id == node_id:
			_context.loop_stack.pop_back()

		# Continue after loop
		_process_next_node(StoryFlowHandles.source(node_id, StoryFlowHandles.OUT_LOOP_COMPLETED))


## Deep-duplicate a map's entries into a fresh Dictionary (per-value
## duplicate_variant copy). Used wherever a map crosses a snapshot boundary
## (setMap from read-only sources, setCharacterVar map writes).
func _snapshot_map_entries(source_map: Dictionary) -> Dictionary:
	var snapshot := {}
	for k in source_map:
		var entry = source_map[k]
		snapshot[k] = entry.duplicate_variant() if entry is StoryFlowVariant else entry
	return snapshot


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

	_sf_trace('IMAGE "%s"' % new_value)
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

	_sf_trace('IMAGE "%s"' % image_path)
	# Persist image for subsequent dialogues and resolve while still in the
	# correct script context (asset IDs are per-file, so cross-script lookups
	# would fail without the cached texture).
	_context.persistent_image = image_path
	if image_path != "":
		_context.persistent_image_texture = _resolve_image_asset(image_path, null, null)
	else:
		_context.persistent_image_texture = null
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

	_sf_trace('AUDIO "%s"' % new_value)
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

	_sf_trace('AUDIO "%s"' % audio_path)
	var loop: bool = data.get("audioLoop", false)
	# Resolve and play the audio (same as dialogue audio handling)
	if _audio and audio_path != "":
		var mgr := get_manager()
		var stream: AudioStream = _audio.resolve_audio_asset(audio_path, _context.current_script, mgr)
		if stream:
			_audio.play(stream, loop)
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
	var var_name := _get_variable_name_from_node(node)
	var is_global: bool = data.get("isGlobal", false)
	_sf_trace('VAR SET "%s" global=%s value=%s' % [var_name, str(is_global).to_lower(), new_value])
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

	# Map-typed character variables take a dedicated path: resolve the wired map
	# input (optionId "input") and SNAPSHOT it into the character's own storage —
	# an independent deep copy, never an alias of the source variable's live map
	# (HTML parity: updateCharacterVariable stores the serialized entry-array form).
	if variable_type == "map":
		# Missing K/V types: the map input handle cannot be built — HTML
		# short-circuits with NO write (and no trace), but exec still continues.
		if str(data.get("keyType", "")).is_empty() or str(data.get("valueType", "")).is_empty():
			_handle_set_node_end(node, StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_FLOW))
			return

		# Unwired or unresolved → empty (HTML defaults the new value to a fresh Map)
		var snapshot: Dictionary = {}
		if _evaluator:
			var map_result: Dictionary = _evaluator.resolve_map_input(node, "input")
			var source_map = map_result.get("map")
			if source_map is Dictionary:
				snapshot = _snapshot_map_entries(source_map)

		# Trace shape matches the map pin on _handle_set_map (size=, not value=).
		# HTML traces before the write gate — trace-then-gate order is parity.
		_sf_trace('VAR SET "%s.%s" global=false size=%d' % [character_path, variable_name, snapshot.size()])

		var map_mgr := get_manager()
		if map_mgr:
			var map_character: StoryFlowCharacter = map_mgr.get_runtime_character(character_path)
			if map_character and map_character.variables.has(variable_name):
				var char_var: Dictionary = map_character.variables[variable_name]
				var char_val = char_var.get("value", null)
				# Write only when the variable exists and is map-typed (HTML's
				# setCharacterVariableValue type-mismatch → no write). Name/Image
				# built-ins are never map-typed.
				if char_val is StoryFlowVariant and char_var.get("type", -1) == StoryFlowTypes.VariableType.MAP:
					char_val.set_map(snapshot) # fresh storage — never aliases the source
					character_variable_changed.emit(character_path, variable_name, char_val)
				else:
					print_verbose("StoryFlow: SetCharacterVar map write skipped - variable '%s' on '%s' missing or not map-typed" % [variable_name, character_path])

		_handle_set_node_end(node, StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_FLOW))
		return

	# Get the value to set
	var new_value := StoryFlowVariant.new()
	var is_array: bool = data.get("isArray", false)
	# Array variables wire through "<type>-array-input", scalars through "<type>-input"
	var input_handle_suffix := variable_type + ("-array-input" if is_array else "-input")
	var input_edge: Dictionary = _context.current_script.find_input_edge(node["id"], input_handle_suffix)

	if is_array:
		if not input_edge.is_empty() and _evaluator:
			new_value = StoryFlowVariant.from_array(_evaluate_character_var_array_input(node["id"], variable_type, input_handle_suffix))
		else:
			var inline_value = data.get("value", null)
			if inline_value is StoryFlowVariant:
				new_value = inline_value.duplicate_variant()
	elif not input_edge.is_empty() and _evaluator:
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

	var value_str := ("[%d elements]" % new_value.get_array().size()) if is_array else new_value.to_display_string()
	_sf_trace('VAR SET "%s.%s" global=%s value=%s' % [character_path, variable_name, "true", value_str])

	# Set the character variable via the manager
	var mgr := get_manager()
	var mutated := false
	if mgr:
		var character: StoryFlowCharacter = mgr.get_runtime_character(character_path)
		if character:
			# Handle built-in "Name" field
			if variable_name.to_lower() == "name":
				character.character_name = new_value.get_string("")
				mutated = true
			# Handle built-in "Image" field
			elif variable_name.to_lower() == "image":
				character.image_key = new_value.get_string("")
				mutated = true
			# Custom variable
			elif character.variables.has(variable_name):
				character.variables[variable_name]["value"] = new_value
				mutated = true

	if mutated:
		character_variable_changed.emit(character_path, variable_name, new_value)

	_handle_set_node_end(node, StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_FLOW))


## Evaluate the wired array input of a setCharacterVar node, dispatching to the
## evaluator's typed array reader for the variable's element type. Returns a
## container copy so the character variable never aliases the source array
## (matches the HTML runtime's .slice() semantics).
func _evaluate_character_var_array_input(node_id: String, variable_type: String, handle_suffix: String) -> Array:
	match variable_type:
		"boolean":
			return _evaluator.evaluate_bool_array_input(node_id, handle_suffix).duplicate()
		"integer":
			return _evaluator.evaluate_int_array_input(node_id, handle_suffix).duplicate()
		"float":
			return _evaluator.evaluate_float_array_input(node_id, handle_suffix).duplicate()
		"image":
			return _evaluator.evaluate_image_array_input(node_id, handle_suffix).duplicate()
		"character":
			return _evaluator.evaluate_character_array_input(node_id, handle_suffix).duplicate()
		"audio":
			return _evaluator.evaluate_audio_array_input(node_id, handle_suffix).duplicate()
		_:
			# string / enum — string-keyed storage (matches the HTML default branch)
			return _evaluator.evaluate_string_array_input(node_id, handle_suffix).duplicate()

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

			# Resolve character portrait to actual Texture2D (reads from mutable
			# runtime character, so SetCharacterVar "Image" changes are reflected)
			if character.image_key != "":
				_sf_trace('CHAR IMAGE "%s"' % character.image_key)
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
		_context.persistent_image_texture = state.image
	elif data.get("imageReset", false):
		state.image = null
		state.image_key = ""
		_context.persistent_image = ""
		_context.persistent_image_texture = null
	else:
		state.image_key = _context.persistent_image
		if _context.persistent_image != "":
			state.image = _resolve_image_asset(_context.persistent_image, project, null)
			# Fallback to cached texture when asset can't be resolved in current
			# script (asset IDs are per-file, so cross-script lookups may fail)
			if state.image == null and _context.persistent_image_texture:
				state.image = _context.persistent_image_texture

	# Resolve audio asset
	var audio_key: String = data.get("audio", "")
	if audio_key != "":
		state.audio_key = audio_key
		state.audio = _audio.resolve_audio_asset(audio_key, _context.current_script, mgr)

	# Build visible text blocks (non-interactive, filtered by visibility)
	var text_blocks_data: Array = data.get("textBlocks", [])
	for block in text_blocks_data:
		# Check visibility condition (same mechanism as options)
		if _evaluator and not _evaluator.evaluate_option_visibility(block, dialogue_node.get("id", "")):
			continue

		var block_text: String = block.get("text", "")
		var tb := StoryFlowTextBlock.new()
		tb.id = block.get("id", "")
		tb.text = _text.interpolate(_text.get_string(block_text, language_code))
		state.text_blocks.append(tb)

	# Dialogue tags (already coerced to strings by the importer; authored order).
	# Optional: absent means none. Guard against a malformed non-array value so
	# the typed local can't fail to assign.
	var tags_data: Variant = data.get("tags", [])
	if tags_data is Array:
		for tag in tags_data:
			state.tags.append(tag)

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
# String Resolution
# =============================================================================

func _resolve_string(key: String) -> String:
	if key.is_empty():
		return key
	# During dialogue, the text interpolator has everything wired up
	if _context.is_executing:
		return _text.get_string(key, language_code)
	# Outside dialogue, resolve through the project's global strings
	var mgr := get_manager()
	if mgr:
		var project: StoryFlowProject = mgr.get_project()
		if project:
			return project.get_localized_string(key, language_code)
	return key


# =============================================================================
# Variable Helpers
# =============================================================================

func _find_variable_by_display_name(display_name: String) -> Dictionary:
	# During active dialogue, the context has name indices built
	if _context.is_executing:
		var result := _context.find_variable_by_name(display_name)
		if not result.is_empty():
			if result.get("is_global", false):
				var mgr := get_manager()
				if mgr:
					var var_id: String = result["id"]
					var globals: Dictionary = mgr.get_global_variables()
					if globals.has(var_id):
						return {"id": var_id, "variable": globals[var_id], "is_global": true}
			else:
				return result
		return {}

	# Outside dialogue: scan manager's globals by display name
	var mgr := get_manager()
	if mgr:
		var globals: Dictionary = mgr.get_global_variables()
		for var_id in globals:
			var v: Dictionary = globals[var_id]
			if v.get("name", "") == display_name:
				return {"id": var_id, "variable": v, "is_global": true}

	push_warning("StoryFlow: Global variable '%s' not found" % display_name)
	return {}


func _get_variable_name_from_node(node: Dictionary) -> String:
	var data: Dictionary = node.get("data", {})
	var var_id: String = data.get("variable", "")
	var is_global: bool = data.get("isGlobal", false)
	var variable: Dictionary = _find_variable(var_id, is_global)
	return variable.get("name", var_id)


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
		# Try direct buffer-based loading first (bypasses Godot's import cache)
		var loaded: Resource = _load_image_direct(val)
		if not loaded:
			loaded = _load_audio_direct(val)
		if not loaded:
			loaded = ResourceLoader.load(val)
		if loaded is Resource:
			assets[key] = loaded
			return loaded
	return null


## Load an image directly from file buffer, detecting the actual format from
## the file header (not the extension). This handles mismatched extensions
## like PNG data saved as .jpg.
func _load_image_direct(file_path: String) -> ImageTexture:
	var file := FileAccess.open(file_path, FileAccess.READ)
	if not file:
		return null
	var buffer := file.get_buffer(file.get_length())
	file.close()
	if buffer.size() < 4:
		return null

	var image := Image.new()
	var err: int = ERR_FILE_UNRECOGNIZED
	# Detect actual format from magic bytes
	if buffer[0] == 0x89 and buffer[1] == 0x50 and buffer[2] == 0x4E and buffer[3] == 0x47:
		err = image.load_png_from_buffer(buffer)
	elif buffer[0] == 0xFF and buffer[1] == 0xD8 and buffer[2] == 0xFF:
		err = image.load_jpg_from_buffer(buffer)
	elif buffer[0] == 0x52 and buffer[1] == 0x49 and buffer[2] == 0x46 and buffer[3] == 0x46:
		err = image.load_webp_from_buffer(buffer)
	else:
		err = image.load(file_path)
	if err != OK:
		return null
	return ImageTexture.create_from_image(image)


## Load an audio file directly from buffer, bypassing Godot's import pipeline.
func _load_audio_direct(file_path: String) -> AudioStream:
	var ext := file_path.get_extension().to_lower()
	if ext != "mp3":
		return null
	var file := FileAccess.open(file_path, FileAccess.READ)
	if not file:
		return null
	var buffer := file.get_buffer(file.get_length())
	file.close()
	if buffer.size() < 4:
		return null
	var stream := AudioStreamMP3.new()
	stream.data = buffer
	return stream
