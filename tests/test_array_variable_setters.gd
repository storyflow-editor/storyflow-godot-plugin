extends SceneTree
## Headless tests for the set_*_array_variable public API on
## StoryFlowComponent.
##
## The setters mirror the Unity and Unreal plugins' Set*ArrayVariable API:
## find the variable by display name, replace its elements with a typed
## variant array, and notify (which also live-refreshes any active dialogue).
##
## Run from the repository root (import first to build the class cache):
##   godot --headless --import
##   godot --headless --script res://tests/test_array_variable_setters.gd
## Or: powershell -File tests/run_tests.ps1 -GodotExe <path-to-godot>

const ManagerScript := preload("res://addons/storyflow/core/storyflow_manager.gd")

var _checks: int = 0
var _failures: int = 0

var _manager: Node = null
var _component: StoryFlowComponent = null


func _initialize() -> void:
	await process_frame

	_setup()
	_run_string_array_tests()
	_run_numeric_array_tests()
	_run_enum_array_tests()
	_run_asset_array_tests()
	_run_missing_variable_test()
	_run_typed_getter_tests()

	if _failures == 0:
		print("ALL %d CHECKS PASSED" % _checks)
	else:
		print("%d OF %d CHECKS FAILED" % [_failures, _checks])
	quit(1 if _failures > 0 else 0)


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  PASS: %s" % label)
	else:
		_failures += 1
		print("  FAIL: %s" % label)


func _setup() -> void:
	_manager = ManagerScript.new()
	_manager.name = "StoryFlowRuntime"
	root.add_child(_manager)

	_component = StoryFlowComponent.new()
	root.add_child(_component)

	_add_global_array("var_inv", "Inventory", StoryFlowTypes.VariableType.STRING)
	_add_global_array("var_b", "Flags", StoryFlowTypes.VariableType.BOOLEAN)
	_add_global_array("var_i", "Scores", StoryFlowTypes.VariableType.INTEGER)
	_add_global_array("var_f", "Weights", StoryFlowTypes.VariableType.FLOAT)
	_add_global_array("var_e", "Moods", StoryFlowTypes.VariableType.ENUM)
	_add_global_array("var_img", "Gallery", StoryFlowTypes.VariableType.IMAGE)


func _add_global_array(id: String, name: String, type: StoryFlowTypes.VariableType) -> void:
	_manager._global_variables[id] = {
		"id": id,
		"name": name,
		"type": type,
		"value": StoryFlowVariant.new(),
		"is_array": true,
		"enum_values": [],
	}


func _stored_array(id: String) -> Array:
	var value = _manager._global_variables[id].get("value")
	return value.get_array() if value is StoryFlowVariant else []


func _run_string_array_tests() -> void:
	_component.set_string_array_variable("Inventory", ["sword", "axe"])
	var arr := _stored_array("var_inv")
	_check("string: two elements stored", arr.size() == 2)
	if arr.size() == 2:
		_check("string: element 0", arr[0].get_string() == "sword")
		_check("string: element 1", arr[1].get_string() == "axe")

	# Public read path round trip
	var read := _component.get_array_variable("Inventory")
	_check("string: get_array_variable reads back 2", read.size() == 2)

	# Overwrite replaces, not appends
	_component.set_string_array_variable("Inventory", ["bow"])
	_check("string: overwrite leaves one element", _stored_array("var_inv").size() == 1)

	# Empty write clears
	_component.set_string_array_variable("Inventory", [])
	_check("string: empty write clears", _stored_array("var_inv").size() == 0)


func _run_numeric_array_tests() -> void:
	_component.set_bool_array_variable("Flags", [true, false, true])
	var flags := _stored_array("var_b")
	_check("bool: three elements", flags.size() == 3)
	if flags.size() == 3:
		_check("bool: element 1 is false", flags[1].get_bool(true) == false)

	_component.set_int_array_variable("Scores", [10, 20, 30])
	var scores := _stored_array("var_i")
	_check("int: three elements", scores.size() == 3)
	if scores.size() == 3:
		_check("int: element 2", scores[2].get_int() == 30)

	_component.set_float_array_variable("Weights", [0.5, 2.25])
	var weights := _stored_array("var_f")
	_check("float: two elements", weights.size() == 2)
	if weights.size() == 2:
		_check("float: element 1", is_equal_approx(weights[1].get_float(), 2.25))


