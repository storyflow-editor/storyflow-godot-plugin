class_name StoryFlowCallFrame
extends RefCounted

## Path of the calling script.
var script_path: String = ""

## Node ID of the RunScript node to return to.
var return_node_id: String = ""

## Reference to the calling script asset.
var script_asset: StoryFlowScript = null

## Deep copy of local variables at the time of the call.
var saved_variables: Dictionary = {}

## Saved flow call stack IDs.
var saved_flow_stack: Array[String] = []
