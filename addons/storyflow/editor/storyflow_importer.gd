class_name StoryFlowImporter
extends RefCounted

# Preloaded by path so parsing never depends on the global class name cache,
# which can be stale or mid-rewrite when the game launches (godotengine/godot#75388).
const StoryFlowCharacter = preload("res://addons/storyflow/core/storyflow_character.gd")
const StoryFlowDataAssetStore = preload("res://addons/storyflow/core/storyflow_data_asset_store.gd")
const StoryFlowProject = preload("res://addons/storyflow/core/storyflow_project.gd")
const StoryFlowScript = preload("res://addons/storyflow/core/storyflow_script.gd")
const StoryFlowTypes = preload("res://addons/storyflow/core/storyflow_types.gd")
const StoryFlowVariant = preload("res://addons/storyflow/core/storyflow_variant.gd")
## JSON importer for StoryFlow project and script files exported by the
## StoryFlow Editor.  Reads the build directory structure, creates
## StoryFlowProject / StoryFlowScript / StoryFlowCharacter resources and
## optionally copies media assets into the Godot project.

## Metadata file the manager reads to auto-discover a previously imported project.
const IMPORT_META_FILENAME := "storyflow_import_meta.json"

## Suffix of the staging file used to publish the metadata atomically.
const IMPORT_META_TEMP_SUFFIX := ".tmp"

## Non-fatal write failures recorded during the current import: media copies,
## build-directory copies, directory creation and the metadata write. The editor
## dock reports the total so a partially failed sync is not shown as a success.
var _error_count: int = 0

## Source paths (simplified) already published under output_dir by this import —
## media handled by [method _import_media_assets] and the project file handled by
## [method _publish_project_file] — used as a set. The blanket copy of the build
## directory skips them so each file is written once per import, at the path the
## runtime actually reads.
var _copied_sources: Dictionary = {}

## Paths (simplified) this import published under output_dir, used as a set. The
## blanket copy must never mistake one of them for a redundant duplicate: when an
## asset's build-relative directory is itself named images/, audio/ or media/,
## the blanket destination IS the file the asset import just wrote — and the
## published project.json must never be deleted in favor of a stale build-side
## copy of the same name.
var _published_targets: Dictionary = {}

## Destination root of the current import, never removed by the duplicate cleanup.
var _output_root: String = ""

# =============================================================================
# Public API
# =============================================================================

## Number of non-fatal write failures recorded during the last [method import_project].
## Each one was also pushed as an error, so the Output log holds the details.
func get_error_count() -> int:
	return _error_count

## Import a full StoryFlow project from an exported build directory.
##
## [param build_dir] Absolute path to the build folder (contains project.storyflow).
## [param output_dir] Godot res:// path where imported resources will be saved.
## Returns the imported [StoryFlowProject], or [code]null[/code] on failure.
func import_project(build_dir: String, output_dir: String) -> StoryFlowProject:
	_error_count = 0
	_copied_sources.clear()
	_published_targets.clear()
	_output_root = output_dir

	# Read project.storyflow (or project.json for backwards compat)
	var project_file := build_dir.path_join("project.storyflow")
	var project_json: Dictionary = _load_json_file(project_file)
	if project_json.is_empty():
		project_file = build_dir.path_join("project.json")
		project_json = _load_json_file(project_file)
	if project_json.is_empty():
		push_error("StoryFlow: Failed to load project file from %s" % build_dir)
		return null

	var project := StoryFlowProject.new()

	# ------------------------------------------------------------------
	# Basic fields
	# ------------------------------------------------------------------
	project.version = project_json.get("version", "")
	project.api_version = project_json.get("apiVersion", "")
	project.startup_script = _normalize_script_path(project_json.get("startupScript", ""))

	# Metadata
	var metadata: Dictionary = project_json.get("metadata", {})
	project.title = metadata.get("title", "")
	project.description = metadata.get("description", "")
	project.max_script_nesting = StoryFlowProject.normalize_max_script_nesting(metadata.get("maxScriptNesting"))
	project.dialogue_rollback = preload("res://addons/storyflow/core/storyflow_rollback_settings.gd").normalize(metadata.get("dialogueRollback"))

	# ------------------------------------------------------------------
	# Global variables  (may be inline in project or in a separate file)
	# ------------------------------------------------------------------
	if project_json.has("globalVariables"):
		project.global_variables = _parse_variables(project_json["globalVariables"])

	# Separate global-variables.json file (new export format)
	var global_vars_json: Dictionary = _load_json_file(build_dir.path_join("global-variables.json"))
	if not global_vars_json.is_empty():
		if global_vars_json.has("variables"):
			var extra_vars := _parse_variables(global_vars_json["variables"])
			for key in extra_vars:
				project.global_variables[key] = extra_vars[key]
		if global_vars_json.has("strings"):
			var extra_strings := _flatten_strings(global_vars_json["strings"])
			for key in extra_strings:
				project.global_strings[key] = extra_strings[key]
		# Global image/audio variable assets live in this file's own "assets" section
		# (json-export-strategy addAsset). Import them into the project pool — the shared
		# final fallback for both image and audio resolution — so a global Image/Audio
		# variable's asset key resolves at runtime instead of showing the default.
		if global_vars_json.has("assets"):
			var global_assets := _parse_assets_dict(global_vars_json["assets"])
			_import_media_assets(build_dir, output_dir, global_assets, project.resolved_assets)

	# ------------------------------------------------------------------
	# Global strings  (inline)
	# ------------------------------------------------------------------
	if project_json.has("globalStrings"):
		var flattened := _flatten_strings(project_json["globalStrings"])
		for key in flattened:
			project.global_strings[key] = flattened[key]

	# ------------------------------------------------------------------
	# Characters
	# ------------------------------------------------------------------
	var characters_json: Dictionary = _load_json_file(build_dir.path_join("characters.json"))
	if not characters_json.is_empty():
		# Merge character strings into global strings
		if characters_json.has("strings"):
			var char_strings := _flatten_strings(characters_json["strings"])
			for key in char_strings:
				if project.global_strings.has(key):
					push_warning("StoryFlow: Character string key '%s' overwrites existing global string" % key)
				project.global_strings[key] = char_strings[key]

		# Parse character asset metadata for media import
		var character_media_assets: Dictionary = {}
		if characters_json.has("assets"):
			character_media_assets = _parse_assets_dict(characters_json["assets"])

		# Import ALL character-scoped media into the project pool. This "assets" dict holds
		# the portraits AND the custom image/audio-typed character-variable and character-map
		# values. project.resolved_assets is the shared final fallback for both image
		# (component) and audio (audio controller) resolution — and audio has no
		# character-level pool, so those assets MUST land here to resolve at all.
		_import_media_assets(build_dir, output_dir, character_media_assets, project.resolved_assets)

		# Create per-character resources
		if characters_json.has("characters"):
			var chars_dict: Dictionary = characters_json["characters"]
			for char_path in chars_dict:
				var char_data: Dictionary = chars_dict[char_path]
				if char_data.is_empty():
					continue

				var character := StoryFlowCharacter.new()
				var normalized_path := StoryFlowCharacter.normalize_path(char_path)
				character.character_path = normalized_path
				character.character_name = char_data.get("name", "")
				character.image_key = char_data.get("image", "")

				if char_data.has("variables"):
					character.variables = _parse_character_variables(char_data["variables"])

				# The portrait is checked in the character pool first at runtime. Reuse the
				# resource already imported into the project pool above instead of copying
				# and decoding the same file a second time.
				if character.image_key != "" and project.resolved_assets.has(character.image_key):
					character.resolved_assets[character.image_key] = project.resolved_assets[character.image_key]

				project.characters[normalized_path] = character
				print("StoryFlow: Imported character '%s'" % char_path)

	# ------------------------------------------------------------------
	# Character index (character-index.json, P4)
	# ------------------------------------------------------------------
	# Source of the character id bridge (characters engine contract §3): character FILE id
	# -> characters.json record key. An ABSENT file is a pre-P4 export and stays silent -
	# everything resolves by path, exactly as before this file existed. Everything else is
	# _parse_character_index's degraded ladder, shared with the inline arm below.
	var character_index_file := build_dir.path_join("character-index.json")
	if FileAccess.file_exists(character_index_file):
		project.character_id_index = _parse_character_index(_load_json_file(character_index_file))

	# ------------------------------------------------------------------
	# Localization (localization.json, §9)
	# ------------------------------------------------------------------
	# THE TRANSLATIONS SIDECAR, on the same degraded ladder as the character index above and for
	# the same reason: absence is a FORMAT VERSION, not a fault.
	#
	# THE FILE-PRESENCE MARKER is the only branch this contract has. No localization.json beside
	# the artifacts means a pre-localization export - source-only, byte-for-byte the behavior of
	# every release before this one - and never a count of anything: a project whose author
	# registered a language and translated nothing still exports FULL tables of source text, and
	# that is a localized project. _apply_localization records which of the two a project is,
	# because an absent sidecar and a sidecar with no rows parse to the same empty Dictionary.
	var localization_file := build_dir.path_join("localization.json")
	if FileAccess.file_exists(localization_file):
		_apply_localization(project, _load_json_file(localization_file))

	# ------------------------------------------------------------------
	# Data Assets (.sfd)
	# ------------------------------------------------------------------
	# Written beside characters.json, always (an empty object when the project references
	# none). TRUSTED SEED: the editor's collector already stripped orphan and stale
	# overrides and collapsed duplicate map keys, so nothing here re-validates or
	# re-sanitizes — a plugin that "fixes" the seed diverges from the other three runtimes
	# (engine contract 2.1).
	#
	# IT IS A KEYING ARTIFACT NOW. Localization spec §2's amendment of 2026-08-27 SUPERSEDES
	# engine-contract 2.1's literal-value posture: a Data Asset's DECLARED string values are
	# player-facing prose and ship as stable table keys in data-assets.json's own "strings"
	# block. What is stored in the seed is still the verbatim bytes the exporter wrote — the
	# lookup happens at the READ DOOR, and only for values whose PROVENANCE says they are
	# content (StoryFlowDataAssetStore.try_read).
	var data_assets_json: Dictionary = _load_json_file(build_dir.path_join("data-assets.json"))
	if not data_assets_json.is_empty():
		project.data_asset_localization_version = _data_asset_localization_version(data_assets_json)
		# data-assets.json's OWN strings table, merged into the project's global table exactly
		# as characters.json's is above — same helper, same `<code>.<key>` shape, same collision
		# warning. It is the SOURCE TIER the .sfd read door falls through to when the language
		# being read carries no row for an id. ABSENT for a pre-amendment export, and then every
		# .sfd value is its own text again, with no branch for it.
		if data_assets_json.has("strings"):
			var data_asset_strings := _flatten_strings(data_assets_json["strings"])
			for key in data_asset_strings:
				if project.global_strings.has(key):
					push_warning("StoryFlow: Data Asset string key '%s' overwrites existing global string" % key)
				project.global_strings[key] = data_asset_strings[key]
		# .sfd media (contract §2.1's 2026-09-04 amendment): image and audio values ship as asset
		# KEYS with their files beside them, so this artifact carries an "assets" registry of its
		# own exactly as characters.json does above. Imported into the PROJECT pool - the shared
		# final fallback for both image and audio resolution - which is what makes a key handed
		# back by get_data_asset_string resolve to something the build actually contains.
		# ABSENT for a pre-amendment export, and then .sfd media is a bare path again with no
		# branch for it, like the strings table above.
		if data_assets_json.has("assets"):
			var data_asset_media := _parse_assets_dict(data_assets_json["assets"])
			_import_media_assets(build_dir, output_dir, data_asset_media, project.resolved_assets)
		project.data_assets = _parse_data_assets(data_assets_json.get("dataAssets", {}))

	# ------------------------------------------------------------------
	# Scripts – inline in project JSON
	# ------------------------------------------------------------------
	if project_json.has("scripts"):
		var scripts_dict: Dictionary = project_json["scripts"]
		for script_path_raw in scripts_dict:
			var script_path := _normalize_script_path(script_path_raw)
			var script_data: Dictionary = scripts_dict[script_path_raw]
			if script_data.is_empty():
				continue

			var script := import_script(script_data)
			if script:
				script.script_path = script_path
				_import_media_assets(build_dir, output_dir, script.assets, script.resolved_assets)
				_pool_script_assets(project, script)
				project.scripts[script_path] = script

	# ------------------------------------------------------------------
	# Scripts – standalone .json files in build directory
	# ------------------------------------------------------------------
	var script_files := _find_json_files_recursive(build_dir)
	for script_file in script_files:
		var filename := script_file.get_file()
		# Skip non-script files. EVERY sidecar the export writes must be listed here:
		# load_project_local re-runs this sweep on every launch, so an unlisted sidecar is
		# imported as a phantom script named after its filename, silently, in shipped games.
		if filename in ["project.json", "project.storyflow", "global-variables.json", "characters.json", "data-assets.json", "character-index.json", "localization.json", IMPORT_META_FILENAME]:
			continue

		var relative := _make_relative(script_file, build_dir)
		var script_path := _normalize_script_path(relative)

		# Skip if already imported from inline
		if project.scripts.has(script_path):
			continue

		var script_json := _load_json_file(script_file)
		if script_json.is_empty():
			continue

		var script := import_script(script_json)
		if script:
			script.script_path = script_path
			_import_media_assets(build_dir, output_dir, script.assets, script.resolved_assets)
			_pool_script_assets(project, script)
			project.scripts[script_path] = script

	# ------------------------------------------------------------------
	# Copy all build files into the output directory (skip if same path)
	# ------------------------------------------------------------------
	var norm_build := build_dir.replace("\\", "/").rstrip("/")
	var norm_output := output_dir.replace("\\", "/").rstrip("/")
	_publish_project_file(project_file, build_dir, output_dir)
	if norm_build != norm_output:
		_copy_directory_recursive(build_dir, output_dir)
		# Reconcile this owned optional sidecar only in a previously imported output.
		# Never remove user files or delete through two spellings of the same directory.
		var source_directory := ProjectSettings.globalize_path(build_dir).simplify_path()
		var output_directory := ProjectSettings.globalize_path(output_dir).simplify_path()
		var old_sidecar := output_dir.path_join("localization.json")
		if source_directory.nocasecmp_to(output_directory) != 0 \
				and not FileAccess.file_exists(localization_file) \
				and FileAccess.file_exists(output_dir.path_join(IMPORT_META_FILENAME)) \
				and FileAccess.file_exists(old_sidecar):
			var remove_error := DirAccess.remove_absolute(old_sidecar)
			if remove_error != OK:
				_error_count += 1
				push_error("StoryFlow: Failed to remove stale localization sidecar: %s" % error_string(remove_error))

	# Save metadata so the manager can reload from the local copy
	if norm_build != norm_output:
		var meta := {
			"output_dir": output_dir,
			"imported_at": Time.get_datetime_string_from_system(),
			"script_paths": Array(project.get_all_script_paths()),
		}
		if write_import_meta(output_dir, meta) != OK:
			_error_count += 1

	print("StoryFlow: Successfully imported project with %d scripts" % project.scripts.size())
	return project


