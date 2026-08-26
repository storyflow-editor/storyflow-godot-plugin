extends Node

# Preloaded by path so parsing never depends on the global class name cache,
# which can be stale or mid-rewrite when the game launches (godotengine/godot#75388).
const StoryFlowCharacter = preload("res://addons/storyflow/core/storyflow_character.gd")
const StoryFlowDataAssetStore = preload("res://addons/storyflow/core/storyflow_data_asset_store.gd")
const StoryFlowImporter = preload("res://addons/storyflow/editor/storyflow_importer.gd")
const StoryFlowLocalization = preload("res://addons/storyflow/core/storyflow_localization.gd")
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

## P4 character id bridge: character FILE id (da_<32 hex>) → _runtime_characters key, copied
## verbatim from the project's character_id_index (characters engine contract §3).
##
## Assigned ONCE here and MUTATED IN PLACE forever - never rebound - for the same reason the
## .sfd seed and overlay below are: a running dialogue's execution context holds this by
## reference from dialogue start, and rebinding on a project change or reset would strand it
## on the pre-reset object, splitting reads into two divergent stores. That is exactly the
## bug rebinding _global_variables caused before v1.2.3.
##
## Refreshed exactly where _runtime_characters refills (reset_runtime_characters, which
## _initialize_from_project delegates to) and NEVER by a save load - the bridge is import
## state, not player state, so load_from_slot must not touch it.
var _character_id_bridge: Dictionary = {}

## The translations sidecar plus the player's chosen language (localization spec §9).
##
## Assigned ONCE here and MUTATED IN PLACE forever - never rebound - for the same reason the id
## bridge above and the .sfd pair below are: a running dialogue's execution context holds this by
## reference from dialogue start, so rebinding on a project change or a reset would strand it on
## the pre-change object and split the game into two languages mid-sentence.
##
## Refreshed exactly where the project is installed (_initialize_from_project) and NEVER by a save
## load or a state reset - see set_language for why the player's choice outlives both.
var _localization: StoryFlowLocalization = StoryFlowLocalization.new()

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

## Claimed "asset|variable|kind" keys for the .sfd HOST ACCESSOR refusals on StoryFlowComponent.
##
## THE LATCH IS HERE, not on the component, for two reasons. A host that rebuilds or reparents a
## component - a scene change, a pooled dialogue box - would otherwise re-arm every warning it
## already emitted, which is the flood this exists to stop. And any future manager-side .sfd
## surface joins the same latch instead of growing a second one.
##
## RE-ARMED ON set_project AND reset_all_state, and nowhere else. Those are the two points where
## the answer to "is this name wrong?" can genuinely have changed: a re-import after a rename, or
## a new game. A re-sync that fixes one name should be free to warn about a different one.
##
## This dictionary and the counter below are INSPECTABLE ON PURPOSE, for the same reason the
## execution context's node-ladder pair is: Godot's push_warning cannot be captured from a
## SceneTree test, so the latch proves WHICH refusals warned and the counter proves HOW MANY
## TIMES - which is the whole difference between a working once-latch and a per-call warning.
var warned_data_asset_access: Dictionary = {}

## How many host-accessor warnings have actually been emitted since the last re-arm.
var data_asset_access_warnings_emitted: int = 0


## Claim the warn latch for one refused host access, reporting whether the CALLER should warn.
##
## Keyed by (asset, variable, kind) so a stale name that is wrong in two different ways names
## both, and so two different variables on one asset are not silenced by each other. The caller
## formats and pushes the message inside the `if`, which keeps the suppressed path allocation
## free - the same shape as the node ladder's should_warn_data_asset.
##
## The BOOLEAN RETURNS of the accessors themselves are untouched by any of this: a refused call
## still answers its default or false on every call, latched or not. Only the log line is once.
func should_warn_data_asset_access(asset: String, variable_name: String, kind: String) -> bool:
	var key := "%s|%s|%s" % [asset, variable_name, kind]
	if warned_data_asset_access.has(key):
		return false
	warned_data_asset_access[key] = true
	data_asset_access_warnings_emitted += 1
	return true


