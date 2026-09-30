class_name StoryFlowComponent
extends Node

# Preloaded by path so parsing never depends on the global class name cache,
# which can be stale or mid-rewrite when the game launches (godotengine/godot#75388).
const StoryFlowAudioController = preload("res://addons/storyflow/core/storyflow_audio_controller.gd")
const StoryFlowCallFrame = preload("res://addons/storyflow/core/storyflow_call_frame.gd")
const StoryFlowCharacter = preload("res://addons/storyflow/core/storyflow_character.gd")
const StoryFlowCharacterData = preload("res://addons/storyflow/core/storyflow_character_data.gd")
const StoryFlowDataAssetAccess = preload("res://addons/storyflow/core/storyflow_data_asset_access.gd")
const StoryFlowDataAssetStore = preload("res://addons/storyflow/core/storyflow_data_asset_store.gd")
const StoryFlowDialogueOption = preload("res://addons/storyflow/core/storyflow_dialogue_option.gd")
const StoryFlowDialogueState = preload("res://addons/storyflow/core/storyflow_dialogue_state.gd")
const StoryFlowEvaluator = preload("res://addons/storyflow/core/storyflow_evaluator.gd")
const StoryFlowExecutionContext = preload("res://addons/storyflow/core/storyflow_execution_context.gd")
const StoryFlowHandles = preload("res://addons/storyflow/core/storyflow_handles.gd")
const StoryFlowLocalization = preload("res://addons/storyflow/core/storyflow_localization.gd")
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

# Presentation hooks: a redraw keeps its entry, while revisiting even the same node gets a new one.
var _dialogue_entry_serial: int = 0
var _current_speaker_path: String = ""

## Whether THIS component currently holds a registration on the manager's active-dialogue count.
##
## That count gates save loading - StoryFlowManager.load_from_slot refuses while it is above zero
## - so a registration that is never given back disables .sfd persistence for the rest of the
## session, silently and with no way back short of restarting the game. _exit_tree was exactly
## that hole: a component freed mid-dialogue (a scene change, a queue_free) tore its state down
## without ever unregistering.
##
## One witness, set beside the increment and honoured by BOTH teardown paths, is what makes the
## count balance by construction instead of by every exit remembering to.
var _counted_dialogue_start: bool = false

## NodeType enum value -> Callable
var _node_handlers: Dictionary = {}

# =============================================================================
# Lifecycle
# =============================================================================

func _ready() -> void:
	add_to_group("storyflow_components")
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
	# Silently clean up without emitting signals - listeners are being torn down too and a
	# script_ended fired from here reaches nobody useful. The manager registration is the one
	# thing that must still be given back: it gates save loading, so a component freed
	# mid-dialogue would otherwise hold it for the rest of the session.
	if _context and _context.is_executing:
		_context.reset()
		if _dialogue_ui_instance and is_instance_valid(_dialogue_ui_instance):
			_dialogue_ui_instance.queue_free()
			_dialogue_ui_instance = null
	_end_dialogue_registration()


## Drop this component's evaluator AND give back its active-dialogue registration, together.
##
## THE TWO BELONG ON ONE PATH. StoryFlowManager.load_from_slot refuses to load while the count is
## above zero and clears no evaluator cache when it does load, and that is only sound because a
## count reaching zero means every component that was counted has already dropped its evaluator.
## Splitting them would turn that invariant into a coincidence maintained by two call sites.
##
## IDEMPOTENT, which is the whole point of the witness: a redundant stop_dialogue, or a
## stop_dialogue followed by _exit_tree, decrements once. get_node_or_null (through get_manager)
## keeps a teardown where the autoload is already freed a no-op rather than an error.
func _end_dialogue_registration() -> void:
	_evaluator = null
	_current_speaker_path = ""
	if not _counted_dialogue_start:
		return
	_counted_dialogue_start = false
	var mgr := get_manager()
	if mgr:
		mgr.register_dialogue_end()

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

	# RESTART WITHOUT A STOP is a supported call: nothing above requires the caller to have
	# stopped first, and a host chaining one script into another does exactly this. Give the
	# previous run's registration back BEFORE taking a new one, or the count climbs by one per
	# restart and never comes down - _end_dialogue_registration is idempotent by design, so the
	# single release on the eventual stop cannot pay off two acquisitions. That leaves the
	# manager reporting a dialogue active forever, which disables every save load: the exact
	# failure the witness exists to prevent, reached through the other door.
	#
	# It nulls _evaluator on the way, which is harmless here - the new evaluator below replaces
	# it a few lines later, so the "a count reaching zero means no live evaluator" invariant
	# survives the restart rather than being suspended across it.
	if _counted_dialogue_start:
		_end_dialogue_registration()

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

	# .sfd Data Assets: NON-OWNING references to the manager's seed and session overlay,
	# taken the same way the globals and characters above are. The manager mutates both in
	# place forever, so they stay valid for the life of this dialogue.
	_context.data_asset_seed = mgr.get_data_asset_seed()
	_context.data_asset_overlay = mgr.get_data_asset_overlay()
	_context.data_asset_revision = mgr.get_data_asset_revision()

	# P4 character id bridge: the same non-owning handover (characters engine contract §3).
	_context.character_id_bridge = mgr.get_character_id_bridge()

	# Localization state: the same non-owning handover (localization spec §9). The manager mutates
	# it in place, so a set_language mid-dialogue reaches this running graph's very next lookup
	# instead of a language copied at dialogue start.
	_context.localization = mgr.get_localization()

	# Create evaluator
	_evaluator = StoryFlowEvaluator.new()
	_evaluator.initialize(_context, mgr.get_global_variables(), mgr.get_runtime_characters(), language_code, project.global_strings, mgr)
	_evaluator.set_trace(_sf_trace)

	# Wire up text interpolator with manager reference
	_text.set_manager(mgr)
	_text.set_language_code(language_code)

	# Register with manager, and witness it so both teardown paths can give it back exactly once.
	mgr.register_dialogue_start()
	_counted_dialogue_start = true

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

	# ...but not the loop element of an enclosing array forEach, which lives in exactly the
	# field that clear just nulled. A dialogue inside a loop body is a chain boundary for the
	# chain, not for the loop: the iteration continues through the selected option, and every
	# node after this one still reads the element. See restore_live_loop_outputs' header.
	_context.restore_live_loop_outputs()

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

	# Same boundary, same carve-out as select_option: advancing a narrative dialogue inside a
	# forEach body must not cost the rest of the iteration its element.
	_context.restore_live_loop_outputs()

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
	_end_dialogue_registration()

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


## Resolved speaker identity, independent of the localized display name. Empty for narration.
func get_current_speaker_path() -> String:
	return _current_speaker_path


## Monotonic line-entry identity. UI refreshes keep this value, new entries increment it.
func get_dialogue_entry_serial() -> int:
	return _dialogue_entry_serial


## The actual player, including a paused line or audio retained after dialogue ends.
func get_current_dialogue_audio_player() -> AudioStreamPlayer:
	return _audio.get_player() if _audio else null


## Distinguishes playback of the same stream on a reused player from an old line's audio tail.
func get_dialogue_audio_playback_serial() -> int:
	return _audio.get_playback_serial() if _audio else 0

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

	# Handle built-in "Name" field (stored as string-table key, resolve it). FIRST TIER of
	# the A2(a) aliases: already case-insensitive pre-P4, so the shared predicate folds
	# cf_name in (the cf_-only second tier lives on set_character_variable below). A5:
	# this lane RESOLVES — it owns language state via _resolve_string — unlike the
	# evaluator arm and the DA-surface branch, which answer the stored key.
	if StoryFlowCharacter.is_name_token(variable_name):
		return StoryFlowVariant.from_string(character.character_name if character.name_is_literal else _resolve_string(character.character_name))

	# Handle built-in "Image" field (current portrait asset key; first tier, as above)
	if StoryFlowCharacter.is_image_token(variable_name):
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
	# The landed/refused answer is deliberately DISCARDED: this lane's pre-P4 posture is a
	# SILENT VOID no-op on a character or variable miss (A3(b) — never a create), pinned
	# first-class in tests/test_character_by_id_saves.gd. Only the ById setter below reports.
	_apply_character_variable(mgr.get_runtime_character(character_path), variable_name, value)


