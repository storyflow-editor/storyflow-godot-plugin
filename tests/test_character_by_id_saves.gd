extends SceneTree
## Headless tests for P4 Task GP3: the ById character surface on the COMPONENT (characters
## engine contract §4 + A3/A4/A5 — the component-only mirror weight, the A3(a) pure-lookup
## split, the vocabulary ruling, the localization scopes) and the SAVE PINS through the real
## save_to_slot / load_from_slot (§3 save ownership, §5 double-capture, the merge doctrine,
## round-trip stability, and the A3(b) first-class never-creates pins on every lane).
##
## FIXTURES: the DECOY PAIR from tests/character_test_fixtures.gd - same variable names,
## different values - so a wrong-record resolution answers a wrong VALUE. Loops are
## COUNT-GUARDED.
##
## Run from the repository root (import first to build the class cache):
##   godot --headless --import
##   godot --headless --script res://tests/test_character_by_id_saves.gd
## Or: powershell -File tests/run_tests.ps1 -GodotExe <path-to-godot>

const CharacterScript := preload("res://addons/storyflow/core/storyflow_character.gd")
const ComponentScript := preload("res://addons/storyflow/core/storyflow_component.gd")
const FX := preload("res://tests/character_test_fixtures.gd")
const Graph := preload("res://tests/data_asset_test_graph.gd")
const ImporterScript := preload("res://addons/storyflow/editor/storyflow_importer.gd")
const ManagerScript := preload("res://addons/storyflow/core/storyflow_manager.gd")
const Types := preload("res://addons/storyflow/core/storyflow_types.gd")
const VariantScript := preload("res://addons/storyflow/core/storyflow_variant.gd")

## The real data asset shipped beside the characters in the save tests, so the dataAssets
## key's characterlessness is asserted beside a GENUINE overlay write, never vacuously.
const RULES_ID := "da_0123456789abcdef0123456789abcdef"
const V_HP := "0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f"

const SAVE_DIR := "user://storyflow_saves/"
const SLOTS := ["gp3_a5", "gp3_shape", "gp3_merge", "gp3_rt1", "gp3_rt2"]

var _checks: int = 0
var _failures: int = 0
var _temp_root: String = ""
var _manager: Node = null