func _run_enum_array_tests() -> void:
	_component.set_enum_array_variable("Moods", ["happy", "angry"])
	var moods := _stored_array("var_e")
	_check("enum: two elements", moods.size() == 2)
	if moods.size() == 2:
		_check("enum: element type is ENUM", moods[0].type == StoryFlowTypes.VariableType.ENUM)
		_check("enum: element value", moods[0].get_string() == "happy")


func _run_asset_array_tests() -> void:
	_component.set_image_array_variable("Gallery", ["asset_image_1", "asset_image_2"])
	var gallery := _stored_array("var_img")
	_check("image: two elements", gallery.size() == 2)
	if gallery.size() == 2:
		# Plain-string storage matches the importer's _parse_variant convention
		_check("image: element value", gallery[1].get_string() == "asset_image_2")


func _run_missing_variable_test() -> void:
	var count_before: int = _manager._global_variables.size()
	# Pushes a "Global variable 'Nope' not found" warning and writes nothing
	_component.set_string_array_variable("Nope", ["x"])
	_check("missing: no variable created", _manager._global_variables.size() == count_before)
	_check("missing: no 'Nope' entry", not _manager._global_variables.has("Nope"))


## The typed GETTERS, which mirror the typed setters above (design 2026-09-04). Every setter had
## a native-typed signature and every read came back as variants, so this half of the round trip
## was hand-unpacking. The gate is the part worth testing: a wrong-typed or non-array variable
## answers EMPTY rather than coercing.
func _run_typed_getter_tests() -> void:
	# A scalar, so the not-an-array arm has something to refuse.
	_manager._global_variables["var_scalar"] = {
		"id": "var_scalar",
		"name": "Health",
		"type": StoryFlowTypes.VariableType.INTEGER,
		"value": StoryFlowVariant.new(),
		"is_array": false,
		"enum_values": [],
	}

	# ROUND TRIP, once per type: write native, read native.
	_component.set_bool_array_variable("Flags", [true, false, true])
	var flags := _component.get_bool_array_variable("Flags")
	_check("typed get: bool round trip size", flags.size() == 3)
	if flags.size() == 3:
		_check("typed get: bool values survive", flags[0] == true and flags[1] == false)

	_component.set_int_array_variable("Scores", [10, 20, 30])
	var scores := _component.get_int_array_variable("Scores")
	_check("typed get: int round trip", scores.size() == 3 and scores[2] == 30)

	_component.set_float_array_variable("Weights", [0.5, 2.25])
	var weights := _component.get_float_array_variable("Weights")
	_check("typed get: float round trip", weights.size() == 2 and is_equal_approx(weights[1], 2.25))

	_component.set_string_array_variable("Inventory", ["sword", "axe"])
	var inv := _component.get_string_array_variable("Inventory")
	_check("typed get: string round trip", inv.size() == 2 and inv[1] == "axe")

	_component.set_enum_array_variable("Moods", ["happy", "sad"])
	var moods := _component.get_enum_array_variable("Moods")
	_check("typed get: enum round trip", moods.size() == 2 and moods[0] == "happy")

	_component.set_image_array_variable("Gallery", ["asset_image_1", "asset_image_2"])
	var gallery := _component.get_image_array_variable("Gallery")
	_check("typed get: image round trip", gallery.size() == 2 and gallery[1] == "asset_image_2")

	# THE GATE. Each of these pushes its own warning and answers empty.
	_check("typed get: a bool array is not a string array", _component.get_string_array_variable("Flags").is_empty())
	_check("typed get: a string array is not an int array", _component.get_int_array_variable("Inventory").is_empty())
	_check("typed get: an image array is not an enum array", _component.get_enum_array_variable("Gallery").is_empty())
	_check("typed get: a scalar is not an array", _component.get_int_array_variable("Health").is_empty())
	_check("typed get: a missing variable is empty", _component.get_bool_array_variable("Nope").is_empty())

	# The gate refuses; it must never mutate what it refused.
	_check("typed get: the refused bool array is intact", _stored_array("var_b").size() == 3)
