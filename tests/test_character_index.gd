extends SceneTree
## Headless tests for the P4 character-id index import (characters engine contract §3):
## the character-index.json read in BOTH import arms, the five-rung degraded ladder, the
## verbatim id -> record-key bridge on the manager, the node-field carry-through
## (characterRefId / characterId), and the two warn-latch pairs the id-resolution lanes of
## the next task will ride.
##
## FIXTURES: the DECOY PAIR from tests/character_test_fixtures.gd - two characters with the
## same variable names and different values, record keys in the wire's lowercase-backslash
## form - shared with the id-resolution tests the same way data_asset_test_graph.gd is.
## Every fixture-driven loop is COUNT-GUARDED: a fixture that silently shrinks would
## otherwise turn into a test that silently passes.
##
## Run from the repository root (import first to build the class cache):
##   godot --headless --import
##   godot --headless --script res://tests/test_character_index.gd
## Or: powershell -File tests/run_tests.ps1 -GodotExe <path-to-godot>

const CharacterScript := preload("res://addons/storyflow/core/storyflow_character.gd")
const ContextScript := preload("res://addons/storyflow/core/storyflow_execution_context.gd")
const FX := preload("res://tests/character_test_fixtures.gd")
const ImporterScript := preload("res://addons/storyflow/editor/storyflow_importer.gd")
const ManagerScript := preload("res://addons/storyflow/core/storyflow_manager.gd")

var _checks: int = 0
var _failures: int = 0
var _temp_root: String = ""
var _manager: Node = null


