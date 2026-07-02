class_name StoryFlowLoopFrame
extends RefCounted

# Preloaded by path so parsing never depends on the global class name cache,
# which can be stale or mid-rewrite when the game launches (godotengine/godot#75388).
const StoryFlowTypes = preload("res://addons/storyflow/core/storyflow_types.gd")

## Node ID of the forEach loop node.
var node_id: String = ""

## Loop type (always FOR_EACH currently).
var type: StoryFlowTypes.LoopType = StoryFlowTypes.LoopType.FOR_EACH

## Current iteration index.
var current_index: int = 0
