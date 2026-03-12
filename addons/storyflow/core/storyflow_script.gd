class_name StoryFlowScript
extends RefCounted

var script_path: String = ""

## node_id → Dictionary with keys: "id", "type" (NodeType enum), "type_string", "data" (Dictionary)
var nodes: Dictionary = {}

## Array of connection Dictionaries: { "id", "source", "target", "source_handle", "target_handle" }
var connections: Array = []

## id → variable Dictionary: { "id", "name", "type", "value" (StoryFlowVariant), "is_array", "enum_values", "is_input", "is_output" }
var variables: Dictionary = {}

## "lang.key" → "value"
var strings: Dictionary = {}

## id → { "id", "type", "path" }
var assets: Dictionary = {}

## flow_id → { "id", "name", "is_exit" }
var flows: Dictionary = {}

## Resolved loaded resources: asset_key → Resource
var resolved_assets: Dictionary = {}

# =============================================================================
# Indices (built after import for fast lookup)
# =============================================================================

## source_handle → connection Dictionary
var source_handle_index: Dictionary = {}

## source_node_id → [connection Dictionaries]
var source_node_index: Dictionary = {}

## target_node_id → [connection Dictionaries]
var target_node_index: Dictionary = {}


func build_indices() -> void:
	source_handle_index.clear()
	source_node_index.clear()
	target_node_index.clear()

	for conn in connections:
		var sh: String = conn.get("source_handle", "")
		if sh != "":
			source_handle_index[sh] = conn

		var src: String = conn.get("source", "")
		if src != "":
			if not source_node_index.has(src):
				source_node_index[src] = []
			source_node_index[src].append(conn)

		var tgt: String = conn.get("target", "")
		if tgt != "":
			if not target_node_index.has(tgt):
				target_node_index[tgt] = []
			target_node_index[tgt].append(conn)


func get_start_node() -> Dictionary:
	return nodes.get("0", {})


func get_node(node_id: String) -> Dictionary:
	return nodes.get(node_id, {})


func find_connection_by_source_handle(source_handle: String) -> Dictionary:
	return source_handle_index.get(source_handle, {})


func find_connections_from_node(node_id: String) -> Array:
	return source_node_index.get(node_id, [])


func find_connections_to_node(node_id: String) -> Array:
	return target_node_index.get(node_id, [])


func find_input_edge(node_id: String, target_suffix: String) -> Dictionary:
	var target_handle := StoryFlowHandles.target(node_id, target_suffix)
	var incoming := find_connections_to_node(node_id)
	for conn in incoming:
		if conn.get("target_handle", "") == target_handle:
			return conn
	return {}


func get_localized_string(key: String, language: String = "en") -> String:
	var full_key := language + "." + key
	return strings.get(full_key, key)