## The ONE write core behind the void path setter above and the bool ById setter below,
## reporting whether the write landed — so the new surface can be honest without the pre-P4
## lane changing shape.
##
## SECOND TIER of the A2(a) aliases: this lane has NO builtin arms and a
## case-sensitive dict, so ONLY the reserved cf_ tokens divert to the builtin fields —
## matched CASE-INSENSITIVELY per A6(a), since the reserved names can shadow nothing —
## while the native spellings stay byte-untouched (a custom variable named "Name"
## or "Image" still writes exactly as pre-P4, and a name that matches nothing is still
## the same silent no-op, never a create).
func _apply_character_variable(character: StoryFlowCharacter, variable_name: String, value: StoryFlowVariant) -> bool:
	if not character:
		return false
	var lower := variable_name.to_lower()
	if lower == StoryFlowCharacter.CF_NAME_ID:
		character.character_name = value.get_string("")
		character.name_is_literal = true
		return true
	if lower == StoryFlowCharacter.CF_IMAGE_ID:
		character.image_key = value.get_string("")
		return true
	if not character.variables.has(variable_name):
		return false
	if value is StoryFlowVariant:
		value.string_is_literal = true
	character.variables[variable_name]["value"] = value
	return true


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
# P4 Character Access by FILE id (characters engine contract §4 + A3/A4/A5)
# =============================================================================
#
# The id-taking doors beside the path APIs above. ON THE COMPONENT ONLY — Godot's mirror
# weight: this engine's V2 host surface lives on the component with its latch on the manager
# (the .sfd accessors below), and the manager carries NO per-variable surface of any kind to
# mirror onto — growing one for characters would be a new manager posture, not a mirror.
# (Cross-engine, for the record: Unreal is component-only for the same reason; Unity mirrors
# onto both because its V2 surface already lived on both.)
#
# NEW SURFACE, NEW IDIOM — the same divergence note as the .sfd host API below
# (_warn_data_asset_once: only the new surface changes shape): default params and bool
# returns rather than the pre-P4 sentinel-and-void shapes, and degraded resolutions warn
# LATCHED on the manager's character pair (should_warn_character_id_access), because these
# are host lanes a rebuilt or reparented component must not re-arm.
#
# THE VOCABULARY RULING (GP3): a dangling id on these lanes warns in the CHARACTER
# vocabulary — the resolver's own "dangling" rung, on the manager pair. These are new
# character surfaces with NO pre-P4 wording to protect. The DA-surface character branch
# below is the deliberate opposite: its dangling ids fall through to the DA ladder's
# pre-P4 "noasset" wording, byte-identical, because that surface predates characters.
#
# A2(b): none of these emit character_variable_changed — the signal is node-lane only,
# a contract property.


## HOST-LANE resolution of one character FILE id: the loaded record key, or "" with the
## dangling/unloaded warn already emitted at most once on the MANAGER pair. Each ById door
## resolves exactly ONCE and then delegates — never a second resolution (the drift the
## id-and-path-reach-one-record pin exists to catch). The getters route through here; the
## setter carries the same shape inline to reuse its own manager guard.
##
## A non-id-shaped value passes the resolver's verbatim non-id rung untouched and lands in
## the path delegate behind each door, so a record key from [method get_character_paths] is
## valid input to every ById door — the sibling ports' pure-delegate parity.
func _resolve_character_id_host(character_id: String) -> String:
	var mgr := get_manager()
	if not mgr:
		return ""
	return StoryFlowCharacter.resolve_character_key(
		mgr.get_character_id_bridge(), mgr.get_runtime_characters(), character_id, mgr)


## The live runtime character a character FILE id resolves to, or null for a not-found of
## either kind: a DANGLING id (no bridge entry) and an UNLOADED one (a bridge hit whose
## record is missing from the loaded set) — each warned once on the manager pair, in the
## character vocabulary (the ruling above). [method get_character_path_by_id] can still
## answer in the unloaded case, because the bridge itself is import state — the A3(a) split.
##
## A5: the record's character_name field is the STORED string-table key;
## [method get_character_variable_by_id] is this surface's resolving door.
func get_character_by_id(character_id: String) -> StoryFlowCharacter:
	var record_key := _resolve_character_id_host(character_id)
	if record_key.is_empty():
		return null
	return get_character(record_key)


## The record key (the runtime table's key) a character FILE id is indexed to, or "" for an
## id this build's character index never carried — "" is unambiguous, since record keys are
## never empty. A PURE bridge lookup, deliberately NOT routed through resolve_character_key,
## for the two recorded reasons (A3(a)): an existence query is not a degraded resolution, so
## it answers for an indexed id whether or not its record is loaded and NEVER warns — the
## resolver warns every miss; and the resolver's verbatim non-id rung would hand any non-id
## input straight back as a fake hit.
##
## The key comes back VERBATIM (the bridge's byte-identity guarantee: lowercase,
## backslashes) and is valid input to every path-taking character API above.
func get_character_path_by_id(character_id: String) -> String:
	var mgr := get_manager()
	if not mgr:
		return ""
	return str(mgr.get_character_id_bridge().get(character_id, ""))


## Record keys of every LOADED character, in the runtime table's insertion order — the A4
## enumeration surface, and the whole of it: by-id enumeration is deliberately not provided
## (ids serve stable BINDING; record keys serve enumeration and the path APIs). NO SORT
## PROMISE, kept weak on purpose for cross-engine uniformity — every engine answers its own
## map order.
##
## Engine-true doc (A5's merge-vs-wholesale inheritance note): the list reflects what the
## RUNTIME holds, and in this engine that always equals the project's character set —
## load_from_slot MERGES values onto the records the project declares and never adds or
## removes one (the four-sections doctrine on the manager), and reset refills from the
## project. The unloaded rung above is reachable only via ghost index entries, which have
## no record to enumerate either way.
func get_character_paths() -> Array[String]:
	var out: Array[String] = []
	var mgr := get_manager()
	if mgr:
		out.assign(mgr.get_runtime_characters().keys())
	return out


## Id twin of [method get_character_variable]: resolve the id ONCE through the host lane,
## then delegate. [param default] answers ONLY the RESOLUTION misses (dangling, unloaded,
## no manager) — the rungs the delegate never sees; once the id resolves, the variable
## access is the path API verbatim, including its own pre-P4 miss posture (an undeclared
## variable answers an EMPTY variant, never the default), so the two surfaces cannot drift.
##
## The FIRST-TIER aliases ride the delegate's builtin arms (cf_name/cf_image,
## case-insensitive), and so does A5's scope: this door RESOLVES the Name key to display
## text via _resolve_string, like the path getter it extends — the DA-surface branch below
## is the stored-key door, and saves write the STORED key regardless.
func get_character_variable_by_id(character_id: String, variable_name: String, default: StoryFlowVariant = null) -> StoryFlowVariant:
	var record_key := _resolve_character_id_host(character_id)
	if record_key.is_empty():
		return default
	return get_character_variable(record_key, variable_name)


## Id twin of [method set_character_variable], reporting whether the write landed — false
## for a resolution miss (warned once on the manager pair) AND for the A3(b) refusal: a
## write naming a variable the record does not declare NEVER creates it. The refusal itself
## stays as silent as the void path lane this extends (the shared _apply_character_variable
## core) — the bool is the new idiom's reporting channel, not a new warning.
##
## The SECOND-TIER aliases ride the shared core: only the cf_ tokens divert to the builtins
## (case-insensitive per A6(a)); native spellings keep the case-sensitive dict
## byte-identical. A2(b): emits nothing.
func set_character_variable_by_id(character_id: String, variable_name: String, value: StoryFlowVariant) -> bool:
	var mgr := get_manager()
	if not mgr:
		return false
	var record_key := StoryFlowCharacter.resolve_character_key(
		mgr.get_character_id_bridge(), mgr.get_runtime_characters(), character_id, mgr)
	if record_key.is_empty():
		return false
	return _apply_character_variable(mgr.get_runtime_character(record_key), variable_name, value)


# =============================================================================
# Data Asset Access (.sfd)
# =============================================================================
#
# The HOST-side door onto the .sfd store — the counterpart to the three node types, for game code
# that wants to read or write a Data Asset variable without going through a graph.
#
# [param asset] takes an asset's ID or its display NAME, because both audiences exist: the
# exporter keys everything by id (ids survive a rename) while a programmer holds the name they
# typed in the editor. The ID is tried first and exactly; a name must match exactly ONE asset.
#
# TWO NAMING DECISIONS, both departures from their nearest neighbours in this file:
#
#  - NO _variable SUFFIX. get_bool_variable reads a script or global variable and the suffix is
#    what separates it from get_character_variable; here the get_data_asset_ prefix already says
#    what is being read, and get_data_asset_bool_variable would be saying it twice.
#  - TYPED, WHERE THE CHARACTER ACCESSORS ARE UNTYPED. get_character_variable hands back a
#    StoryFlowVariant and lets the caller pick a getter, which works because a character variable
#    has no declaration to refuse against - the built-in Name and Image fields are not declared
#    anywhere. A .sfd variable does have one, and the whole value of the strict gate above is
#    refusing a mistyped read instead of quietly answering the wrong thing, which needs one
#    accessor per type to have something to refuse. get_data_asset_variant is the untyped door
#    for callers that want the character-accessor shape.
#
# CROSS-PORT: this matches Unity's GetDataAssetBool. Unreal spells the same call
# GetDataAssetBoolVariable - two of the three ports agree, and the contract does not pin API
# naming (section 1 is about node semantics, not host surfaces), so the divergence is recorded
# rather than resolved.
#
# Reads and writes go through the MANAGER's seed and overlay rather than the execution context's,
# so they work outside a dialogue too. Inside one they are the same two dictionaries — the
# context holds non-owning references to these very objects — so there is no second store and no
# staleness to reason about.
#
# THE TYPE GATE IS STRICT and lives on the DECLARATION, never on the stored value: within the
# string family a value carries no evidence of its declared type, which is the same reason the
# degraded ladder's declMatches check is on the declaration. So get_data_asset_string answers for
# a string, image, audio or character declaration (all of which store as bare strings in this
# engine) but NOT for an enum — an enum has its own accessor, and letting the string door read
# one would make a typo'd variable name that happened to hit an enum look like it worked.
#
# The typed accessors are SCALAR-ONLY. Arrays and maps come out through get_data_asset_variant,
# which is read-only: a write needs a declaration to mint the right element tags against, and the
# graph's Set node is what does that.
#
# WARNINGS ARE LATCHED, once per (asset, variable, kind) - a departure from the per-call idiom
# the character accessors above keep. Game code does not own its call rate the way that idiom
# assumes: a stale name read from _process warns every frame forever, and the first line already
# named the fix. The REFUSAL ITSELF is never latched - every call still answers its default or
# false. See _warn_data_asset_once.
#
# .sfd STRINGS RESOLVE AT THIS DOOR, and only where their PROVENANCE says they are content: a
# DECLARED string value localizes, an override and a session write are handed back verbatim. That
# is localization spec §2's amendment of 2026-08-27, which SUPERSEDES engine-contract 2.1's
# literal-value posture; the rule itself lives once, in StoryFlowDataAssetStore.try_read, and
# these accessors reach it by calling that door instead of try_resolve. Unlike
# get_string_variable above, the running script's strings table is NOT consulted - see
# _data_asset_locale.