## Publish the project file this import parsed into the output directory under
## the project.json name.
##
## Exported games pack .json files as raw bytes, but a .storyflow file is
## unreadable at runtime either way: unimported it is not packed at all, and
## imported it is replaced by StoryFlowImportPlugin's marker resource (which
## carries no project data). Publishing the data as project.json is what lets
## [code]StoryFlowManager._auto_load_project[/code] find it in an exported game.
##
## Both candidate source names are marked as copied so the blanket copy neither
## writes a raw project.storyflow into the output directory nor overwrites the
## published file with a stale build-side project.json, and so it removes the
## project.storyflow an older plugin version copied there. On a failed copy
## nothing is marked, leaving the blanket verbatim copy as the fallback; the
## failure is already counted by [method _copy_file].
##
## Also runs when build_dir == output_dir (a build dropped straight into the
## output directory, and every load_project_local call): there the copy is
## content-skipped when project.json is already current, which keeps it a no-op
## on the read-only res:// of an exported game.
func _publish_project_file(project_file: String, build_dir: String, output_dir: String) -> void:
	var target := output_dir.path_join("project.json")
	if _copy_file(project_file, target, "project.json") != OK:
		return
	_copied_sources[build_dir.path_join("project.storyflow").simplify_path()] = true
	_copied_sources[build_dir.path_join("project.json").simplify_path()] = true
	_published_targets[target.simplify_path()] = true
	_published_targets[target.simplify_path().to_lower()] = true


## Load a project from a local directory inside the Godot project (e.g. res://storyflow/).
## This is used at runtime/startup to load previously imported data without copying files.
## The local_dir should contain project.json/project.storyflow plus script JSON files.
func load_project_local(local_dir: String) -> StoryFlowProject:
	# Reuse import_project but with local_dir as both source and output (no copy needed)
	return import_project(local_dir, local_dir)


