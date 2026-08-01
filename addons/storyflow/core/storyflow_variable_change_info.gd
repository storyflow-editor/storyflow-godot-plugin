class_name StoryFlowVariableChangeInfo
extends RefCounted

# Preloaded by path so parsing never depends on the global class name cache,
# which can be stale or mid-rewrite when the game launches (godotengine/godot#75388).
const StoryFlowVariant = preload("res://addons/storyflow/core/storyflow_variant.gd")

## The variable ID (key in the variables dictionary).
var id: String = ""

## The display name of the variable.
var name: String = ""

## The new value after the change.
var value: StoryFlowVariant = null

## Whether this is a global variable (true) or script-local (false).
var is_global: bool = false
