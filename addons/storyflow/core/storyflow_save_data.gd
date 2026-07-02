class_name StoryFlowSaveData
extends RefCounted

# Preloaded by path so parsing never depends on the global class name cache,
# which can be stale or mid-rewrite when the game launches (godotengine/godot#75388).
const StoryFlowCharacter = preload("res://addons/storyflow/core/storyflow_character.gd")
const StoryFlowTypes = preload("res://addons/storyflow/core/storyflow_types.gd")
const StoryFlowVariant = preload("res://addons/storyflow/core/storyflow_variant.gd")

const SAVE_VERSION := 1
const SAVE_DIR := "user://storyflow_saves/"


static func save_to_slot(slot_name: String, global_variables: Dictionary,
		runtime_characters: Dictionary, used_once_only_options: Dictionary) -> bool:
	_ensure_save_dir()

	var data := {
		"save_version": SAVE_VERSION,
		"global_variables": _serialize_variables(global_variables),
		"runtime_characters": _serialize_characters(runtime_characters),
		"used_once_only_options": used_once_only_options.keys(),
	}

	var json_string := JSON.stringify(data, "\t")
	var path := SAVE_DIR + slot_name + ".json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("[StoryFlow] Failed to save to slot '%s': %s" % [slot_name, error_string(FileAccess.get_open_error())])
		return false

	file.store_string(json_string)
	file.close()
	return true


static func load_from_slot(slot_name: String) -> Dictionary:
	var path := SAVE_DIR + slot_name + ".json"
	if not FileAccess.file_exists(path):
		push_error("[StoryFlow] Save slot '%s' does not exist" % slot_name)
		return {}

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("[StoryFlow] Failed to load slot '%s': %s" % [slot_name, error_string(FileAccess.get_open_error())])
		return {}

	var json_string := file.get_as_text()
	file.close()

	var parsed = JSON.parse_string(json_string)
	if parsed == null:
		push_error("[StoryFlow] Failed to parse save file '%s'" % slot_name)
		return {}

	return {
		"global_variables": _deserialize_variables(parsed.get("global_variables", {})),
		"runtime_characters": _deserialize_characters(parsed.get("runtime_characters", {})),
		"used_once_only_options": _deserialize_once_only(parsed.get("used_once_only_options", [])),
	}


static func does_save_exist(slot_name: String) -> bool:
	return FileAccess.file_exists(SAVE_DIR + slot_name + ".json")


static func delete_save(slot_name: String) -> void:
	var path := SAVE_DIR + slot_name + ".json"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


static func list_save_slots() -> PackedStringArray:
	var slots := PackedStringArray()
	var dir := DirAccess.open(SAVE_DIR)
	if dir == null:
		return slots
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".json"):
			slots.append(file_name.get_basename())
		file_name = dir.get_next()
	return slots


# =============================================================================
# Serialization Helpers
# =============================================================================

static func _ensure_save_dir() -> void:
	if not DirAccess.dir_exists_absolute(SAVE_DIR):
		DirAccess.make_dir_recursive_absolute(SAVE_DIR)


static func _serialize_variables(variables: Dictionary) -> Dictionary:
	var result := {}
	for var_id in variables:
		var v: Dictionary = variables[var_id]
		var entry := {
			"name": v.get("name", ""),
			"type": v.get("type", 0),
			"is_array": v.get("is_array", false),
		}
		# Map K/V type metadata lives on the variable record (set by the
		# importer) — persist it so a loaded record keeps the same shape.
		if v.get("type", 0) == StoryFlowTypes.VariableType.MAP:
			entry["key_type"] = v.get("key_type", StoryFlowTypes.VariableType.STRING)
			entry["value_type"] = v.get("value_type", StoryFlowTypes.VariableType.STRING)
		var value: StoryFlowVariant = v.get("value", null)
		if value != null:
			entry["value"] = _serialize_variant(value)
		result[var_id] = entry
	return result


static func _serialize_variant(v: StoryFlowVariant) -> Dictionary:
	var result := {"type": v.type}
	match v.type:
		StoryFlowTypes.VariableType.BOOLEAN:
			result["value"] = v.get_bool()
		StoryFlowTypes.VariableType.INTEGER:
			result["value"] = v.get_int()
		StoryFlowTypes.VariableType.FLOAT:
			result["value"] = v.get_float()
		StoryFlowTypes.VariableType.STRING, StoryFlowTypes.VariableType.ENUM:
			result["value"] = v.get_string()
		StoryFlowTypes.VariableType.MAP:
			# Ordered [{key, value}, ...] entry list mirroring the editor export
			# shape: raw keys (int or String — JSON keeps the distinction),
			# typed variant values. Values persist EXACTLY as held in memory —
			# in this engine string values resolve through the strings table at
			# READ time (see the evaluator's _resolve_string_key), so what's in
			# memory (and in the save) is usually the raw table key, identical
			# to how scalar string variables persist. Keys never resolve.
			# NOTE: aliasing topology does NOT survive a round-trip — every
			# variable serializes its own entries, so two variables sharing
			# storage via setMap reload as equal-but-detached maps (same
			# posture as the Unreal and HTML runtimes).
			var entries := []
			var map: Dictionary = v.get_map()
			for key in map:
				var entry_value = map[key]
				if entry_value is StoryFlowVariant:
					entries.append({"key": key, "value": _serialize_variant(entry_value)})
			result["value"] = entries
		_:
			result["value"] = null
	# Serialize arrays
	if v.get_array().size() > 0:
		var arr := []
		for elem in v.get_array():
			if elem is StoryFlowVariant:
				arr.append(_serialize_variant(elem))
		result["array"] = arr
	return result


