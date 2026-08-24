extends Node

# Preloaded by path so parsing never depends on the global class name cache,
# which can be stale or mid-rewrite when the game launches (godotengine/godot#75388).
const StoryFlowCharacter = preload("res://addons/storyflow/core/storyflow_character.gd")
const StoryFlowDataAssetStore = preload("res://addons/storyflow/core/storyflow_data_asset_store.gd")
const StoryFlowImporter = preload("res://addons/storyflow/editor/storyflow_importer.gd")
const StoryFlowProject = preload("res://addons/storyflow/core/storyflow_project.gd")
const StoryFlowSaveData = preload("res://addons/storyflow/core/storyflow_save_data.gd")
const StoryFlowScript = preload("res://addons/storyflow/core/storyflow_script.gd")
const StoryFlowVariant = preload("res://addons/storyflow/core/storyflow_variant.gd")

# =============================================================================
# Project
# =============================================================================

const DEFAULT_IMPORT_META_PATH := "res://storyflow/storyflow_import_meta.json"

var _project: StoryFlowProject = null
var _global_variables: Dictionary = {}
var _runtime_characters: Dictionary = {}
var _used_once_only_options: Dictionary = {}
var _active_dialogue_count: int = 0

## .sfd Data Asset SEED (engine contract 3): asset_id → definition, built from the project.
## Read-only once built — nothing anywhere writes into it.
var _data_asset_seed: Dictionary = {}

## .sfd Data Asset session OVERLAY: asset_id → { variable_id → StoryFlowVariant }.
## Script writes only; cleared on a game reset.
##
## BOTH are assigned ONCE, here at declaration, and MUTATED IN PLACE forever - never rebound.
## A running dialogue's execution context holds a reference to each (handed out at dialogue
## start), so rebinding on a project change or a reset would strand it on the pre-reset object,
## splitting reads and writes into two divergent stores for the rest of the session. That is
## exactly the bug rebinding _global_variables caused before v1.2.3.
var _data_asset_overlay: Dictionary = {}


func _ready() -> void:
	_auto_load_project()


## Attempt to load the project from the local copy in the output directory.
func _auto_load_project() -> void:
	if not FileAccess.file_exists(DEFAULT_IMPORT_META_PATH):
		return

	var file := FileAccess.open(DEFAULT_IMPORT_META_PATH, FileAccess.READ)
	if not file:
		return

	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_warning("[StoryFlow] Failed to parse import metadata")
		return

	var meta: Dictionary = json.data
	var output_dir: String = meta.get("output_dir", "")
	if output_dir.is_empty():
		output_dir = DEFAULT_IMPORT_META_PATH.get_base_dir()

	# Load from the local copy inside the project (output_dir IS the build dir now)
	var importer := StoryFlowImporter.new()
	var project := importer.load_project_local(output_dir)
	if project:
		set_project(project)
		print("[StoryFlow] Project loaded: %s (%d scripts)" % [project.title, project.scripts.size()])


# =============================================================================
# Project Access
# =============================================================================

func get_project() -> StoryFlowProject:
	return _project


func set_project(project: StoryFlowProject) -> void:
	_project = project
	if _project:
		_initialize_from_project()


func has_project() -> bool:
	return _project != null


func get_storyflow_script(path: String) -> StoryFlowScript:
	if _project:
		return _project.get_storyflow_script(path)
	return null


func get_all_script_paths() -> PackedStringArray:
	if _project:
		return _project.get_all_script_paths()
	return PackedStringArray()


# =============================================================================
# Global Variables
# =============================================================================

func get_global_variables() -> Dictionary:
	return _global_variables


func set_global_variable(var_id: String, value: StoryFlowVariant) -> void:
	if _global_variables.has(var_id):
		_global_variables[var_id]["value"] = value


func get_global_variable(var_id: String) -> Dictionary:
	return _global_variables.get(var_id, {})


func reset_global_variables() -> void:
	if _project:
		# Mutate IN PLACE - never rebind. A running dialogue's evaluator holds
		# a reference to this dictionary (handed out by get_global_variables at
		# dialogue start); rebinding would strand it on the pre-reset object,
		# splitting reads and writes into two divergent variable stores for the
		# rest of the session. Triggered in practice by a "Reset Game" fired
		# from a dialogue tag mid-session (the example's main menu does this).
		var fresh: Dictionary = StoryFlowVariant.deep_copy_variables(_project.global_variables)
		_global_variables.clear()
		for var_id in fresh:
			_global_variables[var_id] = fresh[var_id]


# =============================================================================
# Data Assets
# =============================================================================

## The .sfd seed table, handed to a starting dialogue by reference. Never write into it.
func get_data_asset_seed() -> Dictionary:
	return _data_asset_seed


