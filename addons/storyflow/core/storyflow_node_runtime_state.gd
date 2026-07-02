class_name StoryFlowNodeRuntimeState
extends RefCounted

# Preloaded by path so parsing never depends on the global class name cache,
# which can be stale or mid-rewrite when the game launches (godotengine/godot#75388).
const StoryFlowVariant = preload("res://addons/storyflow/core/storyflow_variant.gd")

## Cached evaluation output (used by evaluator to avoid re-evaluation).
var cached_output: StoryFlowVariant = null

## Current loop index (for forEach nodes).
var loop_index: int = 0

## Array being iterated (for forEach nodes).
var loop_array: Array = []

## Whether the loop has been initialized.
var loop_initialized: bool = false

## Map loop state (forEachMap). loop_keys/loop_values are a SNAPSHOT of the
## map's entries taken once at loop init (parallel arrays, insertion order) —
## body mutations land on the live map but never affect iteration. loop_key
## (raw int/String key) and loop_value expose the current entry to the typed
## evaluators (read via the "-key"/"-value" source handle suffixes). These are
## dedicated fields rather than cached_output so clear_cached_outputs() — which
## runs every iteration — does not wipe them.
var loop_keys: Array = []
var loop_values: Array = []
var loop_key = null
var loop_value: StoryFlowVariant = null

## Output variable values from RunScript return (variable_id → StoryFlowVariant).
var output_values: Dictionary = {}

## Whether output_values has been populated.
var has_output_values: bool = false