const _DATA_ASSET_STRING_TYPES := [
	StoryFlowTypes.VariableType.STRING, StoryFlowTypes.VariableType.IMAGE,
	StoryFlowTypes.VariableType.AUDIO, StoryFlowTypes.VariableType.CHARACTER,
]


## The `.sfd` host ladder, minted per call — see storyflow_data_asset_access.gd for why it lives
## there rather than here. `language_code` is this component's PRE-LOCALIZATION fallback and can be
## changed at runtime, so it is read now rather than captured once.
func _da() -> StoryFlowDataAssetAccess:
	return StoryFlowDataAssetAccess.new(get_manager(), language_code)


## The boolean-memo clear every `.sfd` writer owes (StoryFlowDataAssetStore.try_set's header): the
## accessor's own read is carved out of the memo, but a memoized PARENT above it is not, so an
## option gated through andBool(accessor, true) keeps answering the pre-write value until this runs.
## It stays on this surface because the access layer owns no execution context.
func _da_written(ok: bool) -> bool:
	# _context is created in _ready, so a component that was never added to the tree has none -
	# and a host write from such a component has no dialogue memo to clear anyway.
	if ok and _context != null:
		_context.clear_boolean_memo()
	return ok


## Read a boolean-declared Data Asset variable. Returns [param default] on any miss.
func get_data_asset_bool(asset: String, variable_name: String, default := false) -> bool:
	var value := _da().read_data_asset_scalar(asset, variable_name, [StoryFlowTypes.VariableType.BOOLEAN])
	return default if value == null else value.get_bool(default)


## Write a boolean-declared Data Asset variable into the session overlay.
## Returns false (having warned) when the asset, the variable or the type does not check out.
func set_data_asset_bool(asset: String, variable_name: String, value: bool) -> bool:
	return _da_written(_da().write_data_asset_scalar(asset, variable_name, [StoryFlowTypes.VariableType.BOOLEAN], value))


func get_data_asset_int(asset: String, variable_name: String, default := 0) -> int:
	var value := _da().read_data_asset_scalar(asset, variable_name, [StoryFlowTypes.VariableType.INTEGER])
	return default if value == null else value.get_int(default)


func set_data_asset_int(asset: String, variable_name: String, value: int) -> bool:
	return _da_written(_da().write_data_asset_scalar(asset, variable_name, [StoryFlowTypes.VariableType.INTEGER], value))


func get_data_asset_float(asset: String, variable_name: String, default := 0.0) -> float:
	var value := _da().read_data_asset_scalar(asset, variable_name, [StoryFlowTypes.VariableType.FLOAT])
	return default if value == null else value.get_float(default)


func set_data_asset_float(asset: String, variable_name: String, value: float) -> bool:
	return _da_written(_da().write_data_asset_scalar(asset, variable_name, [StoryFlowTypes.VariableType.FLOAT], value))


## Read a string-family Data Asset variable: string, image, audio or character, all of which
## store as bare strings here. ENUM IS EXCLUDED — see [method get_data_asset_enum].
##
## The value is the LITERAL from the .sfd, never routed through the strings table.
func get_data_asset_string(asset: String, variable_name: String, default := "") -> String:
	var value := _da().read_data_asset_scalar(asset, variable_name, _DATA_ASSET_STRING_TYPES)
	return default if value == null else value.get_string(default)


func set_data_asset_string(asset: String, variable_name: String, value: String) -> bool:
	return _da_written(_da().write_data_asset_scalar(asset, variable_name, _DATA_ASSET_STRING_TYPES, value))


func get_data_asset_enum(asset: String, variable_name: String, default := "") -> String:
	var value := _da().read_data_asset_scalar(asset, variable_name, [StoryFlowTypes.VariableType.ENUM])
	return default if value == null else value.get_string(default)


func set_data_asset_enum(asset: String, variable_name: String, value: String) -> bool:
	return _da_written(_da().write_data_asset_scalar(asset, variable_name, [StoryFlowTypes.VariableType.ENUM], value))


## Replace a Data Asset's ARRAY variable with [param elements]. True when the write landed.
## The ladder and its shape gate live in storyflow_data_asset_access.gd, shared with the manager.
func set_data_asset_array(asset: String, variable_name: String, elements: Array) -> bool:
	return _da_written(_da().set_array(asset, variable_name, elements))


## Replace a Data Asset's MAP variable with these entries, with RAW keys. The map twin of
## [method set_data_asset_array].
func set_data_asset_map(asset: String, variable_name: String, keys: Array, values: Array) -> bool:
	return _da_written(_da().set_map(asset, variable_name, keys, values))


## Every variable name the asset's chain DECLARES, root-most ancestor first (contract §11.1).
##
## The accessors above all need a name the caller already knew. This is how a game learns the
## names - an inventory row per variable, a debug readout, a data-driven UI - and it is the SAME
## answer the Get Variable Names graph node gives, because both forward to
## StoryFlowDataAssetStore.variable_names, which owns every rule: root-first order, declarations
## only (an override shadows a name, it never adds one), dedupe by id then by name.
##
## Walking `parent` yourself is the thing this exists to prevent: that walk re-implements those
## rules, and a re-implementation that disagrees produces a plausible list nobody notices is
## wrong. [param asset] takes an id or a display name, like every accessor here. Empty when the
## asset cannot be resolved, there is no manager, or the seed does not carry it.
func get_data_asset_variable_names(asset: String) -> Array[String]:
	var empty: Array[String] = []
	var mgr := get_manager()
	if not mgr:
		return empty
	var asset_id := _da().resolve_data_asset_id(asset)
	if asset_id.is_empty():
		return empty
	return StoryFlowDataAssetStore.variable_names(mgr.get_data_asset_seed(), asset_id)


func get_data_asset_variant(asset: String, variable_name: String) -> StoryFlowVariant:
	return _da().read_data_asset_variant(asset, variable_name)


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
		if copy.type == StoryFlowTypes.VariableType.STRING and not copy.string_key.is_empty():
			copy.set_string(_resolve_string(copy.string_key))
		elif copy.type == StoryFlowTypes.VariableType.ENUM:
			copy.set_enum(_resolve_string(copy.get_string("")))
		out.append(copy)
	return out


## THE GATE THE TYPED ARRAY GETTERS SHARE: [method get_array_variable]'s list, but only for a
## variable whose DECLARED element type is one this caller asked for.
##
## The typed getters exist because every typed SETTER already did, so a game could write an
## Array[bool] and then had to read it back as variants and unpack by hand. Unpacking is the
## whole job, so the gate is what makes them more than a loop: a missing, non-array or
## wrong-typed variable warns and answers empty rather than coercing, matching the Unreal
## plugin's Get*ArrayVariable contract.
##
## The gate runs BEFORE [method get_array_variable] rather than filtering after it, so the
## not-an-array warning is emitted once, here, and never twice for one call.
func _typed_array_elements(variable_name: String, expected: Array, type_label: String) -> Array[StoryFlowVariant]:
	var empty: Array[StoryFlowVariant] = []
	var result := _find_variable_by_display_name(variable_name)
	if result.is_empty():
		push_warning("StoryFlow: Variable '%s' not found" % variable_name)
		return empty
	var v: Dictionary = result["variable"]
	if not v.get("is_array", false):
		push_warning("StoryFlow: Variable '%s' is not an array" % variable_name)
		return empty
	if not expected.has(v.get("type", StoryFlowTypes.VariableType.NONE)):
		push_warning("StoryFlow: Variable '%s' is not a %s array" % [variable_name, type_label])
		return empty
	return get_array_variable(variable_name)