## Re-arm every host-accessor warning. Called where the project or the session changes under it.
func reset_data_asset_access_warnings() -> void:
	warned_data_asset_access.clear()
	data_asset_access_warnings_emitted = 0


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
## being stranded on a pre-reset copy.
##
## WITH ONE BOUND, and it is the same one _handle_set_data_asset_var clears the evaluator cache
## for: an accessor re-reads the rebuilt seed on its next pull, but a memoized boolean PARENT
## above it does not recompute on its own. A reset that lands while a dialogue is parked on a
## rendered node therefore leaves the options currently on screen showing pre-reset visibility
## until the next advance or option selection, both of which clear the cache on their way through.
## Nothing reads a stale value after that point.
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
		# The id bridge rides with the characters it points into: in place (see its
		# declaration), values verbatim. THE ONE refill site - _initialize_from_project
		# delegates here rather than repeating the block.
		_character_id_bridge.clear()
		for id in _project.character_id_index:
			_character_id_bridge[id] = _project.character_id_index[id]


## The P4 character id bridge, handed to a starting dialogue by reference. Never write into it.
func get_character_id_bridge() -> Dictionary:
	return _character_id_bridge


## Claimed "id|reason" keys for the character-id HOST-LANE warnings (characters engine
## contract §3). Same design as warned_data_asset_access above, and on the manager for the
## same two reasons: a host that rebuilds or reparents a component must not re-arm warnings
## it already emitted, and every host-side character-id surface joins this one latch. The
## reason vocabulary: "dangling" (an id with no bridge entry) and "unloaded" (a bridge hit
## whose record is missing from _runtime_characters).
##
## RE-ARMED ON set_project AND reset_all_state, and nowhere else - the two points where the
## answer to "is this id wrong?" can genuinely have changed. Inspectable on purpose, like
## the .sfd pair: Godot's push_warning cannot be captured from a SceneTree test, so the
## latch proves WHICH ids warned and the counter proves HOW MANY TIMES.
var warned_character_id_access: Dictionary = {}

## How many host-lane character-id warnings have actually been emitted since the last re-arm.
var character_id_access_warnings_emitted: int = 0


## Claim the warn latch for one degraded host-lane id resolution, reporting whether the
## CALLER should warn. The caller formats and pushes the message inside the `if`, which
## keeps the suppressed path allocation free - the same shape as
## should_warn_data_asset_access above.
func should_warn_character_id_access(id: String, reason: String) -> bool:
	var key := "%s|%s" % [id, reason]
	if warned_character_id_access.has(key):
		return false
	warned_character_id_access[key] = true
	character_id_access_warnings_emitted += 1
	return true


## Re-arm every host-lane character-id warning. Called exactly where the .sfd access pair
## re-arms: set_project (via _initialize_from_project) and reset_all_state.
func reset_character_id_access_warnings() -> void:
	warned_character_id_access.clear()
	character_id_access_warnings_emitted = 0


# =============================================================================
# Localization (spec §9) - the player's language, game-wide
# =============================================================================
#
# ONE SURFACE, not the mirrored pair the .sfd and character sections above carry. The language is
# a single game-wide value rather than per-record state, so a second door on StoryFlowComponent
# would be two names for one field - the component keeps only its pre-localization language_code
# export, which a localized project ignores.


## The localization state, handed to a starting dialogue by reference. Never rebind it; write to
## it only through set_language.
func get_localization() -> StoryFlowLocalization:
	return _localization


