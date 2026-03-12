class_name StoryFlowLoopFrame
extends RefCounted

## Node ID of the forEach loop node.
var node_id: String = ""

## Loop type (always FOR_EACH currently).
var type: StoryFlowTypes.LoopType = StoryFlowTypes.LoopType.FOR_EACH

## Current iteration index.
var current_index: int = 0