## The .sfd session overlay, handed to a starting dialogue by reference. Script writes land
## here through StoryFlowDataAssetStore.try_set.
func get_data_asset_overlay() -> Dictionary:
	return _data_asset_overlay


## Rebuild the seed from the project and drop every session write (contract 3 reset).
## Both dictionaries are mutated in place - see their declarations.
##
## Safe mid-dialogue for the same reason reset_all_state is, and by the same mechanism: a running
## execution context holds these two objects by reference, so it observes the rebuild instead of
## being stranded on a pre-reset copy. Accessors bound to the rebuilt seed simply read authored
## values again on their next pull.
func reset_data_assets() -> void:
	if _project:
		StoryFlowDataAssetStore.build_seed(_project, _data_asset_seed)
	StoryFlowDataAssetStore.reset_overlay(_data_asset_overlay)


# =============================================================================
# Runtime Characters
# =============================================================================

func get_runtime_characters() -> Dictionary:
	return _runtime_characters


func get_runtime_character(character_path: String) -> StoryFlowCharacter:
	var normalized := StoryFlowCharacter.normalize_path(character_path)
	return _runtime_characters.get(normalized, null)


func reset_runtime_characters() -> void:
	if _project:
		_runtime_characters.clear()
		for path in _project.characters:
			var original: StoryFlowCharacter = _project.characters[path]
			_runtime_characters[path] = original.duplicate_character()


# =============================================================================
# Once-Only Options
# =============================================================================

func get_used_once_only_options() -> Dictionary:
	return _used_once_only_options


func mark_option_used(key: String) -> void:
	_used_once_only_options[key] = true


func is_option_used(key: String) -> bool:
	return _used_once_only_options.has(key)


# =============================================================================
# Active Dialogue Tracking
# =============================================================================

func is_dialogue_active() -> bool:
	return _active_dialogue_count > 0


func register_dialogue_start() -> void:
	_active_dialogue_count += 1


func register_dialogue_end() -> void:
	_active_dialogue_count = maxi(0, _active_dialogue_count - 1)


# =============================================================================
# Save / Load
# =============================================================================

func save_to_slot(slot_name: String) -> bool:
	return StoryFlowSaveData.save_to_slot(
		slot_name, _global_variables, _runtime_characters, _used_once_only_options,
		_data_asset_seed, _data_asset_overlay
	)


## Restore a save of either dialect (the reader sniffs; see StoryFlowSaveData._sniff_dialect).
##
## EVERY store is mutated IN PLACE - never rebound. The dictionaries here are handed out by
## reference at dialogue start (and to any host holding get_global_variables), so rebinding one
## strands every live reference on the pre-load object, splitting reads and writes into two
## divergent stores for the rest of the session. That was the v1.2.3 bug in reset_global_variables
## and it lived on this function's global-variable line until the v1 unification.
##
## THE FOUR SECTIONS SPLIT INTO TWO KINDS, and the split is deliberate:
##
##  - GLOBALS and CHARACTERS take VALUES onto the records the project already declares. The
##    declaration is the project's to own: enum value lists, the input/output flags and the map
##    K/V metadata all come from the import and none of them are state a save has any business
##    rewriting. A save that predates a newly added variable therefore leaves it alone instead of
##    deleting it, and an id the project no longer declares is dropped.
##  - ONCE-ONLY OPTIONS and the .sfd OVERLAY are REPLACED wholesale. Each is one complete SET
##    rather than a collection of independent entries: an option key absent from the save means
##    the player has not used it, and an overlay entry absent from the save means that variable
##    is back on seed state. Merging either would let the pre-load session leak into the loaded
##    game, which for the overlay is contract 7's replace-not-merge rule verbatim.
func load_from_slot(slot_name: String) -> bool:
	# The .sfd overlay's typing needs the live seed, so it is handed to the reader rather than
	# applied afterwards.
	#
	# NO EVALUATOR CACHE IS CLEARED after this load, and that is a determination rather than an
	# omission. It rests on ONE invariant: a count of zero means no component is holding a live
	# evaluator. That holds because every path that changes the count goes through
	# StoryFlowComponent, and each one keeps the two in step:
	#
	#   start_dialogue_with_script  releases any registration it already holds BEFORE taking a
	#                               new one, then builds the evaluator it will be counted with
	#   stop_dialogue               _end_dialogue_registration: nulls the evaluator, decrements
	#   _exit_tree                  the same _end_dialogue_registration, same order
	#
	# and because NOTHING ELSE writes the count - _initialize_from_project deliberately does not
	# zero it, which would otherwise let a load land behind a component that is still running.
	# Host WRITES are a different story and do clear - see the data-asset setters on
	# StoryFlowComponent.
	if is_dialogue_active():
		push_warning("[StoryFlow] Cannot load while dialogue is active")
		return false

	var data := StoryFlowSaveData.load_from_slot(slot_name, _data_asset_seed)
	if data.is_empty():
		return false

	# Global variables: values only, onto the records already there.
	var saved_globals: Dictionary = data.get("global_variables", {})
	for var_id in saved_globals:
		if _global_variables.has(var_id):
			_global_variables[var_id]["value"] = saved_globals[var_id].get("value", null)

	# Runtime characters: saved variable values merged into the existing characters, plus the
	# display name and portrait when the document carries them (a legacy save does not, and
	# their absence means keep the current ones).
	var saved_chars: Dictionary = data.get("runtime_characters", {})
	for path in saved_chars:
		if not _runtime_characters.has(path):
			continue
		var character: StoryFlowCharacter = _runtime_characters[path]
		var saved: Dictionary = saved_chars[path]
		if saved.has("name"):
			character.character_name = saved["name"]
		if saved.has("image"):
			character.image_key = saved["image"]
		var saved_vars: Dictionary = saved.get("variables", {})
		for vname in saved_vars:
			if character.variables.has(vname):
				character.variables[vname]["value"] = saved_vars[vname].get("value", null)

	# Once-only options: the saved set IS the complete set, so this replaces rather than merges.
	_used_once_only_options.clear()
	var saved_once_only: Dictionary = data.get("used_once_only_options", {})
	for key in saved_once_only:
		_used_once_only_options[key] = true

	# .sfd overlay: REPLACE, not merge (contract 7). Clearing unconditionally means an absent or
	# malformed key - and every legacy save, which carries none - restores seed state.
	StoryFlowDataAssetStore.reset_overlay(_data_asset_overlay)
	var saved_assets: Dictionary = data.get("data_assets", {})
	for asset_id in saved_assets:
		_data_asset_overlay[asset_id] = saved_assets[asset_id]

	return true


func does_save_exist(slot_name: String) -> bool:
	return StoryFlowSaveData.does_save_exist(slot_name)


func delete_save(slot_name: String) -> void:
	StoryFlowSaveData.delete_save(slot_name)


func list_save_slots() -> PackedStringArray:
	return StoryFlowSaveData.list_save_slots()


# =============================================================================
# Reset
# =============================================================================

## Restore every store to the project's authored state (a new game).
##
## MID-DIALOGUE IS SUPPORTED, deliberately, and this is the one place where reset and LOAD part
## company. load_from_slot refuses while a dialogue is active because it replaces state wholesale
## from a file and cannot reason about what a running graph has already read. A reset has no such
## problem: it restores the values the running script was authored against, in place, so a live
## evaluator observes the reset rather than being stranded beside it. That is not a tolerated
## edge case but the shipped one - the example project's main menu fires a Reset Game tag from
## inside a dialogue node, which is what v1.2.3 fixed and what tests/test_reset_in_place.gd pins.
##
## Adding an is_dialogue_active guard here would therefore break the example project, not protect
## it. What a host DOES need to know: a reset does not stop the running dialogue. Call
## StoryFlowComponent.stop_dialogue first if the intent is to end the story too, not only to
## rewind its state.
func reset_all_state() -> void:
	reset_global_variables()
	reset_runtime_characters()
	reset_data_assets()
	_used_once_only_options.clear()


# =============================================================================
# Internal
# =============================================================================

## Install a project's authored state as the session's starting state.
##
## Every store here is mutated IN PLACE for the same reason reset_global_variables is: set_project
## is reachable mid-dialogue (a host swapping projects, and the editor's WebSocket sync does it on
## every re-import), and a running dialogue's evaluator holds these dictionaries by reference from
## dialogue start. The globals line used to rebind, which is the v1.2.3 stranding bug surviving on
## the one path nobody had walked - the .sfd seed and overlay beside it were already in-place, so
## a project swap left globals split in two while data assets stayed whole.
func _initialize_from_project() -> void:
	var fresh: Dictionary = StoryFlowVariant.deep_copy_variables(_project.global_variables)
	_global_variables.clear()
	for var_id in fresh:
		_global_variables[var_id] = fresh[var_id]

	_runtime_characters.clear()
	for path in _project.characters:
		var original: StoryFlowCharacter = _project.characters[path]
		_runtime_characters[path] = original.duplicate_character()

	reset_data_assets()

	_used_once_only_options.clear()
	# _active_dialogue_count is deliberately NOT zeroed here. A registration belongs to the
	# COMPONENT that took it, not to the project: zeroing it behind a component that is still
	# running would leave that component's eventual stop decrementing a count it no longer owns,
	# and - worse - would let a save load land while a live evaluator is holding memoized reads,
	# falsifying the one invariant load_from_slot's no-cache-clear reasoning rests on. Component
	# lifecycles balance the count on their own now (StoryFlowComponent._counted_dialogue_start),
	# so there is no stale count left for this line to clean up.