## Read a boolean array variable by display name as a native typed array.
##
## Mirrors [method get_array_variable]'s scoping (locals during dialogue, then globals) but
## unpacks each element, so a caller never handles a variant. A missing, non-array or
## wrong-typed variable warns and returns an empty array. Counterpart to
## [method set_bool_array_variable].
func get_bool_array_variable(variable_name: String) -> Array[bool]:
	var out: Array[bool] = []
	for elem in _typed_array_elements(variable_name, [StoryFlowTypes.VariableType.BOOLEAN], "boolean"):
		out.append(elem.get_bool())
	return out


## Read an integer array variable as a native typed array. See
## [method get_bool_array_variable] for the shared rules.
func get_int_array_variable(variable_name: String) -> Array[int]:
	var out: Array[int] = []
	for elem in _typed_array_elements(variable_name, [StoryFlowTypes.VariableType.INTEGER], "integer"):
		out.append(elem.get_int())
	return out


## Read a float array variable as a native typed array. See
## [method get_bool_array_variable] for the shared rules.
func get_float_array_variable(variable_name: String) -> Array[float]:
	var out: Array[float] = []
	for elem in _typed_array_elements(variable_name, [StoryFlowTypes.VariableType.FLOAT], "float"):
		out.append(elem.get_float())
	return out


## Read a string array variable as a native typed array. Elements are resolved through the
## string table, so callers receive LOCALIZED text — [method get_array_variable] does that
## resolution and this inherits it. See [method get_bool_array_variable] for the shared rules.
func get_string_array_variable(variable_name: String) -> Array[String]:
	var out: Array[String] = []
	for elem in _typed_array_elements(variable_name, [StoryFlowTypes.VariableType.STRING], "string"):
		out.append(elem.get_string(""))
	return out


## Read an enum array variable as native option strings, resolved through the string table like
## the string array above. See [method get_bool_array_variable] for the shared rules.
func get_enum_array_variable(variable_name: String) -> Array[String]:
	var out: Array[String] = []
	for elem in _typed_array_elements(variable_name, [StoryFlowTypes.VariableType.ENUM], "enum"):
		out.append(elem.get_string(""))
	return out


## Read an image array variable as native asset-key strings. Keys come back RAW, never string
## table resolved, matching how image elements are stored. See [method get_bool_array_variable]
## for the shared rules.
func get_image_array_variable(variable_name: String) -> Array[String]:
	var out: Array[String] = []
	for elem in _typed_array_elements(variable_name, [StoryFlowTypes.VariableType.IMAGE], "image"):
		out.append(elem.get_string(""))
	return out


