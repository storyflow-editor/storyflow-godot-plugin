extends RefCounted
## Graph builders shared by the .sfd Data Asset test files.
##
## NOT A TEST. Every function here is a static constructor for a piece of a StoryFlowScript —
## nodes, variables, edges, and the assembly that indexes them — so the tests can spell out a
## graph as data and keep their own bodies to assertions.
##
## It exists because the .sfd tests are this repo's first GRAPH-WALK tests: the ladder's first
## rungs are questions about the graph (is anything on the dataAsset pin? is it a pill?) that
## can only be asked of a real script with real edges, and hand-rolling those edges twice gave
## the two files two different _edge signatures within a day of each other. One signature, one
## place. tests/test_data_asset_degraded.gd and tests/test_data_asset_nodes.gd use it today;
## the Task G3 host-API tests are the intended third consumer.
##
## HANDLE FORMATS are the load-bearing part and are the editor's, not invented here:
##   exec out       "source-{id}-"        (start, dialogue) / "source-{id}-1" (setters, OUT_FLOW)
##   exec in        "target-{id}-"
##   typed data out "source-{id}-{type}-" (the trailing dash is part of the editor's format)
##   the .sfd wire  "source-{pill}-dataAsset-" -> "target-{accessor}-dataAsset-asset"
##   map handles    "source-{id}-map-{K}-{V}" -> "target-{id}-map-{K}-{V}-{optionId}"
## Getting one of these wrong makes a test pass for the wrong reason — find_input_edge simply
## finds nothing and the arm under test degrades — so they live in one place too.

# Preloaded by path so parsing never depends on the global class name cache,
# which can be stale or mid-rewrite when the game launches (godotengine/godot#75388).
const Handles = preload("res://addons/storyflow/core/storyflow_handles.gd")
const ScriptScript = preload("res://addons/storyflow/core/storyflow_script.gd")
const Types = preload("res://addons/storyflow/core/storyflow_types.gd")
const VariantScript = preload("res://addons/storyflow/core/storyflow_variant.gd")


# =============================================================================
# Assembly
# =============================================================================

## A StoryFlowScript with its indices built — the one thing a caller must not forget, since an
## unindexed script finds no edges at all and every accessor in it degrades as "unwired".
static func build(path: String, nodes: Dictionary, connections: Array, variables: Dictionary = {}, strings: Dictionary = {}) -> StoryFlowScript:
	var script := ScriptScript.new()
	script.script_path = path
	script.nodes = nodes
	script.connections = connections
	script.variables = variables
	script.strings = strings
	script.build_indices()
	return script


# =============================================================================
# Nodes
# =============================================================================

## The generic node record. "type_string" is the WIRE name, which the trace lines print and
## which the unknown-node warnings quote, so it is worth spelling correctly even in a test.
static func node(id: String, node_type: Types.NodeType, type_string: String, data: Dictionary) -> Dictionary:
	return {"id": id, "type": node_type, "type_string": type_string, "data": data}


static func start(id: String = "0") -> Dictionary:
	return node(id, Types.NodeType.START, "start", {})


static func dialogue(id: String, options: Array = []) -> Dictionary:
	return node(id, Types.NodeType.DIALOGUE, "dialogue", {"title": "", "text": id, "options": options})


## The .sfd reference pill. Pass an empty asset_id for the unbound-pill ladder case.
static func pill(id: String, asset_id: String) -> Dictionary:
	return node(id, Types.NodeType.GET_DATA_ASSET, "getDataAsset", {"assetId": asset_id})


## A getDataAssetVariable. [param data] is the contract 2.2 node payload, duplicated so two
## accessors built from one payload stay independent — the wire-is-the-binding test hands the
## same Dictionary to both of its accessors on purpose.
static func accessor(id: String, data: Dictionary) -> Dictionary:
	return node(id, Types.NodeType.GET_DATA_ASSET_VARIABLE, "getDataAssetVariable", data.duplicate())


static func setter(id: String, data: Dictionary) -> Dictionary:
	return node(id, Types.NodeType.SET_DATA_ASSET_VARIABLE, "setDataAssetVariable", data.duplicate())


## A getDataAssetVariableNames. NO data of its own at all (engine contract 11.1) — the wire
## into its dataAsset pin is its whole binding.
static func names_node(id: String) -> Dictionary:
	return node(id, Types.NodeType.GET_DATA_ASSET_VARIABLE_NAMES, "getDataAssetVariableNames", {})


# =============================================================================
# Variables
# =============================================================================

static func scalar_var(id: String, name: String, type: Types.VariableType, value) -> Dictionary:
	return {"id": id, "name": name, "type": type, "value": value}


## An array variable. Elements arrive as plain values and are stored as STRING-tagged variants
## while the variable itself carries [param type]; that is the shape the array evaluators read,
## and the .sfd write path re-mints every element against its declaration anyway.
static func array_var(id: String, name: String, type: Types.VariableType, values: Array) -> Dictionary:
	var elements: Array = []
	for value in values:
		elements.append(VariantScript.from_string(str(value)))
	var variant := VariantScript.new()
	variant.set_array(elements)
	variant.type = type
	return {"id": id, "name": name, "type": type, "value": variant, "is_array": true}


static func map_var(id: String, name: String, entries: Dictionary) -> Dictionary:
	return {"id": id, "name": name, "type": Types.VariableType.MAP, "value": VariantScript.from_map(entries)}


# =============================================================================
# Edges
# =============================================================================

## THE edge constructor. The id is derived rather than passed: nothing in the runtime reads a
## connection's id, and hand-numbered ids were the whole of the difference between the two
## signatures this file replaced.
static func edge(source: String, source_handle: String, target: String, target_handle: String) -> Dictionary:
	return {
		"id": "%s->%s:%s" % [source, target, target_handle],
		"source": source, "target": target,
		"source_handle": source_handle, "target_handle": target_handle,
	}


## The exec edge out of a node whose flow output carries no suffix (start, dialogue header).
static func exec(source: String, target: String) -> Dictionary:
	return edge(source, Handles.source(source), target, Handles.target(target))


## The exec edge out of a SET node, which flows from its OUT_FLOW pin ("source-{id}-1").
static func exec_flow(source: String, target: String) -> Dictionary:
	return edge(source, Handles.source(source, Handles.OUT_FLOW), target, Handles.target(target))


## The .sfd reference wire, pill -> accessor. The ONLY thing that binds an accessor to an
## asset (contract 2.2), which is why it has its own builder rather than a data_wire call.
static func pill_wire(pill_id: String, target_id: String) -> Dictionary:
	return edge(pill_id, "source-%s-dataAsset-" % pill_id, target_id, Handles.target(target_id, Handles.IN_DATA_ASSET))


## A typed data wire. [param source_type] is the source pin's type token ("integer",
## "string-array", ...); [param target_suffix] is the full target suffix, since input pins
## carry option ids the output side does not.
static func data_wire(source: String, source_type: String, target: String, target_suffix: String) -> Dictionary:
	return edge(source, "source-%s-%s-" % [source, source_type], target, Handles.target(target, target_suffix))


## A map wire. Map handles bake K/V into the id itself, and the SOURCE side carries no option
## id while the target does — the asymmetry is the editor's.
static func map_wire(source: String, target: String, key_type: String, value_type: String, option_id: String) -> Dictionary:
	return edge(source, "source-%s-map-%s-%s" % [source, key_type, value_type],
		target, Handles.target(target, Handles.in_map(key_type, value_type, option_id)))