## Import a project from an already-parsed JSON Dictionary (e.g. from WebSocket sync).
##
## Unlike [method import_project], this does not read files from disk or copy media.
## All data (scripts, characters, variables, strings) must be inline in [param project_json].
## Returns the imported [StoryFlowProject], or [code]null[/code] on failure.
func import_project_from_json(project_json: Dictionary) -> StoryFlowProject:
	if project_json.is_empty():
		return null

	var project := StoryFlowProject.new()

	project.version = project_json.get("version", "")
	project.api_version = project_json.get("apiVersion", "")
	project.startup_script = _normalize_script_path(project_json.get("startupScript", ""))

	var metadata: Dictionary = project_json.get("metadata", {})
	project.title = metadata.get("title", "")
	project.description = metadata.get("description", "")
	project.max_script_nesting = StoryFlowProject.normalize_max_script_nesting(metadata.get("maxScriptNesting"))
	project.dialogue_rollback = preload("res://addons/storyflow/core/storyflow_rollback_settings.gd").normalize(metadata.get("dialogueRollback"))

	# Global variables
	if project_json.has("globalVariables"):
		project.global_variables = _parse_variables(project_json["globalVariables"])

	# Global strings
	if project_json.has("globalStrings"):
		var flattened := _flatten_strings(project_json["globalStrings"])
		for key in flattened:
			project.global_strings[key] = flattened[key]

	# Characters (inline)
	if project_json.has("characters"):
		var chars_data = project_json["characters"]
		# Could be nested under a "characters" key or directly be the dict
		var chars_dict: Dictionary = {}
		if chars_data is Dictionary:
			if chars_data.has("characters"):
				chars_dict = chars_data["characters"]
				# Merge character strings
				if chars_data.has("strings"):
					var char_strings := _flatten_strings(chars_data["strings"])
					for key in char_strings:
						project.global_strings[key] = char_strings[key]
			else:
				chars_dict = chars_data

		for char_path in chars_dict:
			var char_data: Dictionary = chars_dict[char_path]
			if char_data.is_empty():
				continue
			var character := StoryFlowCharacter.new()
			var normalized_path := StoryFlowCharacter.normalize_path(char_path)
			character.character_path = normalized_path
			character.character_name = char_data.get("name", "")
			character.image_key = char_data.get("image", "")
			if char_data.has("variables"):
				character.variables = _parse_character_variables(char_data["variables"])
			project.characters[normalized_path] = character

	# Character index (inline). Accepts both the character-index.json document shape and a
	# wrapper nesting, the same way the characters block above and the dataAssets block below
	# accept either. The two cannot be confused: the document's own keys are
	# schemaVersion/characters, so an inner "characterIndex" key is always the wrapper. A
	# bare id -> key map is deliberately refused: it carries no schemaVersion, and accepting
	# one would make this the only lane that skips the version rung. The parse (degraded
	# ladder, verbatim values) is shared with the disk arm - the two arms must never diverge
	# (the divergence lesson test_import_hardening.gd exists for).
	if project_json.has("characterIndex"):
		var index_data = project_json["characterIndex"]
		if index_data is Dictionary and index_data.has("characterIndex"):
			index_data = index_data["characterIndex"]
		project.character_id_index = _parse_character_index(
			index_data if index_data is Dictionary else {})

	# Localization (inline). The presence of the KEY is the marker here, exactly as the presence
	# of the FILE is on the disk arm - an absent key is a pre-localization payload. Accepts the
	# localization.json document shape and a wrapper nesting, like the blocks around it; the two
	# cannot be confused, because the document's own keys are schemaVersion/sourceLanguage/
	# languages/strings, so an inner "localization" key is always the wrapper. The parse (degraded
	# ladder, verbatim rows) is shared with the disk arm - the two arms must never diverge (the
	# divergence lesson test_import_hardening.gd exists for).
	if project_json.has("localization"):
		var localization_data = project_json["localization"]
		if localization_data is Dictionary and localization_data.has("localization"):
			localization_data = localization_data["localization"]
		_apply_localization(project,
			localization_data if localization_data is Dictionary else {})

	# Data assets (inline). Accepts both the flat asset table and the data-assets.json
	# wrapper shape, the same way the characters block above accepts either nesting. The two
	# cannot be confused: asset ids are always da_<32 hex>, so no asset can be keyed
	# "dataAssets", and an inner "dataAssets" key is therefore always the wrapper.
	if project_json.has("dataAssets"):
		var data_assets_data = project_json["dataAssets"]
		if data_assets_data is Dictionary and data_assets_data.has("dataAssets"):
			project.data_asset_localization_version = _data_asset_localization_version(data_assets_data)
			# The WRAPPER shape carries the strings table too, and this arm must merge it for
			# the same reason the disk arm does (localization spec §2's amendment): a .sfd
			# declared string is a key into it. Reached only through the wrapper, because a
			# flat asset table has no table to merge - the same asymmetry the characters block
			# above lives with.
			if data_assets_data.has("strings"):
				var inline_data_asset_strings := _flatten_strings(data_assets_data["strings"])
				for key in inline_data_asset_strings:
					project.global_strings[key] = inline_data_asset_strings[key]
			data_assets_data = data_assets_data["dataAssets"]
		project.data_assets = _parse_data_assets(data_assets_data)

	# Scripts (inline)
	if project_json.has("scripts"):
		var scripts_dict: Dictionary = project_json["scripts"]
		for script_path_raw in scripts_dict:
			var script_path := _normalize_script_path(script_path_raw)
			var script_data: Dictionary = scripts_dict[script_path_raw]
			if script_data.is_empty():
				continue
			var script := import_script(script_data)
			if script:
				script.script_path = script_path
				project.scripts[script_path] = script

	print("StoryFlow: Imported project from sync data with %d scripts" % project.scripts.size())
	return project


## Import a single StoryFlow script from parsed JSON data.
##
## [param json_data] The parsed Dictionary from a script JSON file.
## Returns the imported [StoryFlowScript], or [code]null[/code] on failure.
func import_script(json_data: Dictionary) -> StoryFlowScript:
	if json_data.is_empty():
		return null

	var script := StoryFlowScript.new()

	# Nodes
	if json_data.has("nodes"):
		var nodes_dict: Dictionary = json_data["nodes"]
		for node_id in nodes_dict:
			var node_id_str := str(node_id)
			if node_id_str.is_empty():
				push_warning("StoryFlow: Skipping node with empty ID")
				continue
			var node_obj: Dictionary = nodes_dict[node_id]
			if node_obj.is_empty():
				continue

			var type_string: String = node_obj.get("type", "")
			var node_type: StoryFlowTypes.NodeType = StoryFlowTypes.parse_node_type(type_string)
			var data: Dictionary = _parse_node_data(type_string, node_obj)

			script.nodes[node_id_str] = {
				"id": node_id_str,
				"type": node_type,
				"type_string": type_string,
				"data": data,
			}

	# Connections
	if json_data.has("connections"):
		var connections_array: Array = json_data["connections"]
		for conn_obj in connections_array:
			if not conn_obj is Dictionary:
				continue
			script.connections.append({
				"id": conn_obj.get("id", ""),
				"source": str(conn_obj.get("source", "")),
				"target": str(conn_obj.get("target", "")),
				"source_handle": conn_obj.get("sourceHandle", ""),
				"target_handle": conn_obj.get("targetHandle", ""),
			})

	# Variables
	if json_data.has("variables"):
		script.variables = _parse_variables(json_data["variables"])

	# Strings
	if json_data.has("strings"):
		script.strings = _flatten_strings(json_data["strings"])

	# Assets
	if json_data.has("assets"):
		var assets_raw = json_data["assets"]
		if assets_raw is Array:
			script.assets = _parse_assets_array(assets_raw)
		elif assets_raw is Dictionary:
			script.assets = _parse_assets_dict(assets_raw)

	# Flows
	if json_data.has("flows"):
		var flows_raw = json_data["flows"]
		if flows_raw is Array:
			for flow_obj in flows_raw:
				if not flow_obj is Dictionary:
					continue
				var flow_id: String = flow_obj.get("id", "")
				script.flows[flow_id] = {
					"id": flow_id,
					"name": flow_obj.get("name", ""),
					"is_exit": flow_obj.get("isExit", false),
				}

	# Build connection index maps for O(1) lookups at runtime
	script.build_indices()
	return script


## Publish [param meta] as storyflow_import_meta.json inside [param output_dir].
##
## The JSON is staged in a sibling temp file and only then renamed over the
## target, so an interrupted or failing write cannot leave a truncated metadata
## file behind — a truncated one breaks project auto-discovery on the next
## launch ([code]StoryFlowManager._auto_load_project[/code]). Every failure is
## pushed as an error and leaves the previously published file untouched.
##
## Shared by the importer and the editor dock; the caller owns the payload.
## Returns [code]OK[/code] only when the target was replaced.
static func write_import_meta(output_dir: String, meta: Dictionary) -> Error:
	var meta_path := output_dir.path_join(IMPORT_META_FILENAME)
	var temp_path := meta_path + IMPORT_META_TEMP_SUFFIX

	var dir_err := DirAccess.make_dir_recursive_absolute(output_dir)
	if dir_err != OK:
		push_error("StoryFlow: Cannot create output directory %s: %s (error %d)" % [
			output_dir, error_string(dir_err), dir_err])
		return dir_err

	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		var open_err := FileAccess.get_open_error()
		if open_err == OK:
			open_err = FAILED
		push_error("StoryFlow: Cannot stage import metadata %s: %s (error %d)" % [
			temp_path, error_string(open_err), open_err])
		return open_err

	file.store_string(JSON.stringify(meta, "\t"))
	var store_err := file.get_error()
	file.close()
	if store_err != OK:
		push_error("StoryFlow: Failed to write import metadata %s: %s (error %d)" % [
			temp_path, error_string(store_err), store_err])
		DirAccess.remove_absolute(temp_path)
		return store_err

	var rename_err := DirAccess.rename_absolute(temp_path, meta_path)
	if rename_err != OK:
		push_error("StoryFlow: Failed to publish import metadata %s: %s (error %d)" % [
			meta_path, error_string(rename_err), rename_err])
		DirAccess.remove_absolute(temp_path)
		return rename_err

	print("StoryFlow: Saved import metadata to %s" % meta_path)
	return OK


# =============================================================================
# Node Data Parsing
# =============================================================================