## Read an audio array variable as native asset-key strings, raw like the image array above.
## See [method get_bool_array_variable] for the shared rules.
func get_audio_array_variable(variable_name: String) -> Array[String]:
	var out: Array[String] = []
	for elem in _typed_array_elements(variable_name, [StoryFlowTypes.VariableType.AUDIO], "audio"):
		out.append(elem.get_string(""))
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
##
## THIS IS THE PUBLIC LOCALIZED DOOR, and it does resolve localized: it delegates to
## [method _resolve_string], which runs the one shared ladder (StoryFlowLocalization.look_up) -
## the translation overlay for the language StoryFlowManager.set_language selected, then the
## keying artifact's own table, then the raw key. Unlike its same-named siblings
## StoryFlowProject.get_localized_string and StoryFlowScript.get_localized_string, which are RAW
## exact-key probes that build `language.key` and run no language tier at all, this one is the
## method to call - a game that resolves a string by hand through those two silently bypasses
## every translation.
##
## Inside an active dialogue the current script's table joins the probe; outside one there is no
## script and the project globals (which characters.json merges into) are the only source tier.
## THE LOOKUP RUNS ON THE AUTHORED TEMPLATE (spec §9): interpolate the RESULT, never the input.
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
		NT.SET_IMAGE_ARRAY, NT.SET_CHARACTER_ARRAY, NT.SET_DATA_ARRAY, NT.SET_AUDIO_ARRAY,
		NT.SET_BOOL_ARRAY_ELEMENT, NT.SET_INT_ARRAY_ELEMENT, NT.SET_FLOAT_ARRAY_ELEMENT,
		NT.SET_STRING_ARRAY_ELEMENT, NT.SET_IMAGE_ARRAY_ELEMENT,
		NT.SET_CHARACTER_ARRAY_ELEMENT, NT.SET_DATA_ARRAY_ELEMENT, NT.SET_AUDIO_ARRAY_ELEMENT,
	]:
		_node_handlers[t] = array_set_handler

	# Array modify handlers (add, remove, clear)
	var array_modify_handler := _handle_array_modify
	for t in [
		NT.ADD_TO_BOOL_ARRAY, NT.ADD_TO_INT_ARRAY, NT.ADD_TO_FLOAT_ARRAY,
		NT.ADD_TO_STRING_ARRAY, NT.ADD_TO_IMAGE_ARRAY,
		NT.ADD_TO_CHARACTER_ARRAY, NT.ADD_TO_DATA_ARRAY, NT.ADD_TO_AUDIO_ARRAY,
		NT.REMOVE_FROM_BOOL_ARRAY, NT.REMOVE_FROM_INT_ARRAY, NT.REMOVE_FROM_FLOAT_ARRAY,
		NT.REMOVE_FROM_STRING_ARRAY, NT.REMOVE_FROM_IMAGE_ARRAY,
		NT.REMOVE_FROM_CHARACTER_ARRAY, NT.REMOVE_FROM_DATA_ARRAY, NT.REMOVE_FROM_AUDIO_ARRAY,
		NT.CLEAR_BOOL_ARRAY, NT.CLEAR_INT_ARRAY, NT.CLEAR_FLOAT_ARRAY,
		NT.CLEAR_STRING_ARRAY, NT.CLEAR_IMAGE_ARRAY,
		NT.CLEAR_CHARACTER_ARRAY, NT.CLEAR_DATA_ARRAY, NT.CLEAR_AUDIO_ARRAY,
	]:
		_node_handlers[t] = array_modify_handler

	# Array get handlers (data nodes, no-op)
	for t in [
		NT.GET_BOOL_ARRAY, NT.GET_INT_ARRAY, NT.GET_FLOAT_ARRAY,
		NT.GET_STRING_ARRAY, NT.GET_IMAGE_ARRAY,
		NT.GET_CHARACTER_ARRAY, NT.GET_DATA_ARRAY, NT.GET_AUDIO_ARRAY,
		NT.GET_BOOL_ARRAY_ELEMENT, NT.GET_INT_ARRAY_ELEMENT, NT.GET_FLOAT_ARRAY_ELEMENT,
		NT.GET_STRING_ARRAY_ELEMENT, NT.GET_IMAGE_ARRAY_ELEMENT,
		NT.GET_CHARACTER_ARRAY_ELEMENT, NT.GET_DATA_ARRAY_ELEMENT, NT.GET_AUDIO_ARRAY_ELEMENT,
		NT.GET_RANDOM_BOOL_ARRAY_ELEMENT, NT.GET_RANDOM_INT_ARRAY_ELEMENT,
		NT.GET_RANDOM_FLOAT_ARRAY_ELEMENT, NT.GET_RANDOM_STRING_ARRAY_ELEMENT,
		NT.GET_RANDOM_IMAGE_ARRAY_ELEMENT, NT.GET_RANDOM_CHARACTER_ARRAY_ELEMENT, NT.GET_RANDOM_DATA_ARRAY_ELEMENT,
		NT.GET_RANDOM_AUDIO_ARRAY_ELEMENT,
		NT.ARRAY_LENGTH_BOOL, NT.ARRAY_LENGTH_INT, NT.ARRAY_LENGTH_FLOAT,
		NT.ARRAY_LENGTH_STRING, NT.ARRAY_LENGTH_IMAGE,
		NT.ARRAY_LENGTH_CHARACTER, NT.ARRAY_LENGTH_DATA, NT.ARRAY_LENGTH_AUDIO,
		NT.ARRAY_CONTAINS_BOOL, NT.ARRAY_CONTAINS_INT, NT.ARRAY_CONTAINS_FLOAT,
		NT.ARRAY_CONTAINS_STRING, NT.ARRAY_CONTAINS_IMAGE,
		NT.ARRAY_CONTAINS_CHARACTER, NT.ARRAY_CONTAINS_DATA, NT.ARRAY_CONTAINS_AUDIO,
		NT.FIND_IN_BOOL_ARRAY, NT.FIND_IN_INT_ARRAY, NT.FIND_IN_FLOAT_ARRAY,
		NT.FIND_IN_STRING_ARRAY, NT.FIND_IN_IMAGE_ARRAY,
		NT.FIND_IN_CHARACTER_ARRAY, NT.FIND_IN_DATA_ARRAY, NT.FIND_IN_AUDIO_ARRAY,
	]:
		_node_handlers[t] = logic_handler

	# ForEach loop handlers
	var for_each_handler := _handle_for_each_loop
	for t in [
		NT.FOR_EACH_BOOL_LOOP, NT.FOR_EACH_INT_LOOP, NT.FOR_EACH_FLOAT_LOOP,
		NT.FOR_EACH_STRING_LOOP, NT.FOR_EACH_IMAGE_LOOP,
		NT.FOR_EACH_CHARACTER_LOOP, NT.FOR_EACH_DATA_LOOP, NT.FOR_EACH_AUDIO_LOOP,
	]:
		_node_handlers[t] = for_each_handler

	# Media get handlers (data nodes)
	_node_handlers[NT.GET_IMAGE] = logic_handler
	_node_handlers[NT.GET_AUDIO] = logic_handler
	_node_handlers[NT.GET_CHARACTER] = logic_handler
	for t in [NT.GET_DATA, NT.GET_DATA_ARRAY, NT.GET_DATA_ARRAY_ELEMENT,
		NT.GET_RANDOM_DATA_ARRAY_ELEMENT, NT.ARRAY_LENGTH_DATA,
		NT.ARRAY_CONTAINS_DATA, NT.FIND_IN_DATA_ARRAY]:
		_node_handlers[t] = _handle_data_read
	_node_handlers[NT.SET_DATA] = _handle_set_data

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

	# Data Asset (.sfd) handlers. The reference pill and the Get accessor are pure data
	# nodes — they produce nothing at exec time and are read lazily by the evaluators, so
	# they route exec straight through like every other Get. The Set is a flow node.
	_node_handlers[NT.GET_DATA_ASSET] = logic_handler
	_node_handlers[NT.GET_DATA_ASSET_VARIABLE] = logic_handler
	_node_handlers[NT.GET_DATA_ASSET_VARIABLE_NAMES] = logic_handler
	_node_handlers[NT.SET_DATA_ASSET_VARIABLE] = _handle_set_data_asset_var

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
		var output_arrays_by_name: Dictionary = {}
		var output_types_by_name: Dictionary = {}
		for var_id in _context.local_variables:
			var v: Dictionary = _context.local_variables[var_id]
			if v.get("is_output", false):
				var var_name: String = v.get("name", "")
				if not var_name.is_empty():
					var out_val = v.get("value", null)
					if out_val is StoryFlowVariant and out_val.is_map():
						out_val = out_val.duplicate_variant()
					output_by_name[var_name] = out_val
					output_arrays_by_name[var_name] = bool(v.get("is_array", false))
					output_types_by_name[var_name] = v.get("type", StoryFlowTypes.VariableType.NONE)

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
			var output_arrays: Dictionary = {}
			var output_types: Dictionary = {}
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
							output_arrays[out_id] = output_arrays_by_name[out_name]
							output_types[out_id] = output_types_by_name[out_name]
				# Also store by variable name as fallback
				for var_name in output_by_name:
					output_values[var_name] = output_by_name[var_name]
					output_arrays[var_name] = output_arrays_by_name[var_name]
					output_types[var_name] = output_types_by_name[var_name]

			# Store output values on the RunScript node's runtime state
			if output_values.size() > 0:
				var rs_state: StoryFlowNodeRuntimeState = _context.get_node_state(frame.return_node_id)
				rs_state.output_values = output_values
				rs_state.output_arrays = output_arrays
				rs_state.output_types = output_types
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
	if is_fresh_entry:
		_dialogue_entry_serial += 1

	# Clear evaluation cache for fresh option visibility evaluation
	if _evaluator:
		_evaluator.clear_cache()

	# The clear above is what makes the option gates re-evaluate; this is what leaves them
	# something to read. An array forEach publishes its current element through cached_output,
	# so without the restore a dialogue in a loop body renders its very first frame against the
	# type default — the one render the gate was authored for.
	_context.restore_live_loop_outputs()

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
	# A prior completed call cannot supply outputs while the next call is unfinished.
	var pending_state := _context.get_node_state(node["id"])
	pending_state.has_output_values = false
	pending_state.output_values = {}
	pending_state.output_arrays = {}
	pending_state.output_types = {}
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
					"dataAsset": arr = _evaluator.evaluate_data_array_input(node.get("id", ""), handle_suffix)
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
				elif param_type == "dataAsset":
					param_values[param_name] = StoryFlowVariant.from_string(_evaluator.evaluate_data_input(node.get("id", ""), handle_suffix, ""))
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
	if node.get("type") == StoryFlowTypes.NodeType.SET_DATA_ARRAY_ELEMENT:
		_handle_set_data_array_element(node)
		return
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
			NT.SET_DATA_ARRAY:
				new_array = _evaluator.evaluate_data_array_input(node.get("id", ""), StoryFlowHandles.IN_DATA_ARRAY)
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
		if node_type not in [NT.ADD_TO_DATA_ARRAY, NT.REMOVE_FROM_DATA_ARRAY, NT.CLEAR_DATA_ARRAY]:
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
			NT.ADD_TO_DATA_ARRAY, NT.REMOVE_FROM_DATA_ARRAY, NT.CLEAR_DATA_ARRAY:
				# HTML getArrayInput returns a copy. A chained modifier must not mutate
				# its input node's cached output or the original variable through an alias.
				arr = _evaluator.evaluate_data_array_input(node_id, StoryFlowHandles.IN_DATA_ARRAY).duplicate()
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
		NT.ADD_TO_DATA_ARRAY:
			var dv: String = inline_value.get_string() if inline_value is StoryFlowVariant else str(inline_value) if inline_value is String else ""
			arr.append(StoryFlowVariant.from_string(_evaluator.evaluate_data_input(node_id, StoryFlowHandles.IN_DATA, dv) if _evaluator else dv))
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
		NT.REMOVE_FROM_CHARACTER_ARRAY, NT.REMOVE_FROM_DATA_ARRAY, NT.REMOVE_FROM_AUDIO_ARRAY:
			var dv := 0
			if inline_value is StoryFlowVariant:
				dv = inline_value.get_int(0)
			var idx: int = _evaluator.evaluate_integer_input(node_id, StoryFlowHandles.IN_INTEGER, dv) if _evaluator else dv
			if idx >= 0 and idx < arr.size():
				arr.remove_at(idx)

		# Clear operations
		NT.CLEAR_BOOL_ARRAY, NT.CLEAR_INT_ARRAY, NT.CLEAR_FLOAT_ARRAY, \
		NT.CLEAR_STRING_ARRAY, NT.CLEAR_IMAGE_ARRAY, \
		NT.CLEAR_CHARACTER_ARRAY, NT.CLEAR_DATA_ARRAY, NT.CLEAR_AUDIO_ARRAY:
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
	# Store Data arrays independently of the modifier's cached output. Their elements
	# are mutable variant objects here, while the HTML runtime stores primitive IDs.
	var is_data_array := array_handle_suffix.begins_with("dataAsset-array")
	if is_data_array:
		new_array = StoryFlowVariant.from_array(new_array).duplicate_variant().get_array()
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

	# A .sfd accessor routes the write into the Data Asset OVERLAY — the array twin of
	# _handle_set_data_asset_var: the same write ladder (a degraded binding warns through the
	# same latch and writes nothing) and the same deep-copy-on-write try_set.
	#
	# ACCESSOR FIRST, before the character branch and before the name lookup below. An accessor
	# carries no isGlobal and its "variable" field is a display-NAME snapshot, so falling
	# through would make it clobber a same-named LOCAL script array instead — the decoy case
	# in tests/test_data_asset_nodes.gd.
	#
	# A bound-but-not-array accessor keeps its own warn-once refusal: its pins could not have
	# fed the op an array, and writing one over a scalar the declaration promises is exactly
	# what a .sfd write must never do.
	#
	# This single site covers add / remove / clear alike: unlike the HTML runtime, which gives
	# clearArray its own copy of this branch, Godot routes all three through
	# _handle_array_modify and lands here.
	if source_type == StoryFlowTypes.NodeType.GET_DATA_ASSET_VARIABLE \
		or source_type == StoryFlowTypes.NodeType.SET_DATA_ASSET_VARIABLE:
		if not bool(source_data.get("isArray", false)):
			if _context.should_warn_data_asset(source_id, "arrayop"):
				push_warning("StoryFlow: Data Asset array op refused - node %s is not bound to an array variable" % source_id)
			return
		if not _evaluator:
			return
		var da_asset_id: String = _evaluator.resolve_data_asset_write_target(source_data, source_id)
		if da_asset_id.is_empty():
			return
		var da_variable_id := str(source_data.get("variableId", ""))
		var da_declared: StoryFlowTypes.VariableType = StoryFlowTypes.parse_variable_type(str(source_data.get("variableType", "")))
		var da_elements: Array = []
		for element in new_array:
			da_elements.append(_type_data_asset_element(da_declared, element))
		var da_value := StoryFlowVariant.new()
		da_value.set_array(da_elements)
		# set_array reads the tag off element zero, so an emptied array would come back
		# untagged — stamp the declaration's storage type, exactly as the Set handler does.
		da_value.type = StoryFlowDataAssetStore.storage_type(da_declared)
		_sf_trace('DA SET "%s.%s" value=[%d elements]' % [da_asset_id, da_variable_id, da_elements.size()])
		StoryFlowDataAssetStore.try_set(_context.data_asset_seed, _context.data_asset_overlay, da_asset_id, da_variable_id, da_value, _context.data_asset_revision)

		# The same required invalidation as _handle_set_data_asset_var (arrayLength /
		# arrayContains feed boolean chains, so a memoized parent above one of them goes stale
		# in exactly the same way) — but ORDERED, because this site has a hazard that one does
		# not: _handle_array_modify already stamped THIS op's result onto its own node state
		# before calling us, and a downstream array read pulls that cached output. Clearing
		# without restoring it would break array chaining, so the stamp is re-applied here.
		#
		# It is re-applied from da_elements and re-TAGGED, not copied from new_array: what this
		# op hands downstream must be what it stored. An enum-declared array fed plain strings
		# would otherwise show STRING-tagged elements on the output pin and ENUM-tagged ones in
		# the overlay, and an op that emptied the array would hand out an untagged one — the
		# exact hole the write's own stamp two lines up exists to close. The restamp survives the
		# switch to a selective clear because its job was always the TAG; not being wiped was
		# only ever the other half of it.
		_context.clear_boolean_memo()
		var restamp := StoryFlowVariant.new()
		restamp.set_array(da_elements)
		restamp.type = StoryFlowDataAssetStore.storage_type(da_declared)
		_context.get_node_state(node_id).cached_output = restamp
		return

	# Handle character variable arrays
	if source_type == StoryFlowTypes.NodeType.GET_CHARACTER_VAR or source_type == StoryFlowTypes.NodeType.SET_CHARACTER_VAR:
		var char_path: String = source_data.get("characterPath", "")
		var var_name: String = source_data.get("variableName", "")
		var mgr := get_manager()
		# Id-first here too (characters engine contract §4): this write-back binds to the
		# SAME node fields the array READ resolved through — left path-keyed, an id-bound
		# array chain would read one character and write the modification back to whatever
		# stale record the path field names. NODE lane -> the context latch pair.
		var wired := false
		if is_data_array and _evaluator:
			var char_edge := _context.current_script.find_input_edge(source_id, StoryFlowHandles.IN_CHARACTER_INPUT)
			if not char_edge.is_empty():
				var char_source := _context.current_script.get_node(char_edge.get("source", ""))
				if not char_source.is_empty():
					char_path = _evaluator.evaluate_string_from_node(char_source.get("id", ""), char_edge.get("source_handle", ""))
					wired = true
		if mgr:
			if wired:
				char_path = StoryFlowCharacter.resolve_character_key(
					_context.character_id_bridge, mgr.get_runtime_characters(), char_path, _context)
			else:
				char_path = StoryFlowCharacter.resolve_character_ref(
					_context.character_id_bridge, mgr.get_runtime_characters(),
					str(source_data.get("characterId", "")), char_path, _context)
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

	# Exported variable nodes bind by ID; retain the name fallback for legacy graphs.
	var bound := _find_variable(str(source_data.get("variable", "")), is_global)
	if not bound.is_empty() and bound.get("is_array", false) and bound.get("value") is StoryFlowVariant:
		bound["value"].set_array(new_array)
		_notify_variable_changed(bound, is_global)
		return

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
		NT.ADD_TO_DATA_ARRAY, NT.REMOVE_FROM_DATA_ARRAY, NT.CLEAR_DATA_ARRAY:
			return StoryFlowHandles.IN_DATA_ARRAY
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
				NT.FOR_EACH_DATA_LOOP:
					loop_array = _evaluator.evaluate_data_array_input(node.get("id", ""), StoryFlowHandles.IN_DATA_ARRAY)
				NT.FOR_EACH_AUDIO_LOOP:
					loop_array = _evaluator.evaluate_audio_array_input(node.get("id", ""), StoryFlowHandles.IN_AUDIO_ARRAY)

		node_state.loop_array = loop_array
		node_state.loop_index = 0
		node_state.loop_initialized = true

	if node_state.loop_index < node_state.loop_array.size():
		# Clear evaluation caches from previous iteration so boolean chains re-evaluate
		_context.clear_cached_outputs()

		# Restore cached outputs for all active outer loops (nested forEach support). THIS
		# node's frame is not on the stack yet — it is pushed further down, and
		# _continue_for_each_loop pops it before re-entering — so the stamp below is the only
		# thing that publishes the current element.
		_context.restore_live_loop_outputs()

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
				if kind == StoryFlowEvaluator.MAP_SOURCE_CHARACTER_VAR or kind == StoryFlowEvaluator.MAP_SOURCE_RUN_SCRIPT \
					or kind == StoryFlowEvaluator.MAP_SOURCE_DATA_ASSET:
					# Read-only-terminal chain (charvar, runScript output or .sfd accessor):
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

	var detached := kind == StoryFlowEvaluator.MAP_SOURCE_DATA_ASSET
	if detached:
		var copy := {}
		for entry_key in map:
			copy[entry_key] = map[entry_key].duplicate_variant()
		map = copy
		# Detached results retain display text. Wired strings have already been evaluated;
		# only an unwired inline value still holds its originating script's authored key.
		if new_value != null and str(data.get("valueType", "")) == "string":
			if _context.current_script.find_input_edge(node["id"], "string-4").is_empty():
				new_value.set_string(_evaluator._resolve_string_key(new_value.get_string()))
	if kind == StoryFlowEvaluator.MAP_SOURCE_CHARACTER_VAR or kind == StoryFlowEvaluator.MAP_SOURCE_RUN_SCRIPT:
		# Read-only-terminal chain (charvar or runScript output): HTML
		# hands the mutator a THROWAWAY fresh Map — the stored variable is observably
		# unchanged and no variable-change dispatch fires. Skip mutation AND
		# notify (observable no-op): use setCharacterVar to write character variables.
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

	if detached:
		var output := map_result.duplicate()
		output["map"] = map
		_context.get_node_state(node.get("id", "")).detached_map_output = output
	var origin_variable: Dictionary = map_result.get("variable", {})
	if not detached and not origin_variable.is_empty():
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
		node_state.loop_text_is_resolved = false
		if _evaluator:
			var map_result: Dictionary = _evaluator.resolve_map_input(node, "map")
			var map = map_result.get("map")
			if map is Dictionary:
				node_state.loop_text_is_resolved = map_result.get("kind", "") == StoryFlowEvaluator.MAP_SOURCE_DATA_ASSET
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
		# no restore: their loop_key/loop_value are not wiped by the cache clear,
		# and the helper's bounds check skips their empty loop_array anyway.
		_context.restore_live_loop_outputs()

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
		node_state.loop_text_is_resolved = false
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
	var char_wired := false
	if not char_edge.is_empty() and _evaluator:
		var char_node: Dictionary = _context.current_script.get_node(char_edge.get("source", ""))
		if not char_node.is_empty():
			character_path = _evaluator.evaluate_string_from_node(char_node.get("id", ""), char_edge.get("source_handle", ""))
			char_wired = true

	# Id-first resolution (characters engine contract §4), NODE lane -> the context latch
	# pair. Wired override wins outright (a dangling inline id under a healthy wire never
	# warns); every fall-back returns the path VERBATIM, so the trace, the writes and the
	# signal below behave byte-identically pre-P4. On an id hit character_path becomes the
	# resolved record key, which is what the trace prints and the signal carries.
	var res_mgr := get_manager()
	if res_mgr:
		if char_wired:
			character_path = StoryFlowCharacter.resolve_character_key(
				_context.character_id_bridge, res_mgr.get_runtime_characters(), character_path, _context)
		else:
			character_path = StoryFlowCharacter.resolve_character_ref(
				_context.character_id_bridge, res_mgr.get_runtime_characters(),
				str(data.get("characterId", "")), character_path, _context)

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
			if variable_type == "dataAsset":
				new_value.set_string(_evaluator.evaluate_data_from_node(source_node.get("id", ""), source_handle))
			elif variable_type == "boolean":
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
			# Handle built-in "Name" field. FIRST TIER of the A2(a) aliases: already
			# case-insensitive pre-P4, so the shared predicate folds cf_name in (the
			# cf_-only second tier lives on public set_character_variable).
			if StoryFlowCharacter.is_name_token(variable_name):
				character.character_name = new_value.get_string("")
				character.name_is_literal = true
				mutated = true
			# Handle built-in "Image" field (first tier, same as Name above)
			elif StoryFlowCharacter.is_image_token(variable_name):
				character.image_key = new_value.get_string("")
				mutated = true
			# Custom variable. Write only when the declared row matches the node's own type
			# snapshot (HTML's setCharacterVariableValue type-mismatch -> no write, the same
			# gate the map path above already keeps): a mismatched write is REFUSED - nothing
			# lands, no signal fires, exec still continues. Contract SS5's
			# type-mismatch-write-refused pin, tests/test_character_contract.gd.
			elif character.variables.has(variable_name):
				var char_var: Dictionary = character.variables[variable_name]
				if char_var.get("type", -1) == StoryFlowTypes.parse_variable_type(variable_type) \
						and bool(char_var.get("is_array", false)) == is_array:
					char_var["value"] = new_value
					mutated = true
				else:
					print_verbose("StoryFlow: SetCharacterVar write skipped - variable '%s' on '%s' does not match the node's declared type" % [variable_name, character_path])

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
		"dataAsset":
			return _evaluator.evaluate_data_array_input(node_id, handle_suffix).duplicate()
		"audio":
			return _evaluator.evaluate_audio_array_input(node_id, handle_suffix).duplicate()
		_:
			# string / enum — string-keyed storage (matches the HTML default branch)
			return _evaluator.evaluate_string_array_input(node_id, handle_suffix).duplicate()

