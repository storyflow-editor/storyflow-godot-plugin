class_name StoryFlowImporter
extends RefCounted
## JSON importer for StoryFlow project and script files exported by the
## StoryFlow Editor.  Reads the build directory structure, creates
## StoryFlowProject / StoryFlowScript / StoryFlowCharacter resources and
## optionally copies media assets into the Godot project.

# =============================================================================
# Public API
# =============================================================================

## Import a full StoryFlow project from an exported build directory.
##
## [param build_dir] Absolute path to the build folder (contains project.storyflow).
## [param output_dir] Godot res:// path where imported resources will be saved.
## Returns the imported [StoryFlowProject], or [code]null[/code] on failure.
func import_project(build_dir: String, output_dir: String) -> StoryFlowProject:
	# Read project.storyflow (or project.json for backwards compat)
	var project_json: Dictionary = _load_json_file(build_dir.path_join("project.storyflow"))
	if project_json.is_empty():
		project_json = _load_json_file(build_dir.path_join("project.json"))
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

		# Parse character asset metadata for later media import
		var character_media_assets: Dictionary = {}
		if characters_json.has("assets"):
			character_media_assets = _parse_assets_dict(characters_json["assets"])

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

				# Import character media (portrait image)
				if character.image_key != "" and character_media_assets.has(character.image_key):
					var single_asset: Dictionary = { character.image_key: character_media_assets[character.image_key] }
					_import_media_assets(build_dir, output_dir, single_asset, character.resolved_assets)

				project.characters[normalized_path] = character
				print("StoryFlow: Imported character '%s'" % char_path)

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
				project.scripts[script_path] = script

	# ------------------------------------------------------------------
	# Scripts – standalone .json files in build directory
	# ------------------------------------------------------------------
	var script_files := _find_json_files_recursive(build_dir)
	for script_file in script_files:
		var filename := script_file.get_file()
		# Skip non-script files
		if filename in ["project.json", "project.storyflow", "global-variables.json", "characters.json"]:
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
			project.scripts[script_path] = script

	# ------------------------------------------------------------------
	# Copy all build files into the output directory (skip if same path)
	# ------------------------------------------------------------------
	var norm_build := build_dir.replace("\\", "/").rstrip("/")
	var norm_output := output_dir.replace("\\", "/").rstrip("/")
	if norm_build != norm_output:
		_copy_directory_recursive(build_dir, output_dir)

	# Save metadata so the manager can reload from the local copy
	if norm_build != norm_output:
		var meta_path := output_dir.path_join("storyflow_import_meta.json")
		var meta := {
			"output_dir": output_dir,
			"imported_at": Time.get_datetime_string_from_system(),
		}
		var meta_file := FileAccess.open(meta_path, FileAccess.WRITE)
		if meta_file:
			meta_file.store_string(JSON.stringify(meta, "\t"))
			meta_file.close()
			print("StoryFlow: Saved import metadata to %s" % meta_path)

	print("StoryFlow: Successfully imported project with %d scripts" % project.scripts.size())
	return project


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
	if data_src.has("variableName"):
		data["variableName"] = data_src["variableName"]
	if data_src.has("variableType"):
		data["variableType"] = data_src["variableType"]

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

	var value: StoryFlowVariant = StoryFlowVariant.new()
	if var_obj.has("value"):
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
		"is_input": var_obj.get("isInput", false),
		"is_output": var_obj.get("isOutput", false),
	}


## Parse variables specific to characters.
## Character variables use a simpler format: { "VarName": { "type": "...", "value": ... } }
func _parse_character_variables(raw: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for var_name in raw:
		var var_obj = raw[var_name]
		if not var_obj is Dictionary:
			continue
		var type_string: String = var_obj.get("type", "")
		var var_type: StoryFlowTypes.VariableType = StoryFlowTypes.parse_variable_type(type_string)
		var value: StoryFlowVariant = StoryFlowVariant.new()
		if var_obj.has("value"):
			value = _parse_variant(var_obj["value"], type_string)
		result[var_name] = {
			"name": var_name,
			"type": var_type,
			"value": value,
		}
	return result


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
	elif value is Array:
		var arr: Array = []
		for item in value:
			arr.append(_parse_variant(item, type_hint))
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
		DirAccess.make_dir_recursive_absolute(target_dir)

		# Build a safe file name (keep extension)
		var filename := source_path.get_file()
		var target_path := target_dir.path_join(filename)

		# Check source exists
		if not FileAccess.file_exists(source_path):
			push_warning("StoryFlow: Source media file not found: %s" % source_path)
			continue

		# Copy file (overwrite if already present)
		var err := DirAccess.copy_absolute(source_path, target_path)
		if err != OK:
			push_error("StoryFlow: Failed to copy %s -> %s (error %d)" % [source_path, target_path, err])
			continue

		# Load the resource so the runtime gets actual Texture2D/AudioStream objects
		# In-editor: trigger reimport so Godot recognizes the new file
		if Engine.is_editor_hint():
			EditorInterface.get_resource_filesystem().update_file(target_path)

		var resource = ResourceLoader.load(target_path)
		if resource:
			out_resolved[asset_id] = resource
		else:
			# Fallback: store the path so a deferred load can be attempted later
			out_resolved[asset_id] = target_path
			push_warning("StoryFlow: Could not load resource %s (may need editor reimport)" % target_path)

		print("StoryFlow: Imported media %s -> %s" % [asset_path, target_path])


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


## Recursively copy all files from source directory to destination directory.
func _copy_directory_recursive(src_dir: String, dst_dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dst_dir)

	var dir := DirAccess.open(src_dir)
	if dir == null:
		push_error("StoryFlow: Cannot open source directory %s" % src_dir)
		return

	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var src_path := src_dir.path_join(name)
		var dst_path := dst_dir.path_join(name)
		if dir.current_is_dir():
			if name != "." and name != "..":
				_copy_directory_recursive(src_path, dst_path)
		else:
			var err := DirAccess.copy_absolute(src_path, dst_path)
			if err != OK:
				push_error("StoryFlow: Failed to copy %s -> %s" % [src_path, dst_path])
			else:
				print("StoryFlow: Copied %s" % name)
		name = dir.get_next()
	dir.list_dir_end()


## Create a .gdignore file in a directory so Godot ignores its contents.
## This prevents "Files have been modified on disk" dialogs during sync.
func _ensure_gdignore(dir_path: String) -> void:
	var gdignore_path := dir_path.path_join(".gdignore")
	if not FileAccess.file_exists(gdignore_path):
		var f := FileAccess.open(gdignore_path, FileAccess.WRITE)
		if f:
			f.store_string("")
			f.close()