func _parse_node_data(type_string: String, node_obj: Dictionary) -> Dictionary:
	# The node_obj contains "type" at the top level and all data fields either
	# at top level or nested under a "data" key depending on the export format.
	# We check for a nested "data" key first; if not present, read directly.
	#
	# Keys are kept as camelCase to match the StoryFlow Editor JSON format.
	# This mirrors how the Unreal plugin reads JSON keys directly.
	var data_src: Dictionary = node_obj.get("data", node_obj)
	var data := {}

	# -- Common fields (variable reference) --------------------------------
	if data_src.has("variable"):
		data["variable"] = data_src["variable"]
	if data_src.has("isGlobal"):
		data["isGlobal"] = data_src["isGlobal"]

	# -- Values (variant) --------------------------------------------------
	if data_src.has("value"):
		data["value"] = _parse_variant(data_src["value"])
	if data_src.has("value1"):
		data["value1"] = _parse_variant(data_src["value1"])
	if data_src.has("value2"):
		data["value2"] = _parse_variant(data_src["value2"])

	# -- Dialogue fields ---------------------------------------------------
	if data_src.has("title"):
		data["title"] = data_src["title"]
	if data_src.has("text"):
		data["text"] = data_src["text"]
	if data_src.has("image"):
		data["image"] = data_src["image"]
	if data_src.has("imageReset"):
		data["imageReset"] = data_src["imageReset"]
	if data_src.has("audio"):
		data["audio"] = data_src["audio"]
	if data_src.has("audioLoop"):
		data["audioLoop"] = data_src["audioLoop"]
	if data_src.has("audioReset"):
		data["audioReset"] = data_src["audioReset"]
	if data_src.has("audioAdvanceOnEnd"):
		data["audioAdvanceOnEnd"] = data_src["audioAdvanceOnEnd"]
	if data_src.has("audioAllowSkip"):
		data["audioAllowSkip"] = data_src["audioAllowSkip"]
	if data_src.has("character"):
		data["character"] = data_src["character"]
	# P4 id sibling of "character" (characters engine contract §1.3): additive on the wire,
	# carried when shipped and absent otherwise. Resolution prefers the id; the path stays
	# the fall-back.
	if data_src.has("characterRefId"):
		data["characterRefId"] = data_src["characterRefId"]

	# Dialogue tags (presentation cues fired when the node is entered).
	# Optional and additive: older files lack the key entirely. Guard that the
	# value is an array (a non-array 'tags' would otherwise iterate garbage — an
	# int iterates as a range), then coerce each entry to a string defensively.
	if data_src.has("tags") and data_src["tags"] is Array:
		var tags: Array = []
		for tag in data_src["tags"]:
			tags.append(str(tag))
		data["tags"] = tags

	# Text blocks
	if data_src.has("textBlocks"):
		var text_blocks: Array = []
		for block in data_src["textBlocks"]:
			if block is Dictionary:
				text_blocks.append({
					"id": block.get("id", ""),
					"text": block.get("text", ""),
				})
		data["textBlocks"] = text_blocks

	# Choices / options (dialogue button options)
	if data_src.has("choices"):
		var choices: Array = []
		for choice in data_src["choices"]:
			if choice is Dictionary:
				choices.append({
					"id": choice.get("id", ""),
					"text": choice.get("text", ""),
					"onceOnly": choice.get("onceOnly", false),
				})
		data["options"] = choices
	elif data_src.has("options"):
		# "options" may be used for dialogue choices OR random branch options.
		# Dialogue choices have a "text" field; random branch options have a "weight" field.
		var options_array: Array = data_src["options"]
		if options_array.size() > 0 and options_array[0] is Dictionary:
			var first: Dictionary = options_array[0]
			if first.has("weight"):
				# Random branch options
				var random_opts: Array = []
				for opt in options_array:
					if opt is Dictionary:
						random_opts.append({
							"id": opt.get("id", ""),
							"weight": maxi(1, int(opt.get("weight", 1))),
						})
				data["randomBranchOptions"] = random_opts
			elif first.has("text"):
				# Dialogue choices
				var choices: Array = []
				for opt in options_array:
					if opt is Dictionary:
						choices.append({
							"id": opt.get("id", ""),
							"text": opt.get("text", ""),
							"onceOnly": opt.get("onceOnly", false),
						})
				data["options"] = choices

	# Input source flags
	if data_src.has("imageUseVarInput"):
		data["imageUseVarInput"] = data_src["imageUseVarInput"]
	if data_src.has("audioUseVarInput"):
		data["audioUseVarInput"] = data_src["audioUseVarInput"]
	if data_src.has("characterUseVarInput"):
		data["characterUseVarInput"] = data_src["characterUseVarInput"]

	# -- Script execution --------------------------------------------------
	if data_src.has("script"):
		data["script"] = _normalize_script_path(data_src["script"])
	if data_src.has("flowId"):
		data["flowId"] = data_src["flowId"]

	# Script interface (runScript parameters, outputs, exits)
	if data_src.has("scriptInterface"):
		var iface: Dictionary = data_src["scriptInterface"]
		if iface.has("parameters"):
			var params: Array = []
			for p in iface["parameters"]:
				if p is Dictionary:
					params.append({
						"id": p.get("id", ""),
						"name": p.get("name", ""),
						"type": p.get("type", ""),
						"isArray": p.get("isArray", false),
					})
			data["scriptParameters"] = params
		if iface.has("outputs"):
			var outputs: Array = []
			for o in iface["outputs"]:
				if o is Dictionary:
					outputs.append({
						"id": o.get("id", ""),
						"name": o.get("name", ""),
						"type": o.get("type", ""),
						"isArray": o.get("isArray", false),
					})
			data["scriptOutputs"] = outputs
		if iface.has("exits"):
			var exits: Array = []
			for e in iface["exits"]:
				if e is Dictionary:
					exits.append({
						"id": e.get("id", ""),
						"name": e.get("name", ""),
					})
			data["scriptExits"] = exits

	# Legacy top-level scriptParameters / scriptOutputs / scriptExits
	if data_src.has("scriptParameters") and not data.has("scriptParameters"):
		var params: Array = []
		for p in data_src["scriptParameters"]:
			if p is Dictionary:
				params.append({
					"id": p.get("id", ""),
					"name": p.get("name", ""),
					"type": p.get("type", ""),
				})
		data["scriptParameters"] = params
	if data_src.has("scriptOutputs") and not data.has("scriptOutputs"):
		var outputs: Array = []
		for o in data_src["scriptOutputs"]:
			if o is Dictionary:
				outputs.append({
					"id": o.get("id", ""),
					"name": o.get("name", ""),
					"type": o.get("type", ""),
					"isArray": o.get("isArray", false),
				})
		data["scriptOutputs"] = outputs
	if data_src.has("scriptExits") and not data.has("scriptExits"):
		var exits: Array = []
		for e in data_src["scriptExits"]:
			if e is Dictionary:
				exits.append({
					"id": e.get("id", ""),
					"name": e.get("name", ""),
				})
		data["scriptExits"] = exits

	# -- Enum --------------------------------------------------------------
	if data_src.has("enumVariable"):
		data["enumVariable"] = data_src["enumVariable"]
	if data_src.has("enumValues"):
		var enum_values: Array = []
		for ev in data_src["enumValues"]:
			enum_values.append(str(ev))
		data["enumValues"] = enum_values

	# -- Random branch options (dedicated field) ---------------------------
	if data_src.has("randomBranchOptions"):
		var random_opts: Array = []
		for opt in data_src["randomBranchOptions"]:
			if opt is Dictionary:
				random_opts.append({
					"id": opt.get("id", ""),
					"weight": maxi(1, int(opt.get("weight", 1))),
				})
		data["randomBranchOptions"] = random_opts

	# -- Character Variable ------------------------------------------------
	# The export reuses "variable" for the character variable name, so we
	# only populate variableName when characterPath is present.
	if data_src.has("characterPath"):
		data["characterPath"] = data_src["characterPath"]
		data["variableName"] = data_src.get("variable", "")
	# P4 id sibling of "characterPath" (characters engine contract §1.3): additive on the
	# wire, carried when shipped and absent otherwise. Resolution prefers the id; the path
	# stays the fall-back - the same rule as the dialogue block's characterRefId above.
	if data_src.has("characterId"):
		data["characterId"] = data_src["characterId"]
	if data_src.has("variableName"):
		data["variableName"] = data_src["variableName"]
	if data_src.has("variableType"):
		data["variableType"] = data_src["variableType"]
	if data_src.has("isArray"):
		data["isArray"] = data_src["isArray"]

	# -- Data Assets (.sfd) ------------------------------------------------
	# Only two fields are new here; the accessor's variableType / isArray /
	# keyType / valueType snapshot rides the character-variable keys above and
	# below, which is why json-export-strategy.ts spells them the same way.
	#
	# "assetId" belongs to the reference PILL and "variableId" to the two
	# accessors, which carry no assetId of their own — the wire into their
	# dataAsset pin is the binding (engine contract 2.2). The accessor's
	# "variable" (its spawn-time display NAME) lands in data["variable"] via the
	# common block at the top of this function; nothing reads it at run time,
	# since the id is the binding, but it is what makes a warning legible.
	if data_src.has("assetId"):
		data["assetId"] = data_src["assetId"]
	if data_src.has("variableId"):
		data["variableId"] = data_src["variableId"]

	# -- Map fields (per-variable map nodes and catalog op nodes) -----------
	if data_src.has("keyType"):
		data["keyType"] = data_src["keyType"]
	if data_src.has("valueType"):
		data["valueType"] = data_src["valueType"]
		# Re-parse the inline "value" fallback with the declared valueType so
		# float and enum values keep their type (the generic parse above has no
		# hint). String values store the exported strings-table key verbatim —
		# resolution happens at read time, exactly like scalar variables.
		if data_src.has("value"):
			data["value"] = _parse_variant(data_src["value"], str(data_src["valueType"]))
	# Inline key fallback for catalog op nodes (used when the key input handle
	# is unwired). Inline keys are always raw — never strings-table keys. The
	# coercion is keyed off the DECLARED keyType, not the JSON value's type, so
	# node-inline keys and variable entry keys (_parse_map_entries) share one
	# strategy and numeric-string keys can't diverge.
	if data_src.has("key"):
		data["key"] = _coerce_map_key(data_src["key"], str(data_src.get("keyType", "")))

	return data


# =============================================================================
# Variable Parsing
# =============================================================================

## Parse variables from either an Array (editor export format) or a Dictionary
## (keyed by variable ID).  Returns a Dictionary: id -> variable dict.
func _parse_variables(raw) -> Dictionary:
	var result: Dictionary = {}

	if raw is Array:
		for var_obj in raw:
			if not var_obj is Dictionary:
				continue
			var var_id: String = var_obj.get("id", "")
			if var_id.is_empty():
				continue
			result[var_id] = _parse_single_variable(var_id, var_obj)
	elif raw is Dictionary:
		for var_id in raw:
			var var_obj = raw[var_id]
			if not var_obj is Dictionary:
				continue
			result[var_id] = _parse_single_variable(var_id, var_obj)

	return result


