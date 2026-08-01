class_name StoryFlowHandles
extends RefCounted

# Preloaded by path so parsing never depends on the global class name cache,
# which can be stale or mid-rewrite when the game launches (godotengine/godot#75388).
const StoryFlowTypes = preload("res://addons/storyflow/core/storyflow_types.gd")

# =============================================================================
# Handle Builders
# =============================================================================

static func source(node_id: String, suffix: String = "") -> String:
	return "source-%s-%s" % [node_id, suffix]


static func target(node_id: String, suffix: String = "") -> String:
	return "target-%s-%s" % [node_id, suffix]


# =============================================================================
# Source Handle Output Suffixes
# =============================================================================

const OUT_DEFAULT := ""
const OUT_TRUE := "true"
const OUT_FALSE := "false"
const OUT_FLOW := "1"
const OUT_OUTPUT := "output"
const OUT_LOOP_BODY := "loopBody"
const OUT_LOOP_COMPLETED := "completed"

# Typed data output suffixes (trailing dash is part of the editor's format)
const OUT_BOOLEAN := "boolean-"
const OUT_INTEGER := "integer-"
const OUT_FLOAT := "float-"
const OUT_STRING := "string-"
const OUT_ENUM := "enum-"

# =============================================================================
# Target Handle Input Suffixes
# =============================================================================

# Single typed inputs
const IN_BOOLEAN := "boolean"
const IN_INTEGER := "integer"
const IN_FLOAT := "float"
const IN_STRING := "string"
const IN_ENUM := "enum"
const IN_IMAGE := "image"
const IN_CHARACTER := "character"
const IN_AUDIO := "audio"

# Numbered inputs (binary operations)
const IN_BOOLEAN1 := "boolean-1"
const IN_BOOLEAN2 := "boolean-2"
const IN_BOOLEAN_CONDITION := "boolean-condition"
const IN_INTEGER1 := "integer-1"
const IN_INTEGER2 := "integer-2"
const IN_INTEGER_INDEX := "integer-index"
const IN_INTEGER_VALUE := "integer-value"
const IN_FLOAT1 := "float-1"
const IN_FLOAT2 := "float-2"
const IN_STRING1 := "string-1"
const IN_STRING2 := "string-2"
const IN_ENUM1 := "enum-1"
const IN_ENUM2 := "enum-2"

# Array inputs
const IN_BOOL_ARRAY := "boolean-array"
const IN_INT_ARRAY := "integer-array"
const IN_FLOAT_ARRAY := "float-array"
const IN_STRING_ARRAY := "string-array"
const IN_IMAGE_ARRAY := "image-array"
const IN_CHARACTER_ARRAY := "character-array"
const IN_AUDIO_ARRAY := "audio-array"

# Media node inputs
const IN_IMAGE_INPUT := "image-image-input"
const IN_AUDIO_INPUT := "audio-audio-input"
const IN_CHARACTER_INPUT := "character-character-input"

# =============================================================================
# Data Type Suffixes (for detecting data edges)
# =============================================================================

static var _data_type_suffixes: Array[String] = [
	"boolean-", "integer-", "float-", "string-", "enum-",
	"image-", "character-", "audio-",
	# Map handles ("source-{id}-map-{keyType}-{valueType}") already match the
	# entries above through their embedded K/V type names, but classify them
	# explicitly so the rule does not depend on which types a map carries.
	"map-",
]


static func is_data_handle(source_handle: String) -> bool:
	for suffix in _data_type_suffixes:
		if source_handle.contains("-" + suffix):
			return true
	return false


## Returns the VariableType for a data handle suffix, or NONE if not a data suffix.
static func get_data_type_from_suffix(suffix: String) -> StoryFlowTypes.VariableType:
	if suffix.begins_with("boolean"):
		return StoryFlowTypes.VariableType.BOOLEAN
	elif suffix.begins_with("integer"):
		return StoryFlowTypes.VariableType.INTEGER
	elif suffix.begins_with("float"):
		return StoryFlowTypes.VariableType.FLOAT
	elif suffix.begins_with("string"):
		return StoryFlowTypes.VariableType.STRING
	elif suffix.begins_with("enum"):
		return StoryFlowTypes.VariableType.ENUM
	elif suffix.begins_with("image"):
		return StoryFlowTypes.VariableType.IMAGE
	elif suffix.begins_with("character"):
		return StoryFlowTypes.VariableType.CHARACTER
	elif suffix.begins_with("audio"):
		return StoryFlowTypes.VariableType.AUDIO
	return StoryFlowTypes.VariableType.NONE


# =============================================================================
# Map Handles
# =============================================================================
# Map handles bake the key/value types into the handle ID itself:
#   Source: "source-{nodeId}-map-{keyType}-{valueType}"             (no optionId)
#   Target: "target-{nodeId}-map-{keyType}-{valueType}-{optionId}"
# Target optionIds: "1" (pure map reads: getMapValue/hasMapKey/mapSize/
# mapKeys/mapValues), "2" (setMap + mutators: setMapValue/removeMapKey/
# clearMap), "map" (forEachMap), "input" (setCharacterVar's map input)
# — optionIds are NOT always digits.


## Build a map input handle suffix: "map-{key_type}-{value_type}-{option_id}".
static func in_map(key_type: String, value_type: String, option_id: String) -> String:
	return "map-%s-%s-%s" % [key_type, value_type, option_id]


# =============================================================================
# Handle Parsing
# =============================================================================

## Parses a handle string into { "is_source": bool, "node_id": String, "suffix": String }
static func parse(handle_string: String) -> Dictionary:
	var parts := handle_string.split("-", false, 2)
	if parts.size() < 2:
		return {}

	var result := {
		"is_source": parts[0] == "source",
		"node_id": parts[1],
		"suffix": "",
	}

	if parts.size() >= 3:
		result["suffix"] = parts[2]

	return result