func _initialize() -> void:
	await process_frame
	_temp_root = OS.get_user_data_dir().path_join("sf_character_index_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(_temp_root)
	_manager = ManagerScript.new()
	_manager.name = "StoryFlowRuntimeCharacterIndexTest"
	get_root().add_child(_manager)

	_test_verbatim_bridge_and_decoys()
	_test_ladder_rungs()
	_test_inline_arm_parity()
	_test_phantom_script_regression()
	_test_node_field_carry()
	_test_context_latch_mechanics()
	_test_manager_latch_mechanics()

	_rm_rf(_temp_root)

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
# Verbatim mapping + decoy pair, through the manager's bridge
# =============================================================================

## A real disk import, installed on the manager: every bridge value must hit the
## _runtime_characters keys DIRECTLY (verbatim, no normalization anywhere), and the decoy
## pair must answer its own values - a wrong-record resolution shows as a wrong Trust.
func _test_verbatim_bridge_and_decoys() -> void:
	print("-- verbatim bridge + decoys --")
	var project = _import_decoy_build("verbatim", FX.index_text_valid())
	_check("import with a valid index returns a project", project != null)
	if project == null:
		return

	_check("the project index carries both entries (got %d)" % project.character_id_index.size(),
		project.character_id_index.size() == 2)

	# The bridge is a MANAGER copy, mutated in place: the pre-set_project reference must
	# observe the fill (the v1.2.3 stranding lesson).
	var bridge_view: Dictionary = _manager.get_character_id_bridge()
	_manager.set_project(project)
	_check("the pre-set_project bridge reference observes the fill (got %d entries)" % bridge_view.size(),
		bridge_view.size() == 2)

	# COUNT-GUARDED loop over the decoy ids.
	var ids := [FX.ALICE_ID, FX.BOB_ID]
	_check("decoy fixture drives 2 ids", ids.size() == 2)
	for id in ids:
		_check("bridge has an entry for %s" % id, bridge_view.has(id))
		var record_key: String = bridge_view.get(id, "")
		_check("bridge value for %s is byte-identical to its own normalization (got '%s')" % [id, record_key],
			record_key != "" and CharacterScript.normalize_path(record_key) == record_key)
		_check("bridge value '%s' hits _runtime_characters directly" % record_key,
			_manager.get_runtime_characters().has(record_key))

	_check("alice's key is stored verbatim (got '%s')" % bridge_view.get(FX.ALICE_ID, ""),
		bridge_view.get(FX.ALICE_ID, "") == FX.ALICE_KEY)
	_check("bob's key is stored verbatim (got '%s')" % bridge_view.get(FX.BOB_ID, ""),
		bridge_view.get(FX.BOB_ID, "") == FX.BOB_KEY)

	# The decoy check: same variable name, different values.
	_check("alice answers HER Trust (got %d)" % _trust_of(FX.ALICE_KEY), _trust_of(FX.ALICE_KEY) == 3)
	_check("bob answers HIS Trust (got %d)" % _trust_of(FX.BOB_KEY), _trust_of(FX.BOB_KEY) == 9)

	# reset_runtime_characters is the other refresh site: an entry erased from the bridge
	# must come back through the SAME object, in place.
	bridge_view.erase(FX.ALICE_ID)
	_manager.reset_runtime_characters()
	_check("reset_runtime_characters refills the bridge through the same reference",
		bridge_view.size() == 2 and bridge_view.get(FX.ALICE_ID, "") == FX.ALICE_KEY)

	# And reset_all_state keeps it whole - the bridge is import state, not player state.
	_manager.reset_all_state()
	_check("reset_all_state leaves the bridge filled (got %d entries)" % bridge_view.size(),
		bridge_view.size() == 2)


func _trust_of(record_key: String) -> int:
	var character = _manager.get_runtime_characters().get(record_key)
	if character == null:
		return -1
	var variable: Dictionary = character.variables.get("Trust", {})
	var value = variable.get("value")
	if value == null:
		return -1
	return value.get_int(-1)


# =============================================================================
# The five-rung degraded ladder
# =============================================================================

## Every refusing rung leaves the index EMPTY while the characters themselves still import -
## the warned consequence, "characters keep resolving by path", must be true. The refusal
## rungs carry a non-empty characters map so an empty index proves the rung refused rather
## than the map being empty. (The warn texts themselves are uncapturable from a SceneTree
## test; the importer parses the document once per import, so each warn is once by
## construction.)
func _test_ladder_rungs() -> void:
	print("-- degraded ladder --")
	var rungs := [
		{"label": "absent file is silent pre-P4", "text": null},
		{"label": "empty characters map is fine",
			"text": JSON.stringify({"schemaVersion": "1", "characters": {}})},
		{"label": "unknown schemaVersion is refused",
			"text": JSON.stringify({"schemaVersion": "2", "characters": {FX.ALICE_ID: FX.ALICE_KEY}})},
		{"label": "missing schemaVersion is refused",
			"text": JSON.stringify({"characters": {FX.ALICE_ID: FX.ALICE_KEY}})},
		{"label": "empty-string schemaVersion is refused",
			"text": JSON.stringify({"schemaVersion": "", "characters": {FX.ALICE_ID: FX.ALICE_KEY}})},
		{"label": "unreadable JSON is refused", "text": "not json {{{"},
		{"label": "a literal empty object is refused", "text": "{}"},
		{"label": "no characters object is refused",
			"text": JSON.stringify({"schemaVersion": "1"})},
		# A NUMERIC version is refused on EVERY Godot build. JSON parses it to a float, and what a
		# whole-valued float prints is version-dependent (4.3 renders 1.0 as "1", 4.6 as "1.0"), so
		# the old str()-gated check accepted this file on one Godot and skipped the id bridge on
		# another. The gate type-checks now, so this rung answers the same everywhere - which is
		# the whole point of the rung.
		{"label": "a numeric schemaVersion is refused (version-independently)",
			"text": JSON.stringify({"schemaVersion": 1, "characters": {FX.ALICE_ID: FX.ALICE_KEY}})},
	]
	_check("ladder fixture drives 9 rungs", rungs.size() == 9)
	for i in rungs.size():
		var rung: Dictionary = rungs[i]
		var project = _import_decoy_build("ladder_%d" % i, rung["text"])
		_check("%s: import still returns a project" % rung["label"], project != null)
		if project == null:
			continue
		_check("%s: the index stays empty (got %d)" % [rung["label"], project.character_id_index.size()],
			project.character_id_index.is_empty())
		_check("%s: characters keep resolving by path (got %d)" % [rung["label"], project.characters.size()],
			project.characters.size() == 2)


# =============================================================================
# Both-arms parity (the inline / WebSocket arm)
# =============================================================================

## import_project_from_json must import the index IDENTICALLY - the parallel inline arm
## silently dropping a sidecar is the divergence lesson test_import_hardening.gd pins for
## data assets.
func _test_inline_arm_parity() -> void:
	print("-- inline arm parity --")
	var importer := ImporterScript.new()

	var flat = importer.import_project_from_json({
		"version": "1.0",
		"scripts": {"Main": {"nodes": {"0": {"type": "start"}}, "connections": []}},
		"characters": FX.characters_payload(),
		"characterIndex": FX.index_payload(),
	})
	_check("inline import returns a project", flat != null)
	_check("inline import carries the index (got %d)" % (flat.character_id_index.size() if flat else -1),
		flat != null and flat.character_id_index.size() == 2)
	_check("inline values are verbatim too",
		flat != null and flat.character_id_index.get(FX.ALICE_ID, "") == FX.ALICE_KEY
			and flat.character_id_index.get(FX.BOB_ID, "") == FX.BOB_KEY)

	# The wrapper nesting is accepted too, matching the characters and dataAssets blocks.
	var wrapped = importer.import_project_from_json({
		"version": "1.0",
		"characterIndex": {"characterIndex": FX.index_payload()},
	})
	_check("inline import accepts the wrapper nesting (got %d)" % (wrapped.character_id_index.size() if wrapped else -1),
		wrapped != null and wrapped.character_id_index.size() == 2)

	# The ladder is the SAME ladder: an unknown version refuses inline exactly as on disk.
	var refused = importer.import_project_from_json({
		"version": "1.0",
		"characterIndex": {"schemaVersion": "2", "characters": {FX.ALICE_ID: FX.ALICE_KEY}},
	})
	_check("inline unknown schemaVersion is refused",
		refused != null and refused.character_id_index.is_empty())

	var not_object = importer.import_project_from_json({
		"version": "1.0",
		"characterIndex": "garbage",
	})
	_check("an inline index that is no object is refused",
		not_object != null and not_object.character_id_index.is_empty())


# =============================================================================
# Phantom-script regression
# =============================================================================

## character-index.json must be on the standalone-script sweep's skip list: an unlisted
## sidecar becomes a phantom script named after its filename, silently, in shipped games -
## load_project_local re-runs the sweep on EVERY launch (the data-assets killer regression,
## mirrored for the new sidecar).
func _test_phantom_script_regression() -> void:
	print("-- phantom-script regression --")
	var build := _temp("phantom/build")
	var out := _temp("phantom/out")
	FX.write_build(build, FX.index_text_valid())

	var importer := ImporterScript.new()
	var project = importer.import_project(build, out)
	_check("import with character-index.json returns a project", project != null)
	if project == null:
		return

	_check("character-index.json does not become a phantom script",
		not project.scripts.has("character-index"))
	_check("only the real script is imported (got %s)" % [project.scripts.keys()],
		project.scripts.size() == 1 and project.scripts.has("Main"))

	# The re-sweep an exported game performs on every launch must stay clean too.
	var reloaded = importer.load_project_local(out)
	_check("reloading the output directory still produces no phantom script",
		reloaded != null and not reloaded.scripts.has("character-index"))
	_check("reloading the output directory still carries the index (got %d)" % (reloaded.character_id_index.size() if reloaded else -1),
		reloaded != null and reloaded.character_id_index.size() == 2)


# =============================================================================
# Node-field carry-through (both arms)
# =============================================================================

## The additive id fields must survive the EXPLICIT node parse: characterRefId beside
## dialogue's character, characterId beside characterPath - present when shipped, absent
## otherwise, in both import arms.
func _test_node_field_carry() -> void:
	print("-- node-field carry --")
	var nodes := {
		"0": {"type": "start"},
		"1": {"type": "dialogue", "text": "hi", "character": "cast/alice.sfc",
			"characterRefId": FX.ALICE_ID},
		"2": {"type": "getCharacterVar", "characterPath": "cast/alice.sfc",
			"variable": "Trust", "variableType": "integer", "characterId": FX.ALICE_ID},
		"3": {"type": "dialogue", "text": "plain", "character": "cast/alice.sfc"},
		"4": {"type": "setCharacterVar", "characterPath": "cast/bob.sfc",
			"variable": "Trust", "variableType": "integer"},
	}

	var build := _temp("carry/build")
	var out := _temp("carry/out")
	FX.write_build(build, FX.index_text_valid(), nodes)
	var disk = ImporterScript.new().import_project(build, out)
	_check("disk import for the carry pins returns a project", disk != null)
	if disk != null:
		_assert_carry("disk arm", disk.scripts.get("Main"))

	var inline = ImporterScript.new().import_project_from_json({
		"version": "1.0",
		"scripts": {"Main": {"nodes": nodes, "connections": []}},
	})
	_check("inline import for the carry pins returns a project", inline != null)
	if inline != null:
		_assert_carry("inline arm", inline.scripts.get("Main"))


func _assert_carry(arm: String, script) -> void:
	if script == null:
		_check("%s: Main script imported" % arm, false)
		return
	var dialogue_data: Dictionary = script.nodes.get("1", {}).get("data", {})
	_check("%s: dialogue carries characterRefId (got '%s')" % [arm, dialogue_data.get("characterRefId", "")],
		dialogue_data.get("characterRefId", "") == FX.ALICE_ID)
	_check("%s: the path sibling still rides beside it" % arm,
		dialogue_data.get("character", "") == "cast/alice.sfc")
	var getter_data: Dictionary = script.nodes.get("2", {}).get("data", {})
	_check("%s: char-var getter carries characterId (got '%s')" % [arm, getter_data.get("characterId", "")],
		getter_data.get("characterId", "") == FX.ALICE_ID)
	var plain_dialogue: Dictionary = script.nodes.get("3", {}).get("data", {})
	_check("%s: a dialogue shipped without characterRefId stays without it" % arm,
		not plain_dialogue.has("characterRefId"))
	var plain_setter: Dictionary = script.nodes.get("4", {}).get("data", {})
	_check("%s: a char-var setter shipped without characterId stays without it" % arm,
		not plain_setter.has("characterId"))


# =============================================================================
# Latch mechanics: the context-owned node-lane pair
# =============================================================================

## should_warn_character_id claims once per id|reason; the counter counts EMISSIONS (the
## difference between a working once-latch and a per-call warning); reset() re-arms the
## pair and rebinds the non-owning bridge reference to a fresh empty.
func _test_context_latch_mechanics() -> void:
	print("-- context latch --")
	var ctx = ContextScript.new()

	_check("first dangling claim warns", ctx.should_warn_character_id(FX.ALICE_ID, "dangling"))
	_check("second dangling claim is latched", not ctx.should_warn_character_id(FX.ALICE_ID, "dangling"))
	_check("a different REASON on the same id warns once more",
		ctx.should_warn_character_id(FX.ALICE_ID, "unloaded"))
	_check("a different ID warns once more", ctx.should_warn_character_id(FX.BOB_ID, "dangling"))
	_check("the counter counts emissions, not calls (got %d)" % ctx.character_id_warnings_emitted,
		ctx.character_id_warnings_emitted == 3)
	_check("the latch dict holds the claimed keys (got %d)" % ctx.warned_character_ids.size(),
		ctx.warned_character_ids.size() == 3)

	# reset() re-arms the pair - beside the data-asset pair, same convention.
	var manager_bridge: Dictionary = _manager.get_character_id_bridge()
	ctx.character_id_bridge = manager_bridge
	ctx.reset()
	_check("reset clears the latch dict", ctx.warned_character_ids.is_empty())
	_check("reset zeroes the counter", ctx.character_id_warnings_emitted == 0)
	_check("a claim after reset warns again", ctx.should_warn_character_id(FX.ALICE_ID, "dangling"))
	_check("reset REBINDS the bridge reference to a fresh empty",
		ctx.character_id_bridge.is_empty())
	_check("the manager's own bridge was not cleared through the reference",
		not manager_bridge.is_empty())


# =============================================================================
# Latch mechanics: the manager-owned host-lane pair
# =============================================================================

## The host-lane pair mirrors should_warn_data_asset_access: once per id|reason, and
## re-armed ONLY on set_project and reset_all_state - a character reset or a data-asset
## reset must not re-arm it.
func _test_manager_latch_mechanics() -> void:
	print("-- manager latch --")
	_check("first host-lane claim warns", _manager.should_warn_character_id_access(FX.ALICE_ID, "dangling"))
	_check("second host-lane claim is latched",
		not _manager.should_warn_character_id_access(FX.ALICE_ID, "dangling"))
	_check("a different reason claims separately",
		_manager.should_warn_character_id_access(FX.ALICE_ID, "unloaded"))
	_check("the host counter counts emissions (got %d)" % _manager.character_id_access_warnings_emitted,
		_manager.character_id_access_warnings_emitted == 2)

	# Neither sibling reset re-arms it.
	_manager.reset_runtime_characters()
	_manager.reset_data_assets()
	_check("reset_runtime_characters / reset_data_assets do NOT re-arm the host latch",
		not _manager.should_warn_character_id_access(FX.ALICE_ID, "dangling")
			and _manager.character_id_access_warnings_emitted == 2)

	# reset_all_state is one of its two re-arm events...
	_manager.reset_all_state()
	_check("reset_all_state re-arms the host latch",
		_manager.warned_character_id_access.is_empty()
			and _manager.character_id_access_warnings_emitted == 0
			and _manager.should_warn_character_id_access(FX.ALICE_ID, "dangling"))

	# ...and set_project is the other.
	_manager.set_project(_import_decoy_build("latch_rearm", FX.index_text_valid()))
	_check("set_project re-arms the host latch",
		_manager.warned_character_id_access.is_empty()
			and _manager.character_id_access_warnings_emitted == 0
			and _manager.should_warn_character_id_access(FX.ALICE_ID, "dangling"))


# =============================================================================
# Helpers
# =============================================================================

## Import the decoy build with [param index_text] (null = no index file) through the REAL
## disk arm, returning the project.
func _import_decoy_build(label: String, index_text):
	var build := _temp("%s/build" % label)
	var out := _temp("%s/out" % label)
	FX.write_build(build, index_text)
	return ImporterScript.new().import_project(build, out)


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
