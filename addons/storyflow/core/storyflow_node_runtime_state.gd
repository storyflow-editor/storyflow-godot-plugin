class_name StoryFlowNodeRuntimeState
extends RefCounted

## Cached evaluation output (used by evaluator to avoid re-evaluation).
var cached_output: StoryFlowVariant = null

## Current loop index (for forEach nodes).
var loop_index: int = 0

## Array being iterated (for forEach nodes).
var loop_array: Array = []

## Whether the loop has been initialized.
var loop_initialized: bool = false

## Output variable values from RunScript return (name → StoryFlowVariant).
var output_values: Dictionary = {}

## Whether output_values has been populated.
var has_output_values: bool = false
