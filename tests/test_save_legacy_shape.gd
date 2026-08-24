extends SceneTree
## CHARACTERIZATION of the PRE-v1 ("legacy") save shape — the document StoryFlowSaveData wrote
## from the plugin's first release through v1.2.4, and the only shape a player's existing save
## file can be in.
##
## It was written BEFORE the unified-v1 writer landed and run green against the writer that
## produced this shape, then its output was frozen as tests/fixtures/legacy-save-v1.json. That
## file is now the subject of every assertion below, because the writer that produced it no
## longer exists: pinning a legacy reader against a live writer only proves the two agree, which
## they trivially do once both change together.
##
## So this file has ONE job now — keep the frozen fixture honest. tests/test_save_unified.gd
## loads the same file through the dual-dialect reader and asserts the VALUES come back; here we
## assert the SHAPE those values are in, so a well-meaning edit that "modernizes" the fixture
## (camelCase keys, type names instead of codes) cannot quietly turn the back-compat test into a
## second unified-format test.
##
## THE LEGACY SHAPE, in full:
##   { "save_version": 1 (INT),
##     "global_variables": { varId: { name, type (INT CODE), is_array, [key_type, value_type],
##                                    value: { type, value, [array] } } },
##     "runtime_characters": { path: { "variables": { varName: { type, [k/v], value } } } },
##     "used_once_only_options": [ key, ... ] }
## No "version", no camelCase, no type NAMES, no per-record id, no character name/image, and no
## "dataAssets" key — the five differences that make the sniff in StoryFlowSaveData.load_from_slot
## a structural key test rather than a version-number test.
##
## HOW THE FIXTURE WAS FROZEN (and how to redo it if the legacy corpus ever needs extending):
## restore the pre-unification storyflow_save_data.gd, point _run_tests at a live
## manager.save_to_slot instead of the fixture, run this file, and copy the slot JSON out of
## OS.get_user_data_dir()/storyflow_saves/. Nothing in the shipped plugin can produce it any more.
##
## Run from the repository root (import first to build the class cache):
##   godot --headless --import
##   godot --headless --script res://tests/test_save_legacy_shape.gd
## Or: powershell -File tests/run_tests.ps1 -GodotExe <path-to-godot>

const TypesScript := preload("res://addons/storyflow/core/storyflow_types.gd")

const FIXTURE_PATH := "res://tests/fixtures/legacy-save-v1.json"

var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	await process_frame

	var parsed = _load_fixture()
	if parsed is Dictionary:
		_test_root_shape(parsed)
		_test_global_variable_records(parsed)
		_test_character_records(parsed)
		_test_once_only(parsed)
	else:
		_check("the frozen legacy fixture parses as a JSON object", false)

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


# =============================================================================
# Root
# =============================================================================

func _test_root_shape(doc: Dictionary) -> void:
	print("-- legacy root shape --")

	# An INT, not the string "1" the unified format writes. This is exactly why the dialect
	# sniff does not read the version field: both documents carry one, and the only difference
	# is a JSON type, which is far too subtle a thing to route a whole reader on.
	var version = doc.get("save_version")
	_check("save_version is present", doc.has("save_version"))
	_check("save_version is the INTEGER 1, not a string", not (version is String) and int(version) == 1)

	_check("the root carries global_variables (snake_case)", doc.has("global_variables"))
	_check("the root carries runtime_characters (snake_case)", doc.has("runtime_characters"))
	_check("the root carries used_once_only_options (snake_case)", doc.has("used_once_only_options"))

	# THE SNIFF: the legacy arm is chosen because global_variables is present, and it must stay
	# the discriminator, so the camelCase twin must stay absent.
	_check("the root carries NO globalVariables key (the unified discriminator)", not doc.has("globalVariables"))
	_check("the root carries NO version key", not doc.has("version"))
	_check("the root carries NO dataAssets key", not doc.has("dataAssets"))
	_check("the root has exactly the four legacy sections (got %d)" % doc.size(), doc.size() == 4)


# =============================================================================
# Global variables
# =============================================================================