# =============================================================================
# Node Handlers - Data Asset Variables (.sfd)
# =============================================================================

## Execute a setDataAssetVariable node: record the wired value in the session overlay.
##
## Shaped like [method _handle_set_character_var] — resolve the target, read the value, trace,
## write, then [method _handle_set_node_end] — with two deliberate differences:
##
## 1. THE LADDER RUNS FIRST. Every degraded case (engine contract 6) is a NO-OP with a
##    once-per-node warning, because writing anything would be worse than doing nothing: an
##    overlay entry SHADOWS the declared default for the rest of the session, and cascades to
##    every descendant when it lands on a base.
## 2. THERE IS NO INLINE FALLBACK. setCharacterVar keeps an editable value on its face and
##    writes it when its pin is unwired; this node's face is the BINDING, so it persists no
##    value and an unwired pin has nothing to offer. Every value branch below does its own
##    explicit find_input_edge and REFUSES — never writes the type's zero over the declared
##    default (contract 5, the getTypedInput trap).
##
## _handle_set_node_end runs on EVERY path, including the refusals: a Set that declines to
## write still has to let the exec chain continue, or a wiring mistake freezes the dialogue.
func _handle_set_data_asset_var(node: Dictionary) -> void:
	var node_id: String = node.get("id", "")
	var data: Dictionary = node.get("data", {})
	var flow_handle := StoryFlowHandles.source(node_id, StoryFlowHandles.OUT_FLOW)

	if not _evaluator:
		_handle_set_node_end(node, flow_handle)
		return

	# All five ladder rungs, warned once each. "" for every degraded case.
	var asset_id: String = _evaluator.resolve_data_asset_write_target(data, node_id)
	if asset_id.is_empty():
		_handle_set_node_end(node, flow_handle)
		return

	var variable_id := str(data.get("variableId", ""))
	var value := _read_data_asset_set_input(node, data)
	if value == null:
		# NOT latched, unlike the ladder above (contract 6, last row): this one names a wiring
		# mistake on an EXEC node the author just ran, and an exec node fires far less often
		# than an option condition re-evaluates.
		push_warning("StoryFlow: Set Data Asset Variable refused an unwired or unresolved value pin: node %s (%s.%s)" % [node_id, asset_id, variable_id])
		_handle_set_node_end(node, flow_handle)
		return

	# Trace BEFORE the write, matching every other setter in this file.
	_sf_trace('DA SET "%s.%s" value=%s' % [asset_id, variable_id, _data_asset_trace_value(value, data)])
	StoryFlowDataAssetStore.try_set(_context.data_asset_seed, _context.data_asset_overlay, asset_id, variable_id, value, _context.data_asset_revision)

	# Drop the memoized boolean outputs so option conditions re-evaluate against the new value
	# (contract 5), the analog of the reference runtime's clearNotBoolCache.
	#
	# THIS IS REQUIRED, and the pull-write-pull triple in tests/test_data_asset_nodes.gd is what
	# proved it rather than a guess. The accessor's OWN read is already carved out of the memo
	# (is_data_asset_read in storyflow_evaluator.gd), so a direct read does see the write without
	# any help — but a memoized PARENT does not. process_boolean_chain recurses into an
	# andBool/orBool/equalBool's inputs WITHOUT recomputing the node itself, so the following
	# evaluate_boolean_from_node answers from that node's stale cache: an option gated through
	# andBool(accessor, true) stayed VISIBLE across a write to false until this line existed.
	#
	# SELECTIVE, and it has to be: clear_cached_outputs nulls EVERY node output, and mid-chain
	# that takes an array forEach's current element and every array op's result pin down with the
	# booleans. clear_boolean_memo touches only the derived booleans the memo actually serves,
	# which is both the whole of what needs invalidating here and the whole of what may be.
	_context.clear_boolean_memo()

	_handle_set_node_end(node, flow_handle)