func _initialize() -> void:
	await process_frame
	_temp_root = OS.get_user_data_dir().path_join("sf_character_by_id_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(_temp_root)
	_manager = ManagerScript.new()
	_manager.name = "StoryFlowRuntime"
	get_root().add_child(_manager)

	_test_by_id_getters_one_record_and_vocabulary()
	_test_pure_path_lookup_vs_record_getter()
	_test_enumeration()
	_test_variable_by_id_and_localization_scopes()
	_test_set_by_id_tiers_and_refusals()
	_test_save_shape_id_bound()
	_test_old_shape_merge_and_bridge_complement()
	_test_save_load_save_stable()
	_test_a3b_first_class_pins()

	_rm_rf(_temp_root)
	for slot in SLOTS:
		_manager.delete_save(slot)

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
		printerr("  FAIL: %s" % label)


# =============================================================================
# 1. get_character_by_id: one record, decoys, the vocabulary ruling, no mirror
# =============================================================================

func _test_by_id_getters_one_record_and_vocabulary() -> void:
	print("-- get_character_by_id + vocabulary --")
	_import_build("getters", FX.index_text_valid())
	var component := _make_component()

	var alice = _manager.get_runtime_characters()[FX.ALICE_KEY]
	var bob = _manager.get_runtime_characters()[FX.BOB_KEY]
	_check("the id answers alice's LIVE record (one state)",
		component.get_character_by_id(FX.ALICE_ID) == alice)
	_check("the decoy id answers bob's", component.get_character_by_id(FX.BOB_ID) == bob)
	# The verbatim non-id rung: a record key from get_character_paths is valid input, so the
	# ById door and the path door reach the SAME object (the sibling ports' delegate parity).
	_check("a record key passes the verbatim rung to the same object",
		component.get_character_by_id(FX.ALICE_KEY) == alice)
	_check("no warnings on clean lookups (got %d)" % _manager.character_id_access_warnings_emitted,
		_manager.character_id_access_warnings_emitted == 0)

	# THE VOCABULARY RULING: the dangling rung on this NEW character surface warns in the
	# CHARACTER vocabulary on the manager pair - never the DA ladder's noasset wording,
	# which is the DA-surface branch's deliberate pre-P4 fall-through.
	_check("a dangling id answers null", component.get_character_by_id(FX.DANGLING_ID) == null)
	_check("warned once, in the character vocabulary (id|dangling)",
		_manager.warned_character_id_access.has("%s|dangling" % FX.DANGLING_ID)
			and _manager.character_id_access_warnings_emitted == 1)
	component.get_character_by_id(FX.DANGLING_ID)
	_check("once means once (got %d)" % _manager.character_id_access_warnings_emitted,
		_manager.character_id_access_warnings_emitted == 1)
	_check("and the DA access latch never heard of it",
		not _manager.warned_data_asset_access.has("%s||noasset" % FX.DANGLING_ID))

	# The mirror weight, pinned: the ById surface is COMPONENT-ONLY. Godot's manager has no
	# per-variable surface of any kind, so there is nothing for characters to mirror onto.
	_check("the manager grows NO ById mirror",
		not _manager.has_method("get_character_by_id")
			and not _manager.has_method("get_character_variable_by_id")
			and not _manager.has_method("set_character_variable_by_id"))
	_free_component(component)


# =============================================================================
# 2. The A3(a) split, side by side on one state (ghost import)
# =============================================================================

## The ghost index entry (bridge hit, record never loaded): the RECORD getter reports
## not-found with the unloaded warn-once, while the PURE path lookup still answers - the
## bridge is import state, an existence query is not a degraded resolution, and no
## path-by-id call ever warns.
func _test_pure_path_lookup_vs_record_getter() -> void:
	print("-- A3(a): pure path lookup vs record getter --")
	_import_build("pure", FX.index_text_with_ghost())
	var component := _make_component()

	_check("path-by-id answers an indexed loaded id verbatim (got '%s')" % component.get_character_path_by_id(FX.ALICE_ID),
		component.get_character_path_by_id(FX.ALICE_ID) == FX.ALICE_KEY)
	_check("path-by-id answers an indexed UNLOADED id too (got '%s')" % component.get_character_path_by_id(FX.GHOST_ID),
		component.get_character_path_by_id(FX.GHOST_ID) == FX.GHOST_KEY)
	_check("path-by-id answers '' for an unindexed id",
		component.get_character_path_by_id(FX.DANGLING_ID) == "")
	_check("and NO pure lookup warned (got %d)" % _manager.character_id_access_warnings_emitted,
		_manager.character_id_access_warnings_emitted == 0)

	_check("the record getter reports the same ghost id NOT-FOUND",
		component.get_character_by_id(FX.GHOST_ID) == null)
	_check("with the unloaded warn-once (id|unloaded)",
		_manager.warned_character_id_access.has("%s|unloaded" % FX.GHOST_ID)
			and _manager.character_id_access_warnings_emitted == 1)
	_check("while path-by-id keeps answering, still without warning",
		component.get_character_path_by_id(FX.GHOST_ID) == FX.GHOST_KEY
			and _manager.character_id_access_warnings_emitted == 1)
	_free_component(component)


# =============================================================================
# 3. A4 enumeration
# =============================================================================

func _test_enumeration() -> void:
	print("-- A4 enumeration --")
	_import_build("enum", FX.index_text_valid())
	var component := _make_component()

	var paths := component.get_character_paths()
	_check("enumeration answers the loaded record keys in insertion order (got %s)" % str(paths),
		paths == [FX.ALICE_KEY, FX.BOB_KEY])
	# The engine-true coincidence the doc states: under this engine's merge-load semantics
	# the loaded set always equals the project's character set.
	_check("and equals the project's character set",
		paths == _manager.get_project().characters.keys())
	_check("record keys are valid path-API input",
		component.get_character(paths[0]) != null)
	_free_component(component)


# =============================================================================
# 4. get_character_variable_by_id + the A5 localization scopes
# =============================================================================

## THE A5 DIVERGENCE, observable for real: the build ships a strings-table entry for
## alice's name key, so the RESOLVING door (this getter, via its path-API delegate and
## _resolve_string) answers display text while the STORED doors - the DA-surface branch and
## the raw record field - answer the key, and the SAVE writes the stored key regardless.
func _test_variable_by_id_and_localization_scopes() -> void:
	print("-- variable-by-id + A5 scopes --")
	_import_build("a5", FX.index_text_valid(), true)
	var component := _make_component()

	_check("the id-bound read answers alice (Trust 3, got %d)" % component.get_character_variable_by_id(FX.ALICE_ID, "Trust").get_int(-1),
		component.get_character_variable_by_id(FX.ALICE_ID, "Trust").get_int(-1) == 3)
	_check("the decoy id answers bob (Trust 9)",
		component.get_character_variable_by_id(FX.BOB_ID, "Trust").get_int(-1) == 9)

	# First tier rides the delegate, case-insensitively - and RESOLVES (A5).
	_check("CF_NAME resolves to display text through the first tier (got '%s')" % component.get_character_variable_by_id(FX.ALICE_ID, "CF_NAME").get_string(),
		component.get_character_variable_by_id(FX.ALICE_ID, "CF_NAME").get_string() == "Alicia")
	_check("the DA-surface door answers the STORED key for the same builtin",
		component.get_data_asset_string(FX.ALICE_ID, "cf_name") == "char.alice.name")
	_check("and the raw record field holds the stored key",
		component.get_character_by_id(FX.ALICE_ID).character_name == "char.alice.name")

	# A5's save invariant: the save lane writes the STORED key, never the resolved string.
	_check("save writes a slot", _manager.save_to_slot("gp3_a5"))
	var doc := _read_slot("gp3_a5")
	_check("the save carries the STORED name key (got '%s')" % str(doc.get("characters", {}).get(FX.ALICE_KEY, {}).get("name")),
		doc.get("characters", {}).get(FX.ALICE_KEY, {}).get("name", "") == "char.alice.name")

	# The default answers ONLY the resolution misses; a resolved id with an undeclared
	# variable keeps the path delegate's own pre-P4 posture (an EMPTY variant), so the two
	# surfaces cannot drift.
	var missed = component.get_character_variable_by_id(FX.DANGLING_ID, "Trust", VariantScript.from_int(-7))
	_check("a dangling id answers the default (got %d)" % (missed.get_int(-99) if missed else -99),
		missed != null and missed.get_int(-99) == -7)
	_check("and null when no default is given",
		component.get_character_variable_by_id(FX.DANGLING_ID, "Trust") == null)
	var undeclared = component.get_character_variable_by_id(FX.ALICE_ID, "Nope", VariantScript.from_int(-7))
	_check("an undeclared variable on a RESOLVED id answers the delegate's empty variant, not the default",
		undeclared != null and undeclared.type == Types.VariableType.NONE)
	_free_component(component)


# =============================================================================
# 5. set_character_variable_by_id: tiers, refusals, signal silence
# =============================================================================

func _test_set_by_id_tiers_and_refusals() -> void:
	print("-- set-by-id tiers + refusals --")
	_import_build("setter", FX.index_text_valid())
	var component := _make_component()
	var emissions: Array = []
	component.character_variable_changed.connect(func(path, _vname, _value): emissions.append(path))
	var alice = _manager.get_runtime_characters()[FX.ALICE_KEY]
	var bob = _manager.get_runtime_characters()[FX.BOB_KEY]

	_check("an id-bound write lands and reports true",
		component.set_character_variable_by_id(FX.ALICE_ID, "Trust", VariantScript.from_int(77)))
	_check("visible to the path read (one state)",
		component.get_character_variable(FX.ALICE_KEY, "Trust").get_int(-1) == 77)
	_check("the decoy is untouched (bob Trust 9)", _var_of(bob, "Trust").get_int(-1) == 9)

	# SECOND tier, exact - the shared core with the void path lane.
	_check("cf_image diverts to the builtin",
		component.set_character_variable_by_id(FX.ALICE_ID, "cf_image", VariantScript.from_string("cellar"))
			and alice.image_key == "cellar")
	_check("leaving the custom 'Image' row alone",
		_var_of(alice, "Image").get_string() == "alice-custom-image-row")
	_check("the native 'Image' spelling writes the CUSTOM row",
		component.set_character_variable_by_id(FX.ALICE_ID, "Image", VariantScript.from_string("row-write"))
			and _var_of(alice, "Image").get_string() == "row-write" and alice.image_key == "cellar")
	_check("lowercase 'image' matches nothing - refused false, nothing written",
		not component.set_character_variable_by_id(FX.ALICE_ID, "image", VariantScript.from_string("nope"))
			and alice.image_key == "cellar" and _var_of(alice, "Image").get_string() == "row-write")
	_check("the second tier is EXACT - 'Cf_Name' refuses",
		not component.set_character_variable_by_id(FX.ALICE_ID, "Cf_Name", VariantScript.from_string("nope")))

	# A3(b) on this lane: refusal = false, never a create.
	var var_count: int = alice.variables.size()
	_check("an undeclared write reports false",
		not component.set_character_variable_by_id(FX.ALICE_ID, "Ghost", VariantScript.from_int(1)))
	_check("and created nothing (got %d vars)" % alice.variables.size(),
		alice.variables.size() == var_count and not alice.variables.has("Ghost"))

	# Resolution misses report false too, warned once on the manager pair.
	_check("a dangling id reports false",
		not component.set_character_variable_by_id(FX.DANGLING_ID, "Trust", VariantScript.from_int(5)))
	_check("warned once in the character vocabulary",
		_manager.warned_character_id_access.has("%s|dangling" % FX.DANGLING_ID))

	# A2(b): the ById writes emitted NOTHING - the signal is node-lane only.
	_check("no signal fired for any ById write (got %d)" % emissions.size(), emissions.is_empty())
	_free_component(component)


# =============================================================================
# 6. Save pin (a): id-bound writes land in TODAY'S exact characters shape
# =============================================================================

## §3 save ownership through the real slot helpers: the characters section keeps its exact
## key and shape - path-keyed records, name-keyed variables, the fallback_id-as-name records
## (character rows carry no var_ ids; the table key IS the id field) - and the dataAssets
## key stays CHARACTERLESS beside a genuine overlay write (§5 double-capture, non-vacuous).
func _test_save_shape_id_bound() -> void:
	print("-- save shape: id-bound writes --")
	_import_build("shape", FX.index_text_valid(), false, true)
	var component := _make_component()

	_check("the id-bound write lands",
		component.set_character_variable_by_id(FX.ALICE_ID, "Trust", VariantScript.from_int(21)))
	_check("the genuine .sfd overlay write lands beside it",
		component.set_data_asset_int(RULES_ID, "hp", 99))
	_check("save writes a slot", _manager.save_to_slot("gp3_shape"))
	var doc := _read_slot("gp3_shape")

	var characters: Dictionary = doc.get("characters", {})
	_check("the characters section keys by record PATH, never by da_ id",
		characters.has(FX.ALICE_KEY) and not characters.has(FX.ALICE_ID))
	var alice_record: Dictionary = characters.get(FX.ALICE_KEY, {})
	_check("the record persists name and image",
		alice_record.get("name", "") == "char.alice.name" and alice_record.get("image", "") == "alice_portrait")
	var trust: Dictionary = alice_record.get("variables", {}).get("Trust", {})
	_check("variables key by NAME", not trust.is_empty())
	_check("with the id-bound write's value (got %s)" % str(trust.get("value")),
		int(trust.get("value", -1)) == 21)
	_check("the fallback_id-as-name record: id IS the name (got '%s')" % str(trust.get("id")),
		trust.get("id", "") == "Trust" and trust.get("name", "") == "Trust")
	_check("typed with the NAME vocabulary", trust.get("type", "") == "Integer")

	var data_assets: Dictionary = doc.get("dataAssets", {})
	_check("the .sfd write rode the dataAssets key",
		int(data_assets.get(RULES_ID, {}).get(V_HP, -1)) == 99)
	_check("and the dataAssets key stays CHARACTERLESS (double-capture pin)",
		not data_assets.has(FX.ALICE_ID) and not data_assets.has(FX.BOB_ID)
			and not data_assets.has(FX.ALICE_KEY))

	# Load-back sanity: disturb the live value, load, and the id lane reads the save.
	component.set_character_variable_by_id(FX.ALICE_ID, "Trust", VariantScript.from_int(5))
	_check("load reports success", _manager.load_from_slot("gp3_shape"))
	_check("the id lane reads the loaded value back (got %d)" % component.get_character_variable_by_id(FX.ALICE_ID, "Trust").get_int(-1),
		component.get_character_variable_by_id(FX.ALICE_ID, "Trust").get_int(-1) == 21)
	_free_component(component)


# =============================================================================
# 7. Save pins (b) + (c): the merge doctrine and its bridge complement
# =============================================================================

## (b) An old-shape save (a V2-era document with no ById lanes anywhere near it) merges
## PER-VARIABLE onto the declared records: carried values land, absent fields keep CURRENT
## values, unknown paths and variables are dropped - never an add, never a remove (the
## manager's four-sections doctrine). (c) The complement this engine's unloaded rung rests
## on: a load leaves the BRIDGE untouched - import state, not player state (GP1 pinned
## reset_all_state; this pins the load path) - so both ids still resolve to LOADED records
## afterwards: a save load cannot manufacture the unloaded state here.
func _test_old_shape_merge_and_bridge_complement() -> void:
	print("-- old-shape merge + bridge complement --")
	_import_build("merge", FX.index_text_valid())
	var component := _make_component()
	var alice = _manager.get_runtime_characters()[FX.ALICE_KEY]
	var bob = _manager.get_runtime_characters()[FX.BOB_KEY]
	var bridge_ref: Dictionary = _manager.get_character_id_bridge()

	# CURRENT state the merge must preserve where the document is silent - each mutated
	# away from its authored value so "keeps current" cannot pass by accident.
	component.set_character_variable_by_id(FX.ALICE_ID, "Title", VariantScript.from_string("Admiral"))
	component.set_character_variable_by_id(FX.ALICE_ID, "cf_name", VariantScript.from_string("mutated.key"))
	component.set_character_variable_by_id(FX.ALICE_ID, "cf_image", VariantScript.from_string("mutated_img"))

	# The old-shape document: alice carries ONLY Trust (no name/image fields) plus a
	# variable this project never declared; a record it never declared rides beside her.
	_write_slot("gp3_merge", {
		"version": "1",
		"globalVariables": {},
		"characters": {
			FX.ALICE_KEY: {"variables": {
				"Trust": {"id": "whatever", "name": "Trust", "type": "Integer", "isArray": false, "value": 55},
				"Ghost": {"id": "Ghost", "name": "Ghost", "type": "Integer", "isArray": false, "value": 5},
			}},
			"cast\\carol.sfc": {"name": "Carol", "variables": {}},
		},
		"usedOnceOnlyOptions": [],
		"dataAssets": {},
	})
	_check("the old-shape save loads", _manager.load_from_slot("gp3_merge"))

	_check("the carried variable applied (Trust 55, got %d)" % _var_of(alice, "Trust").get_int(-1),
		_var_of(alice, "Trust").get_int(-1) == 55)
	_check("an absent variable keeps its CURRENT value (Title Admiral)",
		_var_of(alice, "Title").get_string() == "Admiral")
	_check("an absent name field keeps the current name",
		alice.character_name == "mutated.key")
	_check("and the current image", alice.image_key == "mutated_img")
	_check("an unknown variable is dropped, never created", not alice.variables.has("Ghost"))
	_check("an unknown record is dropped, never added (got %d)" % _manager.get_runtime_characters().size(),
		_manager.get_runtime_characters().size() == 2)
	_check("a character absent from the save keeps ALL authored values",
		_var_of(bob, "Trust").get_int(-1) == 9 and bob.character_name == "char.bob.name")

	# (c) The bridge: same OBJECT (is_same, not == - the in-place doctrine), same entries.
	_check("the load left the bridge OBJECT untouched", is_same(_manager.get_character_id_bridge(), bridge_ref))
	_check("with both entries intact (got %d)" % bridge_ref.size(), bridge_ref.size() == 2)
	_check("alice's id still resolves to a loaded record",
		component.get_character_by_id(FX.ALICE_ID) == alice)
	_check("and bob's does too", component.get_character_by_id(FX.BOB_ID) == bob)
	_check("with no unloaded warn manufactured (got %d)" % _manager.character_id_access_warnings_emitted,
		_manager.character_id_access_warnings_emitted == 0)
	_check("and enumeration still answers the project set",
		component.get_character_paths() == [FX.ALICE_KEY, FX.BOB_KEY])
	_free_component(component)


# =============================================================================
# 8. Save pin (d): save -> load -> save is stable, id-lane writes included
# =============================================================================

func _test_save_load_save_stable() -> void:
	print("-- save -> load -> save stability --")
	_import_build("roundtrip", FX.index_text_valid(), false, true)
	var component := _make_component()

	component.set_character_variable_by_id(FX.ALICE_ID, "Trust", VariantScript.from_int(21))
	component.set_character_variable_by_id(FX.ALICE_ID, "cf_name", VariantScript.from_string("renamed.key"))
	component.set_data_asset_int(RULES_ID, "hp", 42)

	_check("first save writes", _manager.save_to_slot("gp3_rt1"))
	_check("the load succeeds", _manager.load_from_slot("gp3_rt1"))
	_check("second save writes", _manager.save_to_slot("gp3_rt2"))
	_check("save -> load -> save is byte-identical",
		_read_slot_text("gp3_rt1") == _read_slot_text("gp3_rt2"))
	_free_component(component)


# =============================================================================
# 9. Save pin (e): the A3(b) never-creates pins, FIRST-CLASS per lane
# =============================================================================

## The public VOID lane's silent no-op and the NODE lane's no-op, each named for itself
## rather than riding inside the alias matrix - because the pre-P4 back-compat sweep rests
## on neither ever becoming an add. (The ById setter's false-return refusal is pinned in
## the setter section above.)
func _test_a3b_first_class_pins() -> void:
	print("-- A3(b) first-class pins --")
	_import_build("a3b", FX.index_text_valid())
	var component := _make_component()
	var emissions: Array = []
	component.character_variable_changed.connect(func(path, _vname, _value): emissions.append(path))
	var alice = _manager.get_runtime_characters()[FX.ALICE_KEY]
	var bob = _manager.get_runtime_characters()[FX.BOB_KEY]
	var alice_count: int = alice.variables.size()
	var bob_count: int = bob.variables.size()

	# The PUBLIC VOID lane: an undeclared name is a silent no-op - no create, no signal.
	component.set_character_variable(FX.ALICE_KEY, "Ghost", VariantScript.from_int(1))
	_check("the public void lane's undeclared write created nothing (got %d vars)" % alice.variables.size(),
		alice.variables.size() == alice_count and not alice.variables.has("Ghost"))
	_check("and left the declared values untouched", _var_of(alice, "Trust").get_int(-1) == 3)
	component.set_character_variable("cast\\nobody.sfc", "Trust", VariantScript.from_int(1))
	_check("a missing character is the same silent no-op",
		_var_of(alice, "Trust").get_int(-1) == 3 and _var_of(bob, "Trust").get_int(-1) == 9)

	# The NODE lane: an undeclared name no-ops on the SCALAR arm and the MAP arm alike,
	# and the exec chain still continues to the next node. Id-bound with the decoy path,
	# so a resolution that ignored the id would try (and must also fail) on bob.
	var decoy := {"characterPath": FX.BOB_KEY, "characterId": FX.ALICE_ID}
	var scalar_data := decoy.duplicate()
	scalar_data.merge({"variableName": "Ghost", "variableType": "integer", "value": VariantScript.from_int(5)}, true)
	var map_data := decoy.duplicate()
	map_data.merge({"variableName": "Ledger", "variableType": "map", "keyType": "string", "valueType": "integer"}, true)
	var script := Graph.build("scripts/A3b.sfe", {
		"0": Graph.start(),
		"W1": Graph.node("W1", Types.NodeType.SET_CHARACTER_VAR, "setCharacterVar", scalar_data),
		"W2": Graph.node("W2", Types.NodeType.SET_CHARACTER_VAR, "setCharacterVar", map_data),
		"D": Graph.dialogue("D"),
	}, [
		Graph.exec("0", "W1"), Graph.exec_flow("W1", "W2"), Graph.exec_flow("W2", "D"),
	])
	_manager.get_project().scripts[script.script_path] = script
	var runner := _make_component()
	runner.start_dialogue_with_script(script.script_path)
	var state = runner._context.current_dialogue_state
	_check("the exec chain continued past both refused writes", state != null and state.text == "D")
	_check("the node lane's scalar arm created nothing", not alice.variables.has("Ghost"))
	_check("and the map arm created nothing", not alice.variables.has("Ledger"))
	_check("on the decoy either (got %d vars)" % bob.variables.size(),
		bob.variables.size() == bob_count)
	runner.stop_dialogue()
	_free_component(runner)

	# NO lane fired the signal for a refused write.
	_check("no signal fired for any refused write (got %d)" % emissions.size(), emissions.is_empty())
	_free_component(component)


# =============================================================================
# Helpers
# =============================================================================

## Import a build carrying the decoy characters and [param index_text]; [param with_strings]
## adds the strings-table entry the A5 scope test needs, and [param with_data_assets] ships
## the one-asset data-assets.json the save tests write through.
func _import_build(label: String, index_text, with_strings := false, with_data_assets := false) -> void:
	var build := _temp("%s/build" % label)
	var out := _temp("%s/out" % label)
	FX.write_build(build, index_text)
	if with_strings:
		var payload := FX.characters_payload()
		payload["strings"] = {"en": {"char.alice.name": "Alicia"}}
		FX.write_text(build.path_join("characters.json"), JSON.stringify(payload, "\t"))
	if with_data_assets:
		FX.write_text(build.path_join("data-assets.json"), JSON.stringify({
			"dataAssets": {
				RULES_ID: {
					"id": RULES_ID,
					"name": "Rules",
					"parent": null,
					"variables": [
						{"id": V_HP, "name": "hp", "type": "integer", "value": 77},
					],
				},
			},
		}, "\t"))
	var project = ImporterScript.new().import_project(build, out)
	_check("[setup] %s: import returned a project" % label, project != null)
	if project != null:
		_manager.set_project(project)


func _make_component() -> StoryFlowComponent:
	var component := ComponentScript.new()
	component.dialogue_ui_scene = null
	get_root().add_child(component)
	return component


func _free_component(component: StoryFlowComponent) -> void:
	get_root().remove_child(component)
	component.queue_free()


func _var_of(character, variable_name: String) -> StoryFlowVariant:
	var value = character.variables.get(variable_name, {}).get("value")
	return value if value is VariantScript else VariantScript.new()


func _read_slot_text(slot_name: String) -> String:
	var file := FileAccess.open(SAVE_DIR + slot_name + ".json", FileAccess.READ)
	if file == null:
		printerr("  SETUP FAILURE: cannot read slot %s" % slot_name)
		return ""
	var text := file.get_as_text()
	file.close()
	return text


func _read_slot(slot_name: String) -> Dictionary:
	var parsed = JSON.parse_string(_read_slot_text(slot_name))
	return parsed if parsed is Dictionary else {}


func _write_slot(slot_name: String, doc: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	var file := FileAccess.open(SAVE_DIR + slot_name + ".json", FileAccess.WRITE)
	file.store_string(JSON.stringify(doc, "\t"))
	file.close()


func _temp(relative: String) -> String:
	var path := _temp_root.path_join(relative)
	DirAccess.make_dir_recursive_absolute(path)
	return path


static func _rm_rf(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name != "." and name != "..":
			var child := path.path_join(name)
			if dir.current_is_dir():
				_rm_rf(child)
			else:
				DirAccess.remove_absolute(child)
		name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)