func _test_global_variable_records(doc: Dictionary) -> void:
	print("-- legacy global variable records --")
	var T := TypesScript.VariableType
	var globals = doc.get("global_variables")
	if not globals is Dictionary:
		_check("global_variables is an object", false)
		return

	_check("global_variables keys by variable ID", globals.has("g_int") and globals.has("g_map"))

	var gold = globals.get("g_int", {})
	_check("a record carries its display name", gold.get("name", "") == "gold")
	_check("a record's type is the INTEGER ENUM CODE, not a name (got %s)" % gold.get("type"),
		not (gold.get("type") is String) and int(gold.get("type", -1)) == T.INTEGER)
	_check("a record carries is_array in snake_case", gold.has("is_array"))
	_check("a record carries NO isArray in camelCase", not gold.has("isArray"))
	_check("a record carries NO id member", not gold.has("id"))

	# The nested variant ENVELOPE: value is an object restating the type, never the bare JSON
	# value the unified format writes.
	var gold_value = gold.get("value")
	_check("a scalar value is a nested {type, value} envelope", gold_value is Dictionary and gold_value.has("type"))
	_check("the envelope restates the type code", gold_value is Dictionary and int(gold_value.get("type", -1)) == T.INTEGER)
	_check("the envelope carries the runtime value (42)", gold_value is Dictionary and int(gold_value.get("value", 0)) == 42)

	# Arrays live under a SEPARATE "array" member beside the scalar value, and only when the
	# array is non-empty — the emptied-array hole the unified format closes with isArray.
	var inventory = globals.get("g_arr", {})
	var inventory_value = inventory.get("value")
	_check("an array record flags is_array", bool(inventory.get("is_array", false)))
	_check("an array value carries a separate array member", inventory_value is Dictionary and inventory_value.has("array"))
	var elements = inventory_value.get("array", []) if inventory_value is Dictionary else []
	_check("array elements are themselves envelopes", elements.size() == 2 and elements[0] is Dictionary and elements[0].has("type"))
	_check("array elements carry the runtime values", elements.size() == 2 and str(elements[0].get("value", "")) == "rope")

	# An EMPTY array writes no array member at all, which is the shipped data loss this
	# characterization exists to record: type survives, array-ness does not.
	var emptied = globals.get("g_empty", {})
	var emptied_value = emptied.get("value")
	_check("an EMPTIED array record still flags is_array", bool(emptied.get("is_array", false)))
	_check("but its value carries no array member at all (the legacy hole)",
		emptied_value is Dictionary and not emptied_value.has("array"))

	# Maps: K/V codes on the RECORD, ordered entry list inside the envelope.
	var scores = globals.get("g_map", {})
	_check("a map record carries key_type/value_type in snake_case",
		scores.has("key_type") and scores.has("value_type"))
	_check("map K/V are integer codes too",
		int(scores.get("key_type", -1)) == T.STRING and int(scores.get("value_type", -1)) == T.INTEGER)
	var scores_value = scores.get("value")
	_check("a map envelope restates the MAP type", scores_value is Dictionary and int(scores_value.get("type", -1)) == T.MAP)
	var entries = scores_value.get("value", []) if scores_value is Dictionary else []
	_check("a map value is an ORDERED entry list", entries is Array and entries.size() == 2)
	_check("entries are {key, value-envelope} pairs in authored order",
		entries.size() == 2 and entries[0].get("key", "") == "alice"
		and entries[0].get("value", {}) is Dictionary and int(entries[0]["value"].get("value", 0)) == 10)
	_check("and the second entry keeps its authored position",
		entries.size() == 2 and entries[1].get("key", "") == "bob")

	# Enum values were NEVER persisted by the legacy writer, so a legacy load loses the value
	# list an int->enum conversion node needs. Recorded, not fixed: the unified writer carries
	# enumValues, and a legacy file simply has nothing to give back.
	_check("no record carries enumValues", not globals.get("g_enum", {}).has("enumValues"))


# =============================================================================
# Characters
# =============================================================================

func _test_character_records(doc: Dictionary) -> void:
	print("-- legacy character records --")
	var characters = doc.get("runtime_characters")
	if not characters is Dictionary:
		_check("runtime_characters is an object", false)
		return

	_check("characters key by NORMALIZED path (lowercase, backslashes)",
		characters.has("characters\\hero.json"))
	var hero = characters.get("characters\\hero.json", {})
	_check("a character record carries a variables table", hero.has("variables"))

	# THE SHIPPED DATA LOSS the unified writer fixes: setCharacterVar("Name"/"Image") mutates
	# both fields at story time and neither one was ever persisted, so every save silently
	# reverted them to the imported defaults.
	_check("a character record carries NO name (the shipped gap)", not hero.has("name"))
	_check("a character record carries NO image (the shipped gap)", not hero.has("image"))
	_check("a character record has ONLY variables (got %d members)" % hero.size(), hero.size() == 1)

	var vars = hero.get("variables", {})
	_check("character variables key by NAME, not by id", vars is Dictionary and vars.has("affection"))
	var affection = vars.get("affection", {})
	_check("a character variable record carries no name member either", not affection.has("name"))
	_check("its value is a nested envelope carrying the runtime value (7)",
		affection.get("value", {}) is Dictionary and int(affection["value"].get("value", 0)) == 7)


# =============================================================================
# Once-only options
# =============================================================================

func _test_once_only(doc: Dictionary) -> void:
	print("-- legacy once-only options --")
	var used = doc.get("used_once_only_options")
	_check("used_once_only_options is a flat key ARRAY", used is Array)
	_check("it carries both recorded keys", used is Array and used.size() == 2)
	_check("keys are the raw node-option strings",
		used is Array and used.has("D1-o1") and used.has("D2-o2"))


# =============================================================================
# Fixture
# =============================================================================

func _load_fixture():
	var file := FileAccess.open(FIXTURE_PATH, FileAccess.READ)
	if file == null:
		printerr("  SETUP FAILURE: cannot read %s" % FIXTURE_PATH)
		return null
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed
