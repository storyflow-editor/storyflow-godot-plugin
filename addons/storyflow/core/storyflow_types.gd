class_name StoryFlowTypes
extends RefCounted

# =============================================================================
# Node Type Enum
# =============================================================================

enum NodeType {
	# Control Flow
	START,
	END,
	BRANCH,
	RUN_SCRIPT,
	RUN_FLOW,
	ENTRY_FLOW,

	# Dialogue
	DIALOGUE,

	# Boolean
	GET_BOOL,
	SET_BOOL,
	AND_BOOL,
	OR_BOOL,
	NOT_BOOL,
	EQUAL_BOOL,

	# Integer
	GET_INT,
	SET_INT,
	PLUS,
	MINUS,
	MULTIPLY,
	DIVIDE,
	RANDOM,

	# Integer Comparison
	GREATER_THAN,
	GREATER_THAN_OR_EQUAL,
	LESS_THAN,
	LESS_THAN_OR_EQUAL,
	EQUAL_INT,

	# Float
	GET_FLOAT,
	SET_FLOAT,
	PLUS_FLOAT,
	MINUS_FLOAT,
	MULTIPLY_FLOAT,
	DIVIDE_FLOAT,
	RANDOM_FLOAT,

	# Float Comparison
	GREATER_THAN_FLOAT,
	GREATER_THAN_OR_EQUAL_FLOAT,
	LESS_THAN_FLOAT,
	LESS_THAN_OR_EQUAL_FLOAT,
	EQUAL_FLOAT,

	# String
	GET_STRING,
	SET_STRING,
	CONCATENATE_STRING,
	EQUAL_STRING,
	CONTAINS_STRING,
	TO_UPPER_CASE,
	TO_LOWER_CASE,

	# Enum
	GET_ENUM,
	SET_ENUM,
	EQUAL_ENUM,
	SWITCH_ON_ENUM,
	RANDOM_BRANCH,

	# Type Conversion
	INT_TO_BOOLEAN,
	FLOAT_TO_BOOLEAN,
	BOOLEAN_TO_INT,
	BOOLEAN_TO_FLOAT,
	INT_TO_STRING,
	FLOAT_TO_STRING,
	STRING_TO_INT,
	STRING_TO_FLOAT,
	INT_TO_ENUM,
	STRING_TO_ENUM,
	INT_TO_FLOAT,
	FLOAT_TO_INT,
	ENUM_TO_STRING,
	LENGTH_STRING,

	# Boolean Arrays
	GET_BOOL_ARRAY,
	SET_BOOL_ARRAY,
	GET_BOOL_ARRAY_ELEMENT,
	SET_BOOL_ARRAY_ELEMENT,
	GET_RANDOM_BOOL_ARRAY_ELEMENT,
	ADD_TO_BOOL_ARRAY,
	REMOVE_FROM_BOOL_ARRAY,
	CLEAR_BOOL_ARRAY,
	ARRAY_LENGTH_BOOL,
	ARRAY_CONTAINS_BOOL,
	FIND_IN_BOOL_ARRAY,

	# Integer Arrays
	GET_INT_ARRAY,
	SET_INT_ARRAY,
	GET_INT_ARRAY_ELEMENT,
	SET_INT_ARRAY_ELEMENT,
	GET_RANDOM_INT_ARRAY_ELEMENT,
	ADD_TO_INT_ARRAY,
	REMOVE_FROM_INT_ARRAY,
	CLEAR_INT_ARRAY,
	ARRAY_LENGTH_INT,
	ARRAY_CONTAINS_INT,
	FIND_IN_INT_ARRAY,

	# Float Arrays
	GET_FLOAT_ARRAY,
	SET_FLOAT_ARRAY,
	GET_FLOAT_ARRAY_ELEMENT,
	SET_FLOAT_ARRAY_ELEMENT,
	GET_RANDOM_FLOAT_ARRAY_ELEMENT,
	ADD_TO_FLOAT_ARRAY,
	REMOVE_FROM_FLOAT_ARRAY,
	CLEAR_FLOAT_ARRAY,
	ARRAY_LENGTH_FLOAT,
	ARRAY_CONTAINS_FLOAT,
	FIND_IN_FLOAT_ARRAY,

	# String Arrays
	GET_STRING_ARRAY,
	SET_STRING_ARRAY,
	GET_STRING_ARRAY_ELEMENT,
	SET_STRING_ARRAY_ELEMENT,
	GET_RANDOM_STRING_ARRAY_ELEMENT,
	ADD_TO_STRING_ARRAY,
	REMOVE_FROM_STRING_ARRAY,
	CLEAR_STRING_ARRAY,
	ARRAY_LENGTH_STRING,
	ARRAY_CONTAINS_STRING,
	FIND_IN_STRING_ARRAY,

	# Image Arrays
	GET_IMAGE_ARRAY,
	SET_IMAGE_ARRAY,
	GET_IMAGE_ARRAY_ELEMENT,
	SET_IMAGE_ARRAY_ELEMENT,
	GET_RANDOM_IMAGE_ARRAY_ELEMENT,
	ADD_TO_IMAGE_ARRAY,
	REMOVE_FROM_IMAGE_ARRAY,
	CLEAR_IMAGE_ARRAY,
	ARRAY_LENGTH_IMAGE,
	ARRAY_CONTAINS_IMAGE,
	FIND_IN_IMAGE_ARRAY,

	# Character Arrays
	GET_CHARACTER_ARRAY,
	SET_CHARACTER_ARRAY,
	GET_CHARACTER_ARRAY_ELEMENT,
	SET_CHARACTER_ARRAY_ELEMENT,
	GET_RANDOM_CHARACTER_ARRAY_ELEMENT,
	ADD_TO_CHARACTER_ARRAY,
	REMOVE_FROM_CHARACTER_ARRAY,
	CLEAR_CHARACTER_ARRAY,
	ARRAY_LENGTH_CHARACTER,
	ARRAY_CONTAINS_CHARACTER,
	FIND_IN_CHARACTER_ARRAY,

	# Audio Arrays
	GET_AUDIO_ARRAY,
	SET_AUDIO_ARRAY,
	GET_AUDIO_ARRAY_ELEMENT,
	SET_AUDIO_ARRAY_ELEMENT,
	GET_RANDOM_AUDIO_ARRAY_ELEMENT,
	ADD_TO_AUDIO_ARRAY,
	REMOVE_FROM_AUDIO_ARRAY,
	CLEAR_AUDIO_ARRAY,
	ARRAY_LENGTH_AUDIO,
	ARRAY_CONTAINS_AUDIO,
	FIND_IN_AUDIO_ARRAY,

	# Loops
	FOR_EACH_BOOL_LOOP,
	FOR_EACH_INT_LOOP,
	FOR_EACH_FLOAT_LOOP,
	FOR_EACH_STRING_LOOP,
	FOR_EACH_IMAGE_LOOP,
	FOR_EACH_CHARACTER_LOOP,
	FOR_EACH_AUDIO_LOOP,

	# Media
	GET_IMAGE,
	SET_IMAGE,
	SET_BACKGROUND_IMAGE,
	GET_AUDIO,
	SET_AUDIO,
	PLAY_AUDIO,
	GET_CHARACTER,
	SET_CHARACTER,

	# Character Variables
	GET_CHARACTER_VAR,
	SET_CHARACTER_VAR,

	UNKNOWN,
}

enum VariableType {
	NONE,
	BOOLEAN,
	INTEGER,
	FLOAT,
	STRING,
	ENUM,
	IMAGE,
	AUDIO,
	CHARACTER,
}

enum AssetType {
	IMAGE,
	AUDIO,
	VIDEO,
}

enum LoopType {
	FOR_EACH,
}

# =============================================================================
# JSON String → NodeType Mapping
# =============================================================================

static var _node_type_map: Dictionary = {
	# Control Flow
	"start": NodeType.START,
	"end": NodeType.END,
	"branch": NodeType.BRANCH,
	"runScript": NodeType.RUN_SCRIPT,
	"runFlow": NodeType.RUN_FLOW,
	"entryFlow": NodeType.ENTRY_FLOW,

	# Dialogue
	"dialogue": NodeType.DIALOGUE,

	# Boolean
	"getBool": NodeType.GET_BOOL,
	"setBool": NodeType.SET_BOOL,
	"andBool": NodeType.AND_BOOL,
	"orBool": NodeType.OR_BOOL,
	"notBool": NodeType.NOT_BOOL,
	"equalBool": NodeType.EQUAL_BOOL,

	# Integer
	"getInt": NodeType.GET_INT,
	"setInt": NodeType.SET_INT,
	"plus": NodeType.PLUS,
	"minus": NodeType.MINUS,
	"multiply": NodeType.MULTIPLY,
	"divide": NodeType.DIVIDE,
	"random": NodeType.RANDOM,

	# Integer Comparison
	"greaterThan": NodeType.GREATER_THAN,
	"greaterThanOrEqual": NodeType.GREATER_THAN_OR_EQUAL,
	"lessThan": NodeType.LESS_THAN,
	"lessThanOrEqual": NodeType.LESS_THAN_OR_EQUAL,
	"equalInt": NodeType.EQUAL_INT,

	# Float
	"getFloat": NodeType.GET_FLOAT,
	"setFloat": NodeType.SET_FLOAT,
	"plusFloat": NodeType.PLUS_FLOAT,
	"minusFloat": NodeType.MINUS_FLOAT,
	"multiplyFloat": NodeType.MULTIPLY_FLOAT,
	"divideFloat": NodeType.DIVIDE_FLOAT,
	"randomFloat": NodeType.RANDOM_FLOAT,

	# Float Comparison
	"greaterThanFloat": NodeType.GREATER_THAN_FLOAT,
	"greaterThanOrEqualFloat": NodeType.GREATER_THAN_OR_EQUAL_FLOAT,
	"lessThanFloat": NodeType.LESS_THAN_FLOAT,
	"lessThanOrEqualFloat": NodeType.LESS_THAN_OR_EQUAL_FLOAT,
	"equalFloat": NodeType.EQUAL_FLOAT,

	# String
	"getString": NodeType.GET_STRING,
	"setString": NodeType.SET_STRING,
	"concatenateString": NodeType.CONCATENATE_STRING,
	"equalString": NodeType.EQUAL_STRING,
	"containsString": NodeType.CONTAINS_STRING,
	"toUpperCase": NodeType.TO_UPPER_CASE,
	"toLowerCase": NodeType.TO_LOWER_CASE,

	# Enum
	"getEnum": NodeType.GET_ENUM,
	"setEnum": NodeType.SET_ENUM,
	"equalEnum": NodeType.EQUAL_ENUM,
	"switchOnEnum": NodeType.SWITCH_ON_ENUM,
	"randomBranch": NodeType.RANDOM_BRANCH,

	# Type Conversion
	"intToBoolean": NodeType.INT_TO_BOOLEAN,
	"floatToBoolean": NodeType.FLOAT_TO_BOOLEAN,
	"booleanToInt": NodeType.BOOLEAN_TO_INT,
	"booleanToFloat": NodeType.BOOLEAN_TO_FLOAT,
	"intToString": NodeType.INT_TO_STRING,
	"floatToString": NodeType.FLOAT_TO_STRING,
	"stringToInt": NodeType.STRING_TO_INT,
	"stringToFloat": NodeType.STRING_TO_FLOAT,
	"intToEnum": NodeType.INT_TO_ENUM,
	"stringToEnum": NodeType.STRING_TO_ENUM,
	"intToFloat": NodeType.INT_TO_FLOAT,
	"floatToInt": NodeType.FLOAT_TO_INT,
	"enumToString": NodeType.ENUM_TO_STRING,
	"lengthString": NodeType.LENGTH_STRING,

	# Boolean Arrays
	"getBoolArray": NodeType.GET_BOOL_ARRAY,
	"setBoolArray": NodeType.SET_BOOL_ARRAY,
	"getBoolArrayElement": NodeType.GET_BOOL_ARRAY_ELEMENT,
	"setBoolArrayElement": NodeType.SET_BOOL_ARRAY_ELEMENT,
	"getRandomBoolArrayElement": NodeType.GET_RANDOM_BOOL_ARRAY_ELEMENT,
	"addToBoolArray": NodeType.ADD_TO_BOOL_ARRAY,
	"removeFromBoolArray": NodeType.REMOVE_FROM_BOOL_ARRAY,
	"clearBoolArray": NodeType.CLEAR_BOOL_ARRAY,
	"arrayLengthBool": NodeType.ARRAY_LENGTH_BOOL,
	"arrayContainsBool": NodeType.ARRAY_CONTAINS_BOOL,
	"findInBoolArray": NodeType.FIND_IN_BOOL_ARRAY,

	# Integer Arrays
	"getIntArray": NodeType.GET_INT_ARRAY,
	"setIntArray": NodeType.SET_INT_ARRAY,
	"getIntArrayElement": NodeType.GET_INT_ARRAY_ELEMENT,
	"setIntArrayElement": NodeType.SET_INT_ARRAY_ELEMENT,
	"getRandomIntArrayElement": NodeType.GET_RANDOM_INT_ARRAY_ELEMENT,
	"addToIntArray": NodeType.ADD_TO_INT_ARRAY,
	"removeFromIntArray": NodeType.REMOVE_FROM_INT_ARRAY,
	"clearIntArray": NodeType.CLEAR_INT_ARRAY,
	"arrayLengthInt": NodeType.ARRAY_LENGTH_INT,
	"arrayContainsInt": NodeType.ARRAY_CONTAINS_INT,
	"findInIntArray": NodeType.FIND_IN_INT_ARRAY,

	# Float Arrays
	"getFloatArray": NodeType.GET_FLOAT_ARRAY,
	"setFloatArray": NodeType.SET_FLOAT_ARRAY,
	"getFloatArrayElement": NodeType.GET_FLOAT_ARRAY_ELEMENT,
	"setFloatArrayElement": NodeType.SET_FLOAT_ARRAY_ELEMENT,
	"getRandomFloatArrayElement": NodeType.GET_RANDOM_FLOAT_ARRAY_ELEMENT,
	"addToFloatArray": NodeType.ADD_TO_FLOAT_ARRAY,
	"removeFromFloatArray": NodeType.REMOVE_FROM_FLOAT_ARRAY,
	"clearFloatArray": NodeType.CLEAR_FLOAT_ARRAY,
	"arrayLengthFloat": NodeType.ARRAY_LENGTH_FLOAT,
	"arrayContainsFloat": NodeType.ARRAY_CONTAINS_FLOAT,
	"findInFloatArray": NodeType.FIND_IN_FLOAT_ARRAY,

	# String Arrays
	"getStringArray": NodeType.GET_STRING_ARRAY,
	"setStringArray": NodeType.SET_STRING_ARRAY,
	"getStringArrayElement": NodeType.GET_STRING_ARRAY_ELEMENT,
	"setStringArrayElement": NodeType.SET_STRING_ARRAY_ELEMENT,
	"getRandomStringArrayElement": NodeType.GET_RANDOM_STRING_ARRAY_ELEMENT,
	"addToStringArray": NodeType.ADD_TO_STRING_ARRAY,
	"removeFromStringArray": NodeType.REMOVE_FROM_STRING_ARRAY,
	"clearStringArray": NodeType.CLEAR_STRING_ARRAY,
	"arrayLengthString": NodeType.ARRAY_LENGTH_STRING,
	"arrayContainsString": NodeType.ARRAY_CONTAINS_STRING,
	"findInStringArray": NodeType.FIND_IN_STRING_ARRAY,

	# Image Arrays
	"getImageArray": NodeType.GET_IMAGE_ARRAY,
	"setImageArray": NodeType.SET_IMAGE_ARRAY,
	"getImageArrayElement": NodeType.GET_IMAGE_ARRAY_ELEMENT,
	"setImageArrayElement": NodeType.SET_IMAGE_ARRAY_ELEMENT,
	"getRandomImageArrayElement": NodeType.GET_RANDOM_IMAGE_ARRAY_ELEMENT,
	"addToImageArray": NodeType.ADD_TO_IMAGE_ARRAY,
	"removeFromImageArray": NodeType.REMOVE_FROM_IMAGE_ARRAY,
	"clearImageArray": NodeType.CLEAR_IMAGE_ARRAY,
	"arrayLengthImage": NodeType.ARRAY_LENGTH_IMAGE,
	"arrayContainsImage": NodeType.ARRAY_CONTAINS_IMAGE,
	"findInImageArray": NodeType.FIND_IN_IMAGE_ARRAY,

	# Character Arrays
	"getCharacterArray": NodeType.GET_CHARACTER_ARRAY,
	"setCharacterArray": NodeType.SET_CHARACTER_ARRAY,
	"getCharacterArrayElement": NodeType.GET_CHARACTER_ARRAY_ELEMENT,
	"setCharacterArrayElement": NodeType.SET_CHARACTER_ARRAY_ELEMENT,
	"getRandomCharacterArrayElement": NodeType.GET_RANDOM_CHARACTER_ARRAY_ELEMENT,
	"addToCharacterArray": NodeType.ADD_TO_CHARACTER_ARRAY,
	"removeFromCharacterArray": NodeType.REMOVE_FROM_CHARACTER_ARRAY,
	"clearCharacterArray": NodeType.CLEAR_CHARACTER_ARRAY,
	"arrayLengthCharacter": NodeType.ARRAY_LENGTH_CHARACTER,
	"arrayContainsCharacter": NodeType.ARRAY_CONTAINS_CHARACTER,
	"findInCharacterArray": NodeType.FIND_IN_CHARACTER_ARRAY,

	# Audio Arrays
	"getAudioArray": NodeType.GET_AUDIO_ARRAY,
	"setAudioArray": NodeType.SET_AUDIO_ARRAY,
	"getAudioArrayElement": NodeType.GET_AUDIO_ARRAY_ELEMENT,
	"setAudioArrayElement": NodeType.SET_AUDIO_ARRAY_ELEMENT,
	"getRandomAudioArrayElement": NodeType.GET_RANDOM_AUDIO_ARRAY_ELEMENT,
	"addToAudioArray": NodeType.ADD_TO_AUDIO_ARRAY,
	"removeFromAudioArray": NodeType.REMOVE_FROM_AUDIO_ARRAY,
	"clearAudioArray": NodeType.CLEAR_AUDIO_ARRAY,
	"arrayLengthAudio": NodeType.ARRAY_LENGTH_AUDIO,
	"arrayContainsAudio": NodeType.ARRAY_CONTAINS_AUDIO,
	"findInAudioArray": NodeType.FIND_IN_AUDIO_ARRAY,

	# Loops
	"forEachBoolLoop": NodeType.FOR_EACH_BOOL_LOOP,
	"forEachIntLoop": NodeType.FOR_EACH_INT_LOOP,
	"forEachFloatLoop": NodeType.FOR_EACH_FLOAT_LOOP,
	"forEachStringLoop": NodeType.FOR_EACH_STRING_LOOP,
	"forEachImageLoop": NodeType.FOR_EACH_IMAGE_LOOP,
	"forEachCharacterLoop": NodeType.FOR_EACH_CHARACTER_LOOP,
	"forEachAudioLoop": NodeType.FOR_EACH_AUDIO_LOOP,

	# Media
	"getImage": NodeType.GET_IMAGE,
	"setImage": NodeType.SET_IMAGE,
	"setBackgroundImage": NodeType.SET_BACKGROUND_IMAGE,
	"getAudio": NodeType.GET_AUDIO,
	"setAudio": NodeType.SET_AUDIO,
	"playAudio": NodeType.PLAY_AUDIO,
	"getCharacter": NodeType.GET_CHARACTER,
	"setCharacter": NodeType.SET_CHARACTER,

	# Character Variables
	"getCharacterVar": NodeType.GET_CHARACTER_VAR,
	"setCharacterVar": NodeType.SET_CHARACTER_VAR,
}


static func parse_node_type(type_string: String) -> NodeType:
	return _node_type_map.get(type_string, NodeType.UNKNOWN)


# =============================================================================
# JSON String → VariableType Mapping
# =============================================================================

static var _variable_type_map: Dictionary = {
	"boolean": VariableType.BOOLEAN,
	"integer": VariableType.INTEGER,
	"float": VariableType.FLOAT,
	"string": VariableType.STRING,
	"enum": VariableType.ENUM,
	"image": VariableType.IMAGE,
	"audio": VariableType.AUDIO,
	"character": VariableType.CHARACTER,
}


static func parse_variable_type(type_string: String) -> VariableType:
	return _variable_type_map.get(type_string, VariableType.NONE)


# =============================================================================
# Set Node Detection
# =============================================================================

static var _set_node_types: Array[NodeType] = [
	NodeType.SET_BOOL, NodeType.SET_INT, NodeType.SET_FLOAT,
	NodeType.SET_STRING, NodeType.SET_ENUM,
	NodeType.SET_IMAGE, NodeType.SET_AUDIO, NodeType.SET_CHARACTER,
	NodeType.SET_BOOL_ARRAY, NodeType.SET_INT_ARRAY, NodeType.SET_FLOAT_ARRAY,
	NodeType.SET_STRING_ARRAY, NodeType.SET_IMAGE_ARRAY,
	NodeType.SET_CHARACTER_ARRAY, NodeType.SET_AUDIO_ARRAY,
	NodeType.SET_BOOL_ARRAY_ELEMENT, NodeType.SET_INT_ARRAY_ELEMENT,
	NodeType.SET_FLOAT_ARRAY_ELEMENT, NodeType.SET_STRING_ARRAY_ELEMENT,
	NodeType.SET_IMAGE_ARRAY_ELEMENT, NodeType.SET_CHARACTER_ARRAY_ELEMENT,
	NodeType.SET_AUDIO_ARRAY_ELEMENT,
	NodeType.ADD_TO_BOOL_ARRAY, NodeType.ADD_TO_INT_ARRAY,
	NodeType.ADD_TO_FLOAT_ARRAY, NodeType.ADD_TO_STRING_ARRAY,
	NodeType.ADD_TO_IMAGE_ARRAY, NodeType.ADD_TO_CHARACTER_ARRAY,
	NodeType.ADD_TO_AUDIO_ARRAY,
	NodeType.REMOVE_FROM_BOOL_ARRAY, NodeType.REMOVE_FROM_INT_ARRAY,
	NodeType.REMOVE_FROM_FLOAT_ARRAY, NodeType.REMOVE_FROM_STRING_ARRAY,
	NodeType.REMOVE_FROM_IMAGE_ARRAY, NodeType.REMOVE_FROM_CHARACTER_ARRAY,
	NodeType.REMOVE_FROM_AUDIO_ARRAY,
	NodeType.CLEAR_BOOL_ARRAY, NodeType.CLEAR_INT_ARRAY,
	NodeType.CLEAR_FLOAT_ARRAY, NodeType.CLEAR_STRING_ARRAY,
	NodeType.CLEAR_IMAGE_ARRAY, NodeType.CLEAR_CHARACTER_ARRAY,
	NodeType.CLEAR_AUDIO_ARRAY,
	NodeType.SET_CHARACTER_VAR,
	NodeType.SET_BACKGROUND_IMAGE,
	NodeType.PLAY_AUDIO,
]


static func is_set_node(node_type: NodeType) -> bool:
	return node_type in _set_node_types


# =============================================================================
# Logic/Data Node Detection (no-op at execution, evaluated lazily)
# =============================================================================

static var _logic_node_types: Array[NodeType] = [
	# Boolean logic
	NodeType.AND_BOOL, NodeType.OR_BOOL, NodeType.NOT_BOOL, NodeType.EQUAL_BOOL,
	# Integer arithmetic & comparison
	NodeType.PLUS, NodeType.MINUS, NodeType.MULTIPLY, NodeType.DIVIDE, NodeType.RANDOM,
	NodeType.GREATER_THAN, NodeType.GREATER_THAN_OR_EQUAL,
	NodeType.LESS_THAN, NodeType.LESS_THAN_OR_EQUAL, NodeType.EQUAL_INT,
	# Float arithmetic & comparison
	NodeType.PLUS_FLOAT, NodeType.MINUS_FLOAT, NodeType.MULTIPLY_FLOAT,
	NodeType.DIVIDE_FLOAT, NodeType.RANDOM_FLOAT,
	NodeType.GREATER_THAN_FLOAT, NodeType.GREATER_THAN_OR_EQUAL_FLOAT,
	NodeType.LESS_THAN_FLOAT, NodeType.LESS_THAN_OR_EQUAL_FLOAT, NodeType.EQUAL_FLOAT,
	# String operations
	NodeType.CONCATENATE_STRING, NodeType.EQUAL_STRING, NodeType.CONTAINS_STRING,
	NodeType.TO_UPPER_CASE, NodeType.TO_LOWER_CASE, NodeType.LENGTH_STRING,
	# Enum operations
	NodeType.EQUAL_ENUM, NodeType.ENUM_TO_STRING,
	# Type conversions
	NodeType.INT_TO_BOOLEAN, NodeType.FLOAT_TO_BOOLEAN,
	NodeType.BOOLEAN_TO_INT, NodeType.BOOLEAN_TO_FLOAT,
	NodeType.INT_TO_STRING, NodeType.FLOAT_TO_STRING,
	NodeType.STRING_TO_INT, NodeType.STRING_TO_FLOAT,
	NodeType.INT_TO_ENUM, NodeType.STRING_TO_ENUM,
	NodeType.INT_TO_FLOAT, NodeType.FLOAT_TO_INT,
	# Get* nodes
	NodeType.GET_BOOL, NodeType.GET_INT, NodeType.GET_FLOAT,
	NodeType.GET_STRING, NodeType.GET_ENUM,
	NodeType.GET_IMAGE, NodeType.GET_AUDIO, NodeType.GET_CHARACTER,
	NodeType.GET_CHARACTER_VAR,
	# Array read-only operations
	NodeType.GET_BOOL_ARRAY, NodeType.GET_INT_ARRAY, NodeType.GET_FLOAT_ARRAY,
	NodeType.GET_STRING_ARRAY, NodeType.GET_IMAGE_ARRAY,
	NodeType.GET_CHARACTER_ARRAY, NodeType.GET_AUDIO_ARRAY,
	NodeType.GET_BOOL_ARRAY_ELEMENT, NodeType.GET_INT_ARRAY_ELEMENT,
	NodeType.GET_FLOAT_ARRAY_ELEMENT, NodeType.GET_STRING_ARRAY_ELEMENT,
	NodeType.GET_IMAGE_ARRAY_ELEMENT, NodeType.GET_CHARACTER_ARRAY_ELEMENT,
	NodeType.GET_AUDIO_ARRAY_ELEMENT,
	NodeType.GET_RANDOM_BOOL_ARRAY_ELEMENT, NodeType.GET_RANDOM_INT_ARRAY_ELEMENT,
	NodeType.GET_RANDOM_FLOAT_ARRAY_ELEMENT, NodeType.GET_RANDOM_STRING_ARRAY_ELEMENT,
	NodeType.GET_RANDOM_IMAGE_ARRAY_ELEMENT, NodeType.GET_RANDOM_CHARACTER_ARRAY_ELEMENT,
	NodeType.GET_RANDOM_AUDIO_ARRAY_ELEMENT,
	NodeType.ARRAY_LENGTH_BOOL, NodeType.ARRAY_LENGTH_INT, NodeType.ARRAY_LENGTH_FLOAT,
	NodeType.ARRAY_LENGTH_STRING, NodeType.ARRAY_LENGTH_IMAGE,
	NodeType.ARRAY_LENGTH_CHARACTER, NodeType.ARRAY_LENGTH_AUDIO,
	NodeType.ARRAY_CONTAINS_BOOL, NodeType.ARRAY_CONTAINS_INT,
	NodeType.ARRAY_CONTAINS_FLOAT, NodeType.ARRAY_CONTAINS_STRING,
	NodeType.ARRAY_CONTAINS_IMAGE, NodeType.ARRAY_CONTAINS_CHARACTER,
	NodeType.ARRAY_CONTAINS_AUDIO,
	NodeType.FIND_IN_BOOL_ARRAY, NodeType.FIND_IN_INT_ARRAY,
	NodeType.FIND_IN_FLOAT_ARRAY, NodeType.FIND_IN_STRING_ARRAY,
	NodeType.FIND_IN_IMAGE_ARRAY, NodeType.FIND_IN_CHARACTER_ARRAY,
	NodeType.FIND_IN_AUDIO_ARRAY,
]


static func is_logic_node(node_type: NodeType) -> bool:
	return node_type in _logic_node_types


# =============================================================================
# ForEach Loop Detection
# =============================================================================

static var _for_each_loop_types: Array[NodeType] = [
	NodeType.FOR_EACH_BOOL_LOOP, NodeType.FOR_EACH_INT_LOOP,
	NodeType.FOR_EACH_FLOAT_LOOP, NodeType.FOR_EACH_STRING_LOOP,
	NodeType.FOR_EACH_IMAGE_LOOP, NodeType.FOR_EACH_CHARACTER_LOOP,
	NodeType.FOR_EACH_AUDIO_LOOP,
]


static func is_for_each_loop(node_type: NodeType) -> bool:
	return node_type in _for_each_loop_types