## The value a setDataAssetVariable node is writing, or [code]null[/code] when its value pin is
## UNWIRED (which is a refusal, not an empty write).
##
## The pin suffixes are the editor's, from SetDataAssetVariableNode.tsx's value pin at optionId
## "2": "{type}-2" for a scalar, "{type}-array-2" for an array, "map-{K}-{V}-2" for a map.
##
## Wired-but-unresolvable is NOT a refusal — it writes the empty container, matching the
## reference's getArrayInput/getMapInput ("wired to something that resolves to nothing" is how
## an author clears a .sfd array or map). Only the ABSENT EDGE refuses.
##
## Values are re-minted against the DECLARED type rather than passed through: an enum array
## wired from a plain string array must land ENUM-tagged, and an empty array must still carry
## its element type (set_array infers the tag from element zero, which leaves an empty array
## untagged — the same stamp StoryFlowDataAssetStore.type_value applies at import).
func _read_data_asset_set_input(node: Dictionary, data: Dictionary) -> StoryFlowVariant:
	_context.clear_boolean_memo()
	var failures := _context.resolution_failures
	var value := _read_data_asset_set_input_core(node, data)
	return value if failures == _context.resolution_failures else null


func _read_data_asset_set_input_core(node: Dictionary, data: Dictionary) -> StoryFlowVariant:
	var node_id: String = node.get("id", "")
	var variable_type := str(data.get("variableType", ""))
	var declared: StoryFlowTypes.VariableType = StoryFlowTypes.parse_variable_type(variable_type)

	if declared == StoryFlowTypes.VariableType.MAP:
		var key_type := str(data.get("keyType", ""))
		var value_type := str(data.get("valueType", ""))
		# Without K/V the map handle id cannot be built at all, so there is no pin to read.
		if key_type.is_empty() or value_type.is_empty():
			return null
		var map_suffix := StoryFlowHandles.in_map(key_type, value_type, StoryFlowHandles.DATA_ASSET_VALUE_OPTION)
		if _context.current_script.find_input_edge(node_id, map_suffix).is_empty():
			return null
		var snapshot: Dictionary = {}
		var map_result: Dictionary = _evaluator.resolve_map_input_by_handle(node, map_suffix)
		var source_map = map_result.get("map")
		if map_result.has("source_key_type") and (map_result.source_key_type != StoryFlowTypes.parse_variable_type(key_type) or map_result.source_value_type != StoryFlowTypes.parse_variable_type(value_type)):
			return null
		if source_map is Dictionary:
			# Snapshot into fresh storage — never alias the source (the setCharacterVar map
			# precedent). try_set duplicates again on the way in; this one keeps the value the
			# trace prints and the value stored identical even if the source mutates between.
			#
			# Entry VALUES are re-minted against the declared valueType, exactly as the array
			# branch below re-mints elements, and for the same reason: the wired pin's K/V tokens
			# match the declaration (the ladder's decl_matches sees to that) but the variants
			# INSIDE the source map carry whatever tag their producer gave them. An enum-valued
			# map fed plain strings would otherwise sit STRING-tagged in the overlay and come
			# back ENUM-tagged after a save round trip, since the load types from the declaration
			# — a tag flip visible through get_data_asset_variant and in nothing else.
			var declared_value_type := StoryFlowTypes.parse_variable_type(value_type)
			for key in source_map:
				if (key_type == "integer" and not key is int) or (key_type != "integer" and not key is String) or not _data_asset_element_matches(declared_value_type, source_map[key]):
					return null
				snapshot[key] = _type_data_asset_element(declared_value_type, source_map[key])
		return StoryFlowVariant.from_map(snapshot)

	if bool(data.get("isArray", false)):
		var array_suffix := StoryFlowHandles.in_data_asset_array_value(variable_type)
		if _context.current_script.find_input_edge(node_id, array_suffix).is_empty():
			return null
		# Reuses the character path's typed-array dispatcher — it is generic, only its name is
		# not. Its container .duplicate() is redundant here (every element is re-minted below),
		# which is also what keeps .sfd arrays clear of that shallow copy.
		var source_elements := _evaluate_character_var_array_input(node_id, variable_type, array_suffix)
		var elements: Array = []
		for element in source_elements:
			if not _data_asset_element_matches(declared, element):
				return null
			elements.append(_type_data_asset_element(declared, element))
		var array_variant := StoryFlowVariant.new()
		array_variant.set_array(elements)
		array_variant.type = StoryFlowDataAssetStore.storage_type(declared)
		return array_variant

	var scalar_suffix := StoryFlowHandles.in_data_asset_value(variable_type)
	var edge: Dictionary = _context.current_script.find_input_edge(node_id, scalar_suffix)
	if edge.is_empty():
		return null
	var source_id: String = edge.get("source", "")
	var source_handle: String = edge.get("source_handle", "")
	var value := StoryFlowVariant.new()
	match declared:
		StoryFlowTypes.VariableType.BOOLEAN:
			value.set_bool(_evaluator.evaluate_boolean_from_node(source_id, source_handle))
		StoryFlowTypes.VariableType.INTEGER:
			value.set_int(_evaluator.evaluate_integer_from_node(source_id, source_handle))
		StoryFlowTypes.VariableType.FLOAT:
			value.set_float(_evaluator.evaluate_float_from_node(source_id, source_handle))
		StoryFlowTypes.VariableType.DATA_ASSET:
			value.set_string(_evaluator.evaluate_data_from_node(source_id, source_handle))
		StoryFlowTypes.VariableType.ENUM:
			value.set_enum(_evaluator.evaluate_string_from_node(source_id, source_handle))
		StoryFlowTypes.VariableType.STRING, \
		StoryFlowTypes.VariableType.IMAGE, \
		StoryFlowTypes.VariableType.AUDIO, \
		StoryFlowTypes.VariableType.CHARACTER:
			value.set_string(_evaluator.evaluate_string_from_node(source_id, source_handle))
		_:
			# Unreachable past the ladder — decl_matches refuses a wire type the shared parse
			# table does not know — but a write with no type to give it is refused, not guessed.
			return null
	return value