func _parse_single_variable(var_id: String, var_obj: Dictionary) -> Dictionary:
	var type_string: String = var_obj.get("type", "")
	var var_type: StoryFlowTypes.VariableType = StoryFlowTypes.parse_variable_type(type_string)

	# Map key/value types and their enum values (parsed before the value —
	# entry parsing depends on them)
	var key_type_string: String = ""
	var value_type_string: String = ""
	var key_enum_values: Array = []
	var value_enum_values: Array = []
	if var_type == StoryFlowTypes.VariableType.MAP:
		key_type_string = str(var_obj.get("keyType", "string"))
		value_type_string = str(var_obj.get("valueType", "string"))
		if var_obj.has("keyEnumValues"):
			for ev in var_obj["keyEnumValues"]:
				key_enum_values.append(str(ev))
		if var_obj.has("valueEnumValues"):
			for ev in var_obj["valueEnumValues"]:
				value_enum_values.append(str(ev))

	var value: StoryFlowVariant = StoryFlowVariant.new()
	if var_type == StoryFlowTypes.VariableType.MAP:
		# Map variables always hold a map variant — absent map data means an
		# empty map, never an untyped variant
		value = StoryFlowVariant.from_map({})
	if var_obj.has("value"):
		if var_type == StoryFlowTypes.VariableType.MAP:
			# Map values are an ordered array of {key, value} entry objects,
			# not a scalar variant
			var entries_raw = var_obj["value"]
			var context: String = var_obj.get("name", "")
			if context.is_empty():
				context = var_id
			value = StoryFlowVariant.from_map(_parse_map_entries(
				entries_raw if entries_raw is Array else [],
				key_type_string, value_type_string, context))
		else:
			value = _parse_variant(var_obj["value"], type_string)

	var enum_values: Array = []
	if var_obj.has("enumValues"):
		for ev in var_obj["enumValues"]:
			enum_values.append(str(ev))

	return {
		"id": var_id,
		"name": var_obj.get("name", ""),
		"type": var_type,
		"value": value,
		"is_array": var_obj.get("isArray", false),
		"enum_values": enum_values,
		"key_type": StoryFlowTypes.parse_variable_type(key_type_string),
		"value_type": StoryFlowTypes.parse_variable_type(value_type_string),
		"key_enum_values": key_enum_values,
		"value_enum_values": value_enum_values,
		"is_input": var_obj.get("isInput", false),
		"is_output": var_obj.get("isOutput", false),
	}