## Switch the language every StoryFlow string is read in. True when the game is now reading
## [param language_code].
##
## AN UNKNOWN OR EMPTY CODE IS A NO-OP: it warns, changes nothing and returns false. Falling back
## to the default instead would let a typo silently move the player out of the language they
## picked, and a caller that wants to know can read [method get_language]. The codes accepted are
## exactly the rows [method get_languages] returns, matched case-insensitively with the REGISTERED
## casing winning (StoryFlowLocalization.resolve_code, the one resolve point this shares with the
## project install). A project with no localization sidecar accepts only its source language, so
## this is a no-op there by construction rather than by a special case.
##
## WHAT MOVES, AND WHEN. Everything this plugin resolves AT READ TIME follows immediately -
## dialogue titles, text, text blocks, option labels, string and enum variable values, character
## string variables, map and array elements, AND character display names, which this engine stores
## as string-table keys on the runtime record and resolves per read. THE SEED-TIME POSTURE (ruled
## at LD2): a value a running script has already WRITTEN into live state - a Set String node, a
## SetCharacterVar - was resolved in the language current at the moment of the write and stays
## that text; a mid-session switch reaches those only at the next reset or dialogue start, which
## re-seeds them from the project. Exact mid-session re-seeding would need write-tracking to avoid
## clobbering the player's own progress, and is deliberately not built.
##
## PERSISTENCE IS THE GAME'S. This plugin keeps the choice for the SESSION only, and deliberately:
## the unified v1 save envelope carries the story state a slot owns (globals, characters,
## once-only options, the .sfd overlay) and is byte-shape-shared with the Unreal and Unity
## plugins - a language is not that kind of thing. It must survive with no save file at all, apply
## before any save is loaded, and not differ per slot. The HTML runtime reaches the same
## conclusion and keeps it beside its volume settings rather than in the envelope. In Godot the
## settings lane already exists and belongs to the game: persist the code yourself (a ConfigFile
## in user://, your own options screen) and call this once at boot, before the first dialogue.
func set_language(language_code: String) -> bool:
	var next := _localization.resolve_code(language_code)
	if next.is_empty():
		push_warning("[StoryFlow] set_language: unknown language '%s' - staying on '%s'" % [language_code, _localization.active_language])
		return false

	if next != _localization.active_language:
		_localization.active_language = next
		print("[StoryFlow] Language set to '%s'" % next)
	return true


## The language code every StoryFlow string is currently read in. The loaded project's source
## language until set.
func get_language() -> String:
	return _localization.active_language


## Every language the player can be switched to as `[{ "code", "name" }]`: the SOURCE language
## first, then the author's registry order - the list a game's own picker draws. EMPTY for a
## project with no localization sidecar, which is how a game asks "is this project localized at
## all" without reading a key count.
func get_languages() -> Array:
	return _localization.get_roster()


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
	reset_data_asset_access_warnings()
	reset_character_id_access_warnings()
	_used_once_only_options.clear()
	# The active language is deliberately NOT reset (localization spec §9): it is a player SETTING
	# rather than story state, so it outlives a new game exactly as it outlives a save load.


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
	# THE LANGUAGE FIRST, because everything seeded below is read in it. The install replaces the
	# tables wholesale (never appends) and carries the player's choice forward when the new project
	# still ships it - see StoryFlowLocalization.install_from_project.
	_localization.install_from_project(_project)

	var fresh: Dictionary = StoryFlowVariant.deep_copy_variables(_project.global_variables)
	_global_variables.clear()
	for var_id in fresh:
		_global_variables[var_id] = fresh[var_id]

	reset_runtime_characters()

	reset_data_assets()
	# A re-import is exactly when a name that was wrong may have become right, so the host
	# accessor warnings re-arm with the project rather than surviving it.
	reset_data_asset_access_warnings()
	reset_character_id_access_warnings()

	_used_once_only_options.clear()
	# _active_dialogue_count is deliberately NOT zeroed here. A registration belongs to the
	# COMPONENT that took it, not to the project: zeroing it behind a component that is still
	# running would leave that component's eventual stop decrementing a count it no longer owns,
	# and - worse - would let a save load land while a live evaluator is holding memoized reads,
	# falsifying the one invariant load_from_slot's no-cache-clear reasoning rests on. Component
	# lifecycles balance the count on their own now (StoryFlowComponent._counted_dialogue_start),
	# so there is no stale count left for this line to clean up.

