class_name StoryFlowCharacter
extends RefCounted

## String table key for display name
var character_name: String = ""

## Asset key for default portrait image
var image_key: String = ""

## Normalized character path (for lookup)
var character_path: String = ""

## Character-specific variables: var_name → { "name", "type", "value" (StoryFlowVariant) }
var variables: Dictionary = {}

## Resolved assets: asset_key → Resource (Texture2D)
var resolved_assets: Dictionary = {}


## CRITICAL: normalize character paths consistently for storage and lookup
static func normalize_path(path: String) -> String:
	return path.to_lower().replace("/", "\\")


func duplicate_character() -> StoryFlowCharacter:
	var c := StoryFlowCharacter.new()
	c.character_name = character_name
	c.image_key = image_key
	c.character_path = character_path
	c.resolved_assets = resolved_assets.duplicate()
	# Deep copy variables
	for key in variables:
		var v: Dictionary = variables[key]
		var dup := v.duplicate()
		if dup.has("value") and dup["value"] is StoryFlowVariant:
			dup["value"] = dup["value"].duplicate_variant()
		c.variables[key] = dup
	return c