## Parse variables specific to characters.
## Character variables use a simpler format: { "VarName": { "type": "...", "value": ... } }
func _parse_character_variables(raw: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for var_key in raw:
		var var_obj = raw[var_key]
		if not var_obj is Dictionary:
			continue
		var var_name: String = var_obj.get("name", var_key)
		var type_string: String = var_obj.get("type", "")
		var var_type: StoryFlowTypes.VariableType = StoryFlowTypes.parse_variable_type(type_string)
		var key_type_string: String = ""
		var value_type_string: String = ""
		var key_enum_values: Array = []
		var value_enum_values: Array = []
		var value: StoryFlowVariant = StoryFlowVariant.new()
		if var_type == StoryFlowTypes.VariableType.MAP:
			key_type_string = str(var_obj.get("keyType", "string"))
			value_type_string = str(var_obj.get("valueType", "string"))
			if var_obj.has("keyEnumValues"):
				for ev in var_obj["keyEnumValues"]:
					key_enum_values.append(str(ev))
			if var_obj.has("valueEnumValues"):
				for ev in var_obj["valueEnumValues"]:
					value_enum_values.append(str(ev))
			# Map values are an ordered array of {key, value} entry objects;
			# absent map data means an empty map, never an untyped variant
			var entries_raw = var_obj.get("value")
			value = StoryFlowVariant.from_map(_parse_map_entries(
				entries_raw if entries_raw is Array else [],
				key_type_string, value_type_string, var_name))
		elif var_obj.has("value"):
			value = _parse_variant(var_obj["value"], type_string)
		result[var_name] = {
			"id": str(var_key),
			"name": var_name,
			"type": var_type,
			"value": value,
			# The wire's array marker, carried for the DA-surface character branch's
			# scalar gate (P4): an array-valued row stores its ELEMENT type in "type", so
			# without this flag a bool-array row would satisfy a scalar boolean read.
			"is_array": bool(var_obj.get("isArray", false)),
			"key_type": StoryFlowTypes.parse_variable_type(key_type_string),
			"value_type": StoryFlowTypes.parse_variable_type(value_type_string),
			"key_enum_values": key_enum_values,
			"value_enum_values": value_enum_values,
		}
	return result


## Parse a PRESENT character-index.json document into the id -> record-key table
## (characters engine contract §3), or {} when a degraded rung refuses it. Both import
## arms funnel through here, so the ladder and the verbatim rule cannot diverge.
##
## The degraded ladder - each refusing rung warns naming the consequence, once per import
## since an import parses the document once:
##   absent file          silent (a pre-P4 export; never reaches this function)
##   empty characters map fine (a P4 project with no characters)
##   unreadable document  warn + skip
##   unknown/missing schemaVersion (a plain string compare against "1" - no schema-token
##                        machinery exists in this plugin)  warn + skip
##   no characters object warn + skip
## A skipped index leaves the table empty, so characters keep resolving by path.
##
## Values are stored VERBATIM. The wire ships the exporter's lowercase-backslash record
## keys, which are byte-identical to StoryFlowCharacter.normalize_path's output (to_lower +
## forward->backslash) - normalize_path applied to a value would be a no-op by construction.
## That byte-identity is why no normalization pass exists here or at lookup time; never add
## one (a second normalization regime is exactly the two-regime drift this comment guards).
##
## No re-validation either: the editor never ships unmigrated character ids in the index
## (they simply have no entry, contract §2), so the seed is trusted as-is - the same
## posture as the data-assets block.
func _parse_character_index(index_json: Dictionary) -> Dictionary:
	if index_json.is_empty():
		# {} is both _load_json_file's parse-failure answer (the error it pushed carries
		# the details) and what a literal empty object parses to - the two cannot be told
		# apart here, so the warn names both. An inline payload that is no object lands
		# here too.
		push_warning("StoryFlow: character-index.json is unreadable or empty - the character id bridge was skipped; characters keep resolving by path")
		return {}

	# TYPE-CHECKED, never str()-gated - the same rule the localization reader carries since
	# de0ed70e, and the last reader in this plugin that still branched on a formatter's output.
	# The schema version is a STRING in the format ("1"), but a hand-edited numeric parses to a
	# FLOAT whose printed form is Godot-version-dependent: 4.3 renders 1.0 as "1" and 4.6 as
	# "1.0", so the old str() gate ACCEPTED that file on one Godot and silently skipped the id
	# bridge on another. Requiring a genuine String removes the engine from the decision. It also
	# gives up the numeric tolerance the old comment claimed from Unity, deliberately: matching
	# Unreal's refusal is worth more than matching Unity's leniency when the third option is
	# behaving differently per Godot build. The str() in the MESSAGE below is display-only and
	# nothing branches on it.
	var declared_version = index_json.get("schemaVersion")
	if not (declared_version is String) or declared_version != "1":
		# Absent and present-but-empty read differently in the warn - <missing> vs '' -
		# the same distinction both sibling plugins print (the Unreal spelling).
		var shown: String = str(declared_version) if index_json.has("schemaVersion") else "<missing>"
		push_warning("StoryFlow: character-index.json has an unknown schemaVersion ('%s'; this plugin reads '1') - the character id bridge was skipped; characters keep resolving by path" % shown)
		return {}

	var chars = index_json.get("characters")
	if not (chars is Dictionary):
		push_warning("StoryFlow: character-index.json carries no characters object - the character id bridge was skipped; characters keep resolving by path")
		return {}

	var result: Dictionary = {}
	for id in chars:
		# Trusted-seed posture for malformed VALUES too: a non-String entry is skipped
		# silently, precedent-exact with Unity's index reader - distinct from the
		# unmigrated-id trust above, which is about entries the editor never ships.
		if not (chars[id] is String):
			continue
		result[str(id)] = chars[id]
	return result


## Apply a PRESENT localization.json document (localization spec §9) to [param project], or leave
## the project SOURCE-ONLY when a degraded rung refuses it. Both import arms funnel through here,
## so the ladder and the verbatim-row rule cannot diverge.
##
## The degraded ladder - each refusing rung warns naming the consequence, once per import since an
## import parses the document once:
##   absent file/key      silent (a pre-localization export; never reaches this function)
##   empty target tables  fine (a project whose author registered a language and translated
##                        nothing still ships full tables of source text - and even a sidecar with
##                        no tables at all is a LOCALIZED project, which is why the marker is set
##                        before a single row is counted)
##   unreadable document  warn + skip
##   MISSING schemaVersion    warn + skip - a DISTINCT message from the rung below, because a
##                        sidecar that declares no version and one that declares a version this
##                        plugin cannot read are two different authoring situations; a .get()
##                        with a default would answer the same thing for both and collapse them
##   unsupported schemaVersion (a plain string compare against "1" - no schema-token machinery
##                        exists in this plugin)  warn + skip
##   no strings object    warn + skip
## A skipped sidecar leaves has_localization false, so every string keeps resolving to its source
## text exactly as it did before this file existed.
##
## THE TABLES ARE FULL AND PRE-RESOLVED: the export already applied every §7 fallback (an OUTDATED
## row carries the OLD translation per user ruling 2, an UNTRANSLATED or CLEARED one carries the
## source text, an ORPHAN has no row at all). Nothing here computes a status or compares a hash,
## and the lookup that reads these tables holds no rule beyond the tiers in
## StoryFlowLocalization.look_up.
##
## THE ID SET IS THE SHIPPED SET - the ids that KEYED an artifact this export wrote. `.sfui` widget
## and dropdown strings have NO rows here: `.sfui` documents never reach a plugin, and their text
## localizes in the HTML lane. Their absence is the contract, not a missing feature, and nothing
## downstream should infer a bug from it.
##
## Ids and texts are stored VERBATIM and ids are OPAQUE: this plugin never parses one, and the
## only thing it ever does with one is look it up.
func _apply_localization(project: StoryFlowProject, localization_json: Dictionary) -> void:
	if localization_json.is_empty():
		# {} is both _load_json_file's parse-failure answer (the error it pushed carries the
		# details) and what a literal empty object parses to - the two cannot be told apart here,
		# so the warn names both. An inline payload that is no object lands here too.
		push_warning("StoryFlow: localization.json is unreadable or empty - the language tables were skipped; strings keep resolving to their source text")
		return

	if not localization_json.has("schemaVersion"):
		push_warning("StoryFlow: localization.json declares no schemaVersion (this plugin reads '1') - the language tables were skipped; strings keep resolving to their source text")
		return

	# A TYPE-CHECKED compare, never str() on the parsed value - no schema-token machinery exists in
	# this plugin, but the gate still has to be version-independent.
	#
	# WHY THE VALUE IS NEVER STRINGIFIED: Godot's JSON parses every number as a FLOAT, and the way
	# a whole-valued float PRINTS is version-dependent - Godot 4.3 renders 1.0 as "1" while 4.6
	# renders it as "1.0". A `str(value) != "1"` gate would therefore ACCEPT an unquoted numeric 1
	# on one engine build and REFUSE it on another, which is a degraded ladder that answers
	# differently depending on which Godot a game happens to ship on. Requiring a genuine String
	# removes the engine from the decision entirely: the schema version is a STRING in the format
	# (the exporter always writes the quoted "1"), so anything else - float, int, bool, array - is
	# an unsupported version and lands here. The str() in the MESSAGE is display-only and may well
	# print version-dependently; nothing branches on it.
	#
	# The message is DISTINCT from the missing-field rung above on purpose: a sidecar that declares
	# no version and one that declares a version this plugin cannot read are two different
	# authoring situations, and a `.get()` with a default would collapse them into one. A
	# present-but-empty version prints as '' here, which is what keeps that case readable too.
	var declared_version = localization_json["schemaVersion"]
	if not (declared_version is String) or declared_version != "1":
		push_warning("StoryFlow: localization.json declares schemaVersion '%s', which this plugin does not support (it reads the string '1') - the language tables were skipped; strings keep resolving to their source text" % str(declared_version))
		return

	var strings = localization_json.get("strings")
	if not (strings is Dictionary):
		push_warning("StoryFlow: localization.json carries no strings object - the language tables were skipped; strings keep resolving to their source text")
		return

	# Past every rung: this project IS localized. Set before a single row is counted, so a
	# present-but-empty sidecar is still a localized project.
	project.has_localization = true

	# EVERY VALUE BELOW IS TYPE-CHECKED RATHER THAN STRINGIFIED, for the reason spelled out at the
	# version gate above: a parsed number is a float whose printed form is Godot-version-dependent,
	# so str() on anything read out of this document would make the import answer differently on
	# different engine builds. Codes, labels and rows are STRINGS in the format; a non-string is
	# malformed and is ignored rather than coerced. (Table and row KEYS are exempt - JSON object
	# keys are always strings.)
	var declared_source = localization_json.get("sourceLanguage", "")
	if declared_source is String and not declared_source.is_empty():
		project.source_language = declared_source

	# Registry ORDER is the author's and is preserved: it is the order a picker draws.
	var declared_languages = localization_json.get("languages", [])
	if declared_languages is Array:
		for entry in declared_languages:
			if not (entry is Dictionary):
				continue
			var code = entry.get("code", "")
			if not (code is String) or code.is_empty():
				continue
			var label = entry.get("name", "")
			var has_label: bool = label is String and not label.is_empty()
			project.languages.append({"code": code, "name": label if has_label else code})

	for language_code in strings:
		var table = strings[language_code]
		if not (table is Dictionary):
			continue
		var rows: Dictionary = {}
		for key in table:
			# Trusted-seed posture for malformed VALUES, precedent-exact with the character
			# index's reader: a non-String row is skipped silently.
			if not (table[key] is String):
				continue
			rows[str(key)] = table[key]
		project.language_strings[str(language_code)] = rows


# =============================================================================
# Data Asset Parsing
# =============================================================================

## Only the numeric version 2 opts in; absent/legacy or unsupported metadata stays conservative.
func _data_asset_localization_version(document: Dictionary) -> int:
	var version = document.get("localizationVersion", 1)
	return 2 if (version is int or version is float) and version == 2 else 1


## Parse the exported data-assets.json table (engine contract 2.1) into raw definitions:
## asset_id → { "id", "name", "parent", "variables": Array[declaration], "raw_overrides" }.
##
## Declarations are parsed IN ORDER — declaration order is contractual. Overrides are kept as
## RAW JSON, because typing one needs the declaration that owns its id, which may live on an
## ancestor that has not been parsed yet; StoryFlowDataAssetStore.build_seed types them in a
## second pass once every level is present.
func _parse_data_assets(raw) -> Dictionary:
	var result: Dictionary = {}
	if not raw is Dictionary:
		return result

	for asset_id in raw:
		var asset_obj = raw[asset_id]
		if not asset_obj is Dictionary:
			continue

		var variables: Array = []
		var variables_raw = asset_obj.get("variables", [])
		if variables_raw is Array:
			for var_obj in variables_raw:
				if not var_obj is Dictionary:
					continue
				var declaration := _parse_data_asset_variable(var_obj)
				if not declaration.is_empty():
					variables.append(declaration)

		var overrides_raw = asset_obj.get("overrides", {})
		var parent = asset_obj.get("parent", null)
		result[str(asset_id)] = {
			# The MAP KEY is the authoritative assetId: it is what the pills, the resolver
			# and the save key all use.
			"id": str(asset_id),
			"name": str(asset_obj.get("name", "")),
			"parent": "" if parent == null else str(parent),
			"variables": variables,
			"raw_overrides": overrides_raw if overrides_raw is Dictionary else {},
		}

	return result


## Parse one .sfd variable declaration, or an empty Dictionary when the row is DROPPED.
##
## Two kinds of row are dropped rather than carried:
##  - "category" rows, which are section headers with no value at all and can never be
##    resolved. StoryFlowTypes.VariableType has no CATEGORY member, and the contract's
##    category-drop sanction lets a typed engine drop them at import — Unreal drops, so
##    Godot drops. Silent, because it is the normal shape of an authored .sfd.
##  - rows whose type string the shared table does not know, which is a broken or
##    newer-than-this-plugin export and worth a warning.
##
## The declared VALUE is typed by StoryFlowDataAssetStore.type_value — the same one rule that
## types stored overrides — so a declaration default and an override of it can never disagree
## about the shape a read hands out. A row with no usable value keeps its TYPE DEFAULT and
## still resolves; "is this id declared?" and "does it carry a value?" are different questions.
func _parse_data_asset_variable(var_obj: Dictionary) -> Dictionary:
	var var_id := str(var_obj.get("id", ""))
	if var_id.is_empty():
		return {}

	var type_string := str(var_obj.get("type", ""))
	if type_string == "category":
		return {}

	var var_type: StoryFlowTypes.VariableType = StoryFlowTypes.parse_variable_type(type_string)
	if var_type == StoryFlowTypes.VariableType.NONE:
		push_warning("StoryFlow: Data Asset variable '%s' has unknown type '%s' - dropping the declaration" % [var_obj.get("name", var_id), type_string])
		return {}

	var key_type_string := ""
	var value_type_string := ""
	var key_enum_values: Array = []
	var value_enum_values: Array = []
	if var_type == StoryFlowTypes.VariableType.MAP:
		key_type_string = str(var_obj.get("keyType", "string"))
		value_type_string = str(var_obj.get("valueType", "string"))
		if var_obj.has("keyEnumValues"):
			for ev in var_obj["keyEnumValues"]:
				key_enum_values.append(str(ev))
		if var_obj.has("valueEnumValues"):
			for ev in var_obj["valueEnumValues"]:
				value_enum_values.append(str(ev))

	var enum_values: Array = []
	if var_obj.has("enumValues"):
		for ev in var_obj["enumValues"]:
			enum_values.append(str(ev))

	var declaration: Dictionary = {
		"id": var_id,
		"name": str(var_obj.get("name", "")),
		"type": var_type,
		"localizable": var_obj.get("localizable", true) != false,
		"is_array": bool(var_obj.get("isArray", false)),
		"key_type": StoryFlowTypes.parse_variable_type(key_type_string),
		"value_type": StoryFlowTypes.parse_variable_type(value_type_string),
		"enum_values": enum_values,
		"key_enum_values": key_enum_values,
		"value_enum_values": value_enum_values,
		"value": null,
	}

	var value: StoryFlowVariant = null
	if var_obj.has("value"):
		value = StoryFlowDataAssetStore.type_value(declaration, var_obj["value"])
	if value == null:
		value = StoryFlowDataAssetStore.type_default(declaration)
	declaration["value"] = value

	return declaration


# =============================================================================
# Map Entry Parsing
# =============================================================================

## Coerce a raw JSON map key to its storage type from the DECLARED keyType.
## Integer keys arrive as JSON numbers (parsed as float by Godot) and are
## coerced to int so map lookups compare numerically; string/enum keys are
## stored as String. Keys are raw values — never strings-table keys. This is
## the single coercion strategy shared by node-inline keys (_parse_node_data)
## and variable entry keys (_parse_map_entries).
func _coerce_map_key(raw_key, key_type_string: String):
	if key_type_string == "integer":
		return int(raw_key)
	return str(raw_key)


## Parse map entries from the exported ordered array of {key, value} objects.
## Returns an insertion-ordered Dictionary: coerced key -> StoryFlowVariant.
## Entry order is contractual — it is observable through mapKeys/mapValues/
## forEachMap and must match the editor's serialized order (Godot Dictionaries
## preserve insertion order).
func _parse_map_entries(entries_raw: Array, key_type_string: String, value_type_string: String, variable_context: String) -> Dictionary:
	var entries: Dictionary = {}
	for entry_obj in entries_raw:
		if not entry_obj is Dictionary:
			continue
		# Keys are raw values (numbers for integer keys, strings otherwise) and
		# never resolve through the strings table or asset map. An entry without
		# a key is unaddressable — skip it.
		if not entry_obj.has("key") or entry_obj["key"] == null:
			push_warning("StoryFlow: Skipping map entry with missing key in map variable '%s'" % variable_context)
			continue
		var key = _coerce_map_key(entry_obj["key"], key_type_string)
		# String-family values store the exported strings-table key / asset id
		# verbatim; resolution happens at read time, exactly like scalar variables
		var value := _parse_variant(entry_obj.get("value"), value_type_string)
		if value_type_string == "string" and entry_obj.get("value") is String:
			value.string_key = entry_obj["value"]
		entries[key] = value
	return entries


# =============================================================================
# Variant Parsing
# =============================================================================

## Parse a variant value from JSON.
## [param value] The raw JSON value (bool, int, float, String, Array).
## [param type_hint] Optional type string ("boolean", "integer", etc.) for disambiguation.
func _parse_variant(value, type_hint: String = "") -> StoryFlowVariant:
	var variant := StoryFlowVariant.new()

	if value == null:
		return variant

	if value is bool:
		variant.set_bool(value)
	elif value is int:
		if type_hint == "float":
			variant.set_float(float(value))
		else:
			variant.set_int(value)
	elif value is float:
		if type_hint == "integer":
			variant.set_int(int(value))
		elif type_hint == "float":
			variant.set_float(value)
		else:
			# Unknown type: check for fractional part
			if fmod(value, 1.0) != 0.0:
				variant.set_float(value)
			else:
				variant.set_int(int(value))
	elif value is String:
		if type_hint == "enum":
			variant.set_enum(value)
		else:
			variant.set_string(value)
			variant.string_is_literal = false
	elif value is Array:
		var arr: Array = []
		for item in value:
			var element := _parse_variant(item, type_hint)
			if type_hint == "string" and item is String:
				element.string_key = item
			arr.append(element)
		variant.set_array(arr)

	return variant


# =============================================================================
# String Table Flattening
# =============================================================================

## Flatten nested locale strings.
## Input:  { "en": { "key1": "val1" } }
## Output: { "en.key1": "val1" }
func _flatten_strings(json: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for lang_code in json:
		var lang_strings = json[lang_code]
		if not lang_strings is Dictionary:
			continue
		for key in lang_strings:
			result["%s.%s" % [lang_code, key]] = str(lang_strings[key])
	return result


# =============================================================================
# Asset Parsing
# =============================================================================

## Parse assets from an Array format: [ { "id": "...", "type": "...", "path": "..." } ]
func _parse_assets_array(arr: Array) -> Dictionary:
	var result: Dictionary = {}
	for asset_obj in arr:
		if not asset_obj is Dictionary:
			continue
		var asset_id: String = asset_obj.get("id", "")
		if asset_id.is_empty():
			continue
		result[asset_id] = {
			"id": asset_id,
			"type": asset_obj.get("type", ""),
			"path": asset_obj.get("path", ""),
		}
	return result


## Parse assets from a Dictionary format: { "id": { "type": "...", "path": "..." } }
func _parse_assets_dict(dict: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for asset_id in dict:
		var asset_obj = dict[asset_id]
		if not asset_obj is Dictionary:
			continue
		result[asset_id] = {
			"id": asset_id,
			"type": asset_obj.get("type", ""),
			"path": asset_obj.get("path", ""),
		}
	return result


# =============================================================================
# Media Asset Import
# =============================================================================

## Mirror a script's resolved assets into the project-wide pool. Asset IDs are
## globally unique across the export, and values can cross script boundaries at
## runtime (a character's Image set from one script's local image variable is
## displayed while ANOTHER script runs) - the component's asset resolution
## falls back to the project pool, so the pool must know every script's assets.
func _pool_script_assets(project: StoryFlowProject, script: StoryFlowScript) -> void:
	for asset_id in script.resolved_assets:
		if not project.resolved_assets.has(asset_id):
			project.resolved_assets[asset_id] = script.resolved_assets[asset_id]


## Import media assets from the build directory into the Godot project.
##
## [param build_dir] Source build directory.
## [param output_dir] Godot res:// base path for imported media.
## [param assets] Dictionary of asset metadata (id -> { "id", "type", "path" }).
## [param out_resolved] Output dictionary to populate with res:// paths.
func _import_media_assets(
	build_dir: String,
	output_dir: String,
	assets: Dictionary,
	out_resolved: Dictionary,
) -> void:
	if assets.is_empty():
		return

	for asset_id in assets:
		var asset: Dictionary = assets[asset_id]
		var asset_path: String = asset.get("path", "")
		var asset_type: String = asset.get("type", "")

		if asset_path.is_empty():
			continue

		var source_path := build_dir.path_join(asset_path)

		# Determine type-specific subdirectory
		var type_dir: String
		match asset_type:
			"image":
				type_dir = "images"
			"audio":
				type_dir = "audio"
			_:
				type_dir = "media"

		var target_dir := output_dir.path_join(type_dir)

		# Build a safe file name (keep extension)
		var filename := source_path.get_file()
		var target_path := target_dir.path_join(filename)

		# Check source exists
		if not FileAccess.file_exists(source_path):
			# Fallback: asset may already exist in output from a previous full sync
			# (e.g. data-only sync skips copying assets but they were imported before)
			if FileAccess.file_exists(target_path):
				var resource: Resource = null
				if asset_type == "image":
					resource = _load_image_direct(target_path)
				elif asset_type == "audio":
					resource = _load_audio_direct(target_path)
				else:
					resource = ResourceLoader.load(target_path)
				if resource:
					out_resolved[asset_id] = resource
				else:
					out_resolved[asset_id] = target_path
				continue
			# Exported games pack only Godot's imported versions of media (no raw
			# bytes for FileAccess); those are reachable solely through the
			# resource remap via ResourceLoader.
			var imported := _load_imported_resource(source_path, target_path)
			if imported:
				out_resolved[asset_id] = imported
				continue
			push_warning("StoryFlow: Source media file not found: %s" % source_path)
			continue

		# Copy file (only when the destination differs in content), but skip when
		# source == target (happens during load_project_local where build_dir ==
		# output_dir, and res:// is read-only in exported games anyway)
		if source_path != target_path:
			if _copy_file(source_path, target_path) != OK:
				continue

		# This media file is now published under output_dir; the blanket copy of
		# the build directory must not write a second copy of it, and must not
		# delete this one when both land on the same path.
		_copied_sources[source_path.simplify_path()] = true
		_published_targets[target_path.simplify_path()] = true
		# Case-folded spelling as well: on a case-insensitive filesystem the
		# blanket copy reaches this same file under a differently cased path
		# (a build directory named Images/ against the images/ published here).
		# The extra key only ever declines a deletion, so on a case-sensitive
		# filesystem, where such a path really is a different file, the worst it
		# can cause is a second copy — the safe direction.
		_published_targets[target_path.simplify_path().to_lower()] = true

		# Load resources directly from file buffers, bypassing Godot's import
		# pipeline entirely. This avoids stale .import cache issues on
		# re-launch and handles mismatched extensions (PNG data as .jpg).
		var resource: Resource = null
		if asset_type == "image":
			resource = _load_image_direct(target_path)
		elif asset_type == "audio":
			resource = _load_audio_direct(target_path)
		else:
			resource = ResourceLoader.load(target_path)

		if resource:
			out_resolved[asset_id] = resource
		else:
			out_resolved[asset_id] = target_path
			push_warning("StoryFlow: Could not load resource %s" % target_path)

		print("StoryFlow: Imported media %s -> %s" % [asset_path, target_path])


## Load a media file through Godot's import remap. In exported games the raw
## file bytes are not packed; only the imported resource (CompressedTexture2D,
## AudioStreamWAV, AudioStreamMP3, ...) is, and only ResourceLoader reaches it.
func _load_imported_resource(source_path: String, target_path: String) -> Resource:
	for path in [target_path, source_path]:
		if ResourceLoader.exists(path):
			var res := ResourceLoader.load(path)
			if res:
				return res
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


## Load an audio file directly from file buffer, bypassing Godot's import
## pipeline. Supports MP3 and WAV formats.
func _load_audio_direct(file_path: String) -> AudioStream:
	var file := FileAccess.open(file_path, FileAccess.READ)
	if not file:
		return null
	var buffer := file.get_buffer(file.get_length())
	file.close()
	if buffer.size() < 4:
		return null

	var ext := file_path.get_extension().to_lower()

	# MP3: check for ID3 tag (49 44 33) or MPEG sync word (FF FB/FA/F3/F2)
	if ext == "mp3" or (buffer[0] == 0x49 and buffer[1] == 0x44 and buffer[2] == 0x33) or (buffer[0] == 0xFF and (buffer[1] & 0xE0) == 0xE0):
		var stream := AudioStreamMP3.new()
		stream.data = buffer
		return stream

	# WAV: RIFF header with WAVE
	if ext == "wav" or (buffer[0] == 0x52 and buffer[1] == 0x49 and buffer[2] == 0x46 and buffer[3] == 0x46):
		var stream := AudioStreamWAV.new()
		# WAV requires ResourceLoader for proper parsing — fall back
		var res = ResourceLoader.load(file_path)
		if res:
			return res

	# OGG: check for OggS header
	if ext == "ogg" or (buffer[0] == 0x4F and buffer[1] == 0x67 and buffer[2] == 0x67 and buffer[3] == 0x53):
		var res = ResourceLoader.load(file_path)
		if res:
			return res

	return null


# =============================================================================
# File Helpers
# =============================================================================

## Load and parse a JSON file.  Returns an empty Dictionary on failure.
func _load_json_file(file_path: String) -> Dictionary:
	if not FileAccess.file_exists(file_path):
		return {}

	var file := FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		push_error("StoryFlow: Cannot open file %s" % file_path)
		return {}

	var json_text := file.get_as_text()
	file.close()

	var json := JSON.new()
	var err := json.parse(json_text)
	if err != OK:
		push_error("StoryFlow: JSON parse error in %s at line %d: %s" % [
			file_path, json.get_error_line(), json.get_error_message()
		])
		return {}

	var result = json.data
	if result is Dictionary:
		return result

	push_error("StoryFlow: Expected JSON object in %s, got %s" % [file_path, typeof(result)])
	return {}


## Recursively find all .json files under a directory.
func _find_json_files_recursive(dir_path: String) -> PackedStringArray:
	var results := PackedStringArray()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return results

	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if dir.current_is_dir():
			if name != "." and name != "..":
				var sub_results := _find_json_files_recursive(dir_path.path_join(name))
				results.append_array(sub_results)
		else:
			if name.get_extension().to_lower() == "json":
				results.append(dir_path.path_join(name))
		name = dir.get_next()
	dir.list_dir_end()

	return results


## Make a path relative to a base directory.
func _make_relative(absolute_path: String, base_dir: String) -> String:
	# Normalize separators
	var norm_path := absolute_path.replace("\\", "/")
	var norm_base := base_dir.replace("\\", "/")
	if not norm_base.ends_with("/"):
		norm_base += "/"
	if norm_path.begins_with(norm_base):
		return norm_path.substr(norm_base.length())
	return norm_path


## Strip .json extension from a script path.
func _normalize_script_path(path: String) -> String:
	var result := path
	if result.ends_with(".json"):
		result = result.substr(0, result.length() - 5)
	return result


## Copy a single file, skipping the write when the destination already holds the
## same content. Rewriting unchanged files churns the disk and makes Godot
## re-import every copied file (a full project.storyflow parse) on every sync.
## Failures are pushed as errors and counted; [param log_label] is printed only
## when bytes were really written.
func _copy_file(src_path: String, dst_path: String, log_label: String = "") -> Error:
	if _is_up_to_date(src_path, dst_path):
		return OK

	var dst_dir := dst_path.get_base_dir()
	var dir_err := DirAccess.make_dir_recursive_absolute(dst_dir)
	if dir_err != OK:
		push_error("StoryFlow: Failed to create directory %s: %s (error %d)" % [
			dst_dir, error_string(dir_err), dir_err])
		_error_count += 1
		return dir_err

	var err := DirAccess.copy_absolute(src_path, dst_path)
	if err != OK:
		push_error("StoryFlow: Failed to copy %s -> %s: %s (error %d)" % [
			src_path, dst_path, error_string(err), err])
		_error_count += 1
		return err

	if not log_label.is_empty():
		print("StoryFlow: Copied %s" % log_label)
	return OK


## True when [param dst_path] already holds exactly the bytes of
## [param src_path]. Sizes are compared first because they rule out most
## changes cheaply, then MD5 so a same-length edit is still detected. Anything
## unreadable or missing answers false, so the caller copies when in doubt.
static func _is_up_to_date(src_path: String, dst_path: String) -> bool:
	if not FileAccess.file_exists(dst_path):
		return false

	var src_size := _file_size(src_path)
	if src_size < 0 or src_size != _file_size(dst_path):
		return false

	var src_md5 := FileAccess.get_md5(src_path)
	if src_md5.is_empty():
		return false
	return src_md5 == FileAccess.get_md5(dst_path)


## Size of a file in bytes, or -1 when it cannot be opened.
static func _file_size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return -1
	var size := file.get_length()
	file.close()
	return size


## Delete a stale copy an older import left in the output directory — a media
## duplicate at its build-relative path, or a verbatim project.storyflow.
## Missing is the normal case and not an error; a failed removal is, because the
## leftover shadows the copy the runtime should be resolving.
func _remove_redundant_copy(path: String) -> void:
	# Never delete what this import just published. An asset stored under a
	# build-relative images/, audio/ or media/ directory lands on exactly the
	# path the asset import wrote, and deleting it would lose the media entirely.
	# The case-folded spelling counts as the same file, because that is how a
	# case-insensitive filesystem resolves it.
	var simplified := path.simplify_path()
	if _published_targets.has(simplified) or _published_targets.has(simplified.to_lower()):
		return

	if not FileAccess.file_exists(path):
		return

	var err := DirAccess.remove_absolute(path)
	if err != OK:
		push_error("StoryFlow: Failed to remove stale copy %s: %s (error %d)" % [
			path, error_string(err), err])
		_error_count += 1
		return

	print("StoryFlow: Removed stale copy %s" % path)

	# Tidy up what the removed file leaves behind. Both steps are best effort:
	# under res:// Godot keeps an .import sidecar next to every media file, and
	# the directory that held the duplicate is usually empty afterwards. Failing
	# to clean either one does not affect the imported project, so it is not
	# reported as an import failure.
	var sidecar := path + ".import"
	if FileAccess.file_exists(sidecar):
		DirAccess.remove_absolute(sidecar)
	_remove_dir_if_empty(path.get_base_dir())


## Remove a directory the duplicate cleanup just emptied. The destination root
## of the import is never removed, and a directory that still holds anything is
## left alone.
func _remove_dir_if_empty(dir_path: String) -> void:
	if _as_dir_prefix(dir_path) == _as_dir_prefix(_output_root):
		return

	var dir := DirAccess.open(dir_path)
	if dir == null:
		return

	var is_empty := true
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name != "." and name != "..":
			is_empty = false
			break
		name = dir.get_next()
	dir.list_dir_end()

	if is_empty:
		DirAccess.remove_absolute(dir_path)


## True when one of the directories contains the other, or they are the same.
## Copying between overlapping directories descends into its own output and
## never terminates, so such a step must be refused.
static func _dirs_overlap(dir_a: String, dir_b: String) -> bool:
	var a := _as_dir_prefix(dir_a)
	var b := _as_dir_prefix(dir_b)
	return a.begins_with(b) or b.begins_with(a)


## Normalize a directory path for prefix comparison: forward slashes, resolved
## "." and ".." segments, and a trailing slash so "foo/bar2" is not mistaken for
## something living inside "foo/bar".
static func _as_dir_prefix(path: String) -> String:
	var normalized := path.replace("\\", "/").simplify_path()
	if not normalized.ends_with("/"):
		normalized += "/"
	return normalized


## Recursively copy all files from source directory to destination directory.
func _copy_directory_recursive(src_dir: String, dst_dir: String) -> void:
	var dir_err := DirAccess.make_dir_recursive_absolute(dst_dir)
	if dir_err != OK:
		push_error("StoryFlow: Failed to create directory %s: %s (error %d)" % [
			dst_dir, error_string(dir_err), dir_err])
		_error_count += 1
		return

	var dir := DirAccess.open(src_dir)
	if dir == null:
		var open_err := DirAccess.get_open_error()
		push_error("StoryFlow: Cannot open source directory %s: %s (error %d)" % [
			src_dir, error_string(open_err), open_err])
		_error_count += 1
		return

	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var src_path := src_dir.path_join(name)
		var dst_path := dst_dir.path_join(name)
		if dir.current_is_dir():
			if name != "." and name != "..":
				if _dirs_overlap(src_path, dst_path):
					push_error("StoryFlow: Refusing to copy %s -> %s: the directories are nested, which would recurse without end" % [
						src_path, dst_path])
					_error_count += 1
				else:
					_copy_directory_recursive(src_path, dst_path)
		elif _copied_sources.has(src_path.simplify_path()):
			# A file this import already published under output_dir (media into
			# its asset directory, the project file as project.json): it is
			# resolved from that copy at runtime, so a second copy at the
			# build-relative path is pure duplication. A duplicate written by an
			# older version is removed, because the runtime reloads the output
			# directory in place and would copy that stale file over the fresh one.
			_remove_redundant_copy(dst_path)
		else:
			_copy_file(src_path, dst_path, name)
		name = dir.get_next()
	dir.list_dir_end()
