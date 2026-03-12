class_name StoryFlowVariableChangeInfo
extends RefCounted

## The variable ID (key in the variables dictionary).
var id: String = ""

## The display name of the variable.
var name: String = ""

## The new value after the change.
var value: StoryFlowVariant = null

## Whether this is a global variable (true) or script-local (false).
var is_global: bool = false
