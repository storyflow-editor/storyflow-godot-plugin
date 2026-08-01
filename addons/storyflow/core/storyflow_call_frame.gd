class_name StoryFlowCallFrame
extends RefCounted

# Preloaded by path so parsing never depends on the global class name cache,
# which can be stale or mid-rewrite when the game launches (godotengine/godot#75388).
const StoryFlowScript = preload("res://addons/storyflow/core/storyflow_script.gd")

## Path of the calling script.
var script_path: String = ""

## Node ID of the RunScript node to return to.
var return_node_id: String = ""

## Reference to the calling script asset.
var script_asset: StoryFlowScript = null

## The caller's live local-variable records at the time of the call (SHARED,
## not copied — HTML slice semantics: map aliasing established before the call
## must survive it). Safe because the called script reassigns the context's
## local_variables Dictionary rather than mutating this one.
var saved_variables: Dictionary = {}

## Saved flow call stack IDs.
var saved_flow_stack: Array[String] = []