## Validate evaluated entries before reminting them; no mismatched value becomes a type zero.
func _data_asset_element_matches(declared: int, source) -> bool:
	if not source is StoryFlowVariant:
		return false
	var storage := StoryFlowDataAssetStore.storage_type(declared)
	if storage in [StoryFlowTypes.VariableType.STRING, StoryFlowTypes.VariableType.ENUM]:
		return source.type in [StoryFlowTypes.VariableType.STRING, StoryFlowTypes.VariableType.ENUM]
	return source.type == storage


func _type_data_asset_element(declared: StoryFlowTypes.VariableType, source) -> StoryFlowVariant:
	var element := StoryFlowVariant.new()
	if not source is StoryFlowVariant:
		element.type = StoryFlowDataAssetStore.storage_type(declared)
		return element
	match declared:
		StoryFlowTypes.VariableType.BOOLEAN:
			element.set_bool(source.get_bool())
		StoryFlowTypes.VariableType.INTEGER:
			element.set_int(source.get_int())
		StoryFlowTypes.VariableType.FLOAT:
			element.set_float(source.get_float())
		StoryFlowTypes.VariableType.ENUM:
			element.set_enum(source.get_string())
		StoryFlowTypes.VariableType.STRING:
			# A session write captures displayed text, not the source array's authored key.
			element.set_string(_evaluator._array_string(source))
		_:
			element.set_string(source.get_string())
	return element


## A .sfd value rendered for the DA SET trace line, told apart by the accessor's own snapshot
## rather than by the variant: to_display_string answers "" for a map, an array AND an empty
## string alike, so an empty array would otherwise be indistinguishable from an empty string.
## Containers trace their SIZE — printing a large map's contents would make the trace unusable.
func _data_asset_trace_value(value: StoryFlowVariant, data: Dictionary) -> String:
	if str(data.get("variableType", "")) == "map":
		return "{%d entries}" % value.get_map().size()
	if bool(data.get("isArray", false)):
		return "[%d elements]" % value.get_array().size()
	return value.to_display_string()


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
	_current_speaker_path = ""
	var state := StoryFlowDialogueState.new()
	state.is_valid = true
	state.node_id = dialogue_node.get("id", "")

	var data: Dictionary = dialogue_node.get("data", {})
	var mgr := get_manager()
	var project: StoryFlowProject = mgr.get_project() if mgr else null

	# IMPORTANT: Resolve character FIRST so {Character.Name} interpolation works
	var character_path: String = data.get("character", "")
	# Id-first speaker resolution (characters engine contract §4): characterRefId through
	# the bridge — NODE lane, so the context's latch pair — with the path field as the
	# fall-back, returned verbatim so the pre-P4 lines below behave byte-identically.
	if mgr:
		character_path = StoryFlowCharacter.resolve_character_ref(
			_context.character_id_bridge, mgr.get_runtime_characters(),
			str(data.get("characterRefId", "")), character_path, _context)
	if character_path != "" and mgr:
		var character: StoryFlowCharacter = mgr.get_runtime_character(character_path)
		if character:
			_current_speaker_path = StoryFlowCharacter.normalize_path(character_path)
			var char_data := StoryFlowCharacterData.new()
			# Authored names resolve at read time; player-written names remain literal.
			char_data.character_path = character_path
			char_data.name = character.character_name if character.name_is_literal else _text.get_string(character.character_name, language_code)

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

	# Get title and text from string table, then interpolate variables.
	#
	# THE AUTHORED-TEMPLATE INVARIANT (localization spec §9) governs this field and every one
	# below it - the text blocks and the option labels: the table lookup runs FIRST and interpolate
	# runs on its RESULT. A translated line is authored with the same {Variable} tokens as the
	# source line, so interpolating first would hand the lookup a string no table was ever keyed
	# by, and the failure is invisible - the text still renders, in the source language, only for
	# lines that happen to carry a token. get_string IS the whole ladder; never build a
	# `language_code + "." + key` probe here.
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

## The component's string door, on both sides of a dialogue.
##
## DURING dialogue it delegates to the text interpolator (whose lookup adds the current script's
## own strings table); OUTSIDE dialogue there is no script and the project globals - which
## characters.json merges into - are the only source tier. That split is the pre-localization
## behavior kept exactly as it was; both sides now run the SAME shared ladder
## (StoryFlowLocalization.look_up), so a string cannot resolve one way inside dialogue and another
## way outside it.
##
## [member language_code] is the PRE-LOCALIZATION language and only the fallback; once the project
## ships a localization.json the manager owns the language (see StoryFlowManager.set_language).
##
## THE LOOKUP RUNS ON THE AUTHORED TEMPLATE (§9): any caller that interpolates `{Variable}` tokens
## does it on this RESULT, never before the call.
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
			var resolved = StoryFlowLocalization.look_up(
				mgr.get_localization(), null, project.global_strings, key, language_code)
			return key if resolved == null else resolved
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


func _handle_set_data(node: Dictionary) -> void:
	var data: Dictionary = node.get("data", {})
	var variable := _find_variable(str(data.get("variable", "")), bool(data.get("isGlobal", false)))
	if variable.get("type", -1) == StoryFlowTypes.VariableType.DATA_ASSET and not variable.get("is_array", false):
		var inline_value = data.get("value")
		var current = variable.get("value")
		var fallback: String = current.get_string() if current is StoryFlowVariant else ""
		if inline_value is StoryFlowVariant:
			fallback = inline_value.get_string()
		elif inline_value is String:
			fallback = inline_value
		var value := _evaluator.evaluate_data_input(node.get("id", ""), "dataAsset-2", fallback) if _evaluator else fallback
		_set_variable_on_node(node, StoryFlowVariant.from_string(value))
		_sf_trace('VAR SET "%s" global=%s value=%s' % [variable.get("name", ""), str(data.get("isGlobal", false)).to_lower(), value])
	_handle_set_node_end(node, StoryFlowHandles.source(node["id"], StoryFlowHandles.OUT_FLOW))


func _handle_data_read(node: Dictionary) -> void:
	var suffix := "dataAsset-"
	match node.get("type"):
		StoryFlowTypes.NodeType.ARRAY_LENGTH_DATA, StoryFlowTypes.NodeType.FIND_IN_DATA_ARRAY:
			suffix = StoryFlowHandles.OUT_INTEGER
		StoryFlowTypes.NodeType.ARRAY_CONTAINS_DATA:
			suffix = StoryFlowHandles.OUT_BOOLEAN
	_process_next_node(StoryFlowHandles.source(node["id"], suffix))


func _handle_set_data_array_element(node: Dictionary) -> void:
	var node_id: String = node["id"]
	var data: Dictionary = node.get("data", {})
	var suffix := "dataAsset-array-2"
	if _evaluator:
		var failures_before := _context.resolution_failures
		var arr := _evaluator.evaluate_data_array_input(node_id, suffix).duplicate()
		var index := _evaluator.evaluate_integer_input(node_id, "integer-3", _evaluator._get_data_int(data, "value1", 0))
		var value := _evaluator.evaluate_data_input(node_id, "dataAsset-4", _evaluator._get_data_string(data, "value2"))
		if _context.resolution_failures == failures_before and index >= 0 and index < arr.size():
			arr[index] = StoryFlowVariant.from_string(value)
			_context.get_node_state(node_id).cached_output = StoryFlowVariant.from_array(arr)
			_update_connected_array_variable(node, suffix, arr)
	_handle_set_node_end(node, StoryFlowHandles.source(node_id, StoryFlowHandles.OUT_FLOW))