static func _serialize_characters(characters: Dictionary) -> Dictionary:
	var result := {}
	for path in characters:
		var c: StoryFlowCharacter = characters[path]
		var vars := {}
		for vname in c.variables:
			var vdata: Dictionary = c.variables[vname]
			var entry := {"type": vdata.get("type", 0)}
			if vdata.get("type", 0) == StoryFlowTypes.VariableType.MAP:
				entry["key_type"] = vdata.get("key_type", StoryFlowTypes.VariableType.STRING)
				entry["value_type"] = vdata.get("value_type", StoryFlowTypes.VariableType.STRING)
			var value: StoryFlowVariant = vdata.get("value", null)
			if value != null:
				entry["value"] = _serialize_variant(value)
			vars[vname] = entry
		result[path] = {"variables": vars}
	return result


static func _deserialize_variables(data: Dictionary) -> Dictionary:
	var result := {}
	for var_id in data:
		var entry: Dictionary = data[var_id]
		var v := {
			"id": var_id,
			"name": entry.get("name", ""),
			"type": int(entry.get("type", 0)),
			"is_array": entry.get("is_array", false),
		}
		# Restore map K/V type metadata (absent on pre-map saves → string defaults)
		if v["type"] == StoryFlowTypes.VariableType.MAP:
			v["key_type"] = int(entry.get("key_type", StoryFlowTypes.VariableType.STRING))
			v["value_type"] = int(entry.get("value_type", StoryFlowTypes.VariableType.STRING))
		if entry.has("value"):
			v["value"] = _deserialize_variant(entry["value"])
		result[var_id] = v
	return result


static func _deserialize_variant(data) -> StoryFlowVariant:
	if data is Dictionary:
		var v := StoryFlowVariant.new()
		var t: int = int(data.get("type", 0))
		match t:
			StoryFlowTypes.VariableType.BOOLEAN:
				v.set_bool(bool(data.get("value", false)))
			StoryFlowTypes.VariableType.INTEGER:
				v.set_int(int(data.get("value", 0)))
			StoryFlowTypes.VariableType.FLOAT:
				v.set_float(float(data.get("value", 0.0)))
			StoryFlowTypes.VariableType.STRING:
				v.set_string(str(data.get("value", "")))
			StoryFlowTypes.VariableType.ENUM:
				v.set_enum(str(data.get("value", "")))
			StoryFlowTypes.VariableType.MAP:
				# Tolerant: absent/malformed entry list degrades to an empty map
				# with the MAP type preserved (set_map types the variant); a
				# keyless entry is skipped. JSON numbers parse as float — coerce
				# numeric keys back to the int storage type (the importer's key
				# coercion rule); everything else stores as String.
				var entries := {}
				var raw = data.get("value")
				if raw is Array:
					for entry_obj in raw:
						if not (entry_obj is Dictionary) or not entry_obj.has("key"):
							continue
						var key = entry_obj["key"]
						if key is float:
							key = int(key)
						elif not (key is int):
							key = str(key)
						entries[key] = _deserialize_variant(entry_obj.get("value"))
				v.set_map(entries)
		if data.has("array"):
			var arr: Array = []
			for elem in data["array"]:
				arr.append(_deserialize_variant(elem))
			v.set_array(arr)
		return v
	return StoryFlowVariant.new()


static func _deserialize_characters(data: Dictionary) -> Dictionary:
	var result := {}
	for path in data:
		var entry: Dictionary = data[path]
		var vars := {}
		var vars_data: Dictionary = entry.get("variables", {})
		for vname in vars_data:
			var ventry: Dictionary = vars_data[vname]
			var vdata := {"name": vname, "type": int(ventry.get("type", 0))}
			if vdata["type"] == StoryFlowTypes.VariableType.MAP:
				vdata["key_type"] = int(ventry.get("key_type", StoryFlowTypes.VariableType.STRING))
				vdata["value_type"] = int(ventry.get("value_type", StoryFlowTypes.VariableType.STRING))
			if ventry.has("value"):
				vdata["value"] = _deserialize_variant(ventry["value"])
			vars[vname] = vdata
		result[path] = vars
	return result


static func _deserialize_once_only(data: Array) -> Dictionary:
	var result := {}
	for key in data:
		result[str(key)] = true
	return result
