extends SceneTree
## Headless tests for the P4 character branch of the DATA ASSET HOST SURFACE (characters
## engine contract §3/§4 + A1-A3, A5) and the A2(a) alias tiers on the public character
## lanes: seed-first routing, name-routed typed reads and writes against the ONE character
## state, the manager-owned host latch (and its independence from the context latch), the
## cf_ aliases per lane with the double-row case-variant protection, never-creates, and the
## node-lane-only signal posture.
##
## FIXTURES: the DECOY PAIR from tests/character_test_fixtures.gd. Loops are COUNT-GUARDED.
##
## Run from the repository root (import first to build the class cache):
##   godot --headless --import
##   godot --headless --script res://tests/test_character_host_surface.gd
## Or: powershell -File tests/run_tests.ps1 -GodotExe <path-to-godot>

const CharacterScript := preload("res://addons/storyflow/core/storyflow_character.gd")
const ComponentScript := preload("res://addons/storyflow/core/storyflow_component.gd")
const FX := preload("res://tests/character_test_fixtures.gd")
const Graph := preload("res://tests/data_asset_test_graph.gd")
const Handles := preload("res://addons/storyflow/core/storyflow_handles.gd")
const ImporterScript := preload("res://addons/storyflow/editor/storyflow_importer.gd")
const ManagerScript := preload("res://addons/storyflow/core/storyflow_manager.gd")
const Types := preload("res://addons/storyflow/core/storyflow_types.gd")
const VariantScript := preload("res://addons/storyflow/core/storyflow_variant.gd")

## A REAL data asset shipped beside the characters, so seed-disjointness and seed-first
## routing are pinned against a seed that actually has something in it.
const RULES_ID := "da_0123456789abcdef0123456789abcdef"

var _checks: int = 0
var _failures: int = 0
var _temp_root: String = ""
var _manager: Node = null


func _initialize() -> void:
	await process_frame
	_temp_root = OS.get_user_data_dir().path_join("sf_character_host_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(_temp_root)
	_manager = ManagerScript.new()
	_manager.name = "StoryFlowRuntime"
	get_root().add_child(_manager)

	_test_seed_disjointness_and_routing()
	_test_branch_reads_and_refusals()
	_test_branch_writes_one_state_and_signal_silence()
	_test_host_latch_unloaded_and_cross_lane_independence()
	_test_public_lane_alias_tiers()

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
# 1. Seed-disjointness + seed-first routing, through a real import
# =============================================================================

## The build ships characters, the index AND a real data-assets.json. No character id may
## appear in the data-asset seed (contract §2 - the disjointness the seed-first branch order
## relies on), a data-asset id still resolves through the store, and a character id routes
## to character state.
func _test_seed_disjointness_and_routing() -> void:
	print("-- seed disjointness + routing --")
	_import_full_build("disjoint", FX.index_text_valid())

	var seed: Dictionary = _manager.get_data_asset_seed()
	_check("the DA seed carries the shipped asset", seed.has(RULES_ID))
	var bridge: Dictionary = _manager.get_character_id_bridge()
	var ids := bridge.keys()
	_check("bridge fixture drives 2 ids (got %d)" % ids.size(), ids.size() == 2)
	for id in ids:
		_check("character id %s is NOT in the DA seed" % id, not seed.has(id))

	var component := _make_component()
	_check("a data-asset id still resolves through the store (got %d)" % component.get_data_asset_int(RULES_ID, "hp", -1),
		component.get_data_asset_int(RULES_ID, "hp", -1) == 77)
	_check("a character id routes to character state (alice Trust 3, got %d)" % component.get_data_asset_int(FX.ALICE_ID, "Trust", -1),
		component.get_data_asset_int(FX.ALICE_ID, "Trust", -1) == 3)
	_check("the decoy answers his own values (bob Trust 9, got %d)" % component.get_data_asset_int(FX.BOB_ID, "Trust", -1),
		component.get_data_asset_int(FX.BOB_ID, "Trust", -1) == 9)
	_check("no host warnings on clean routing (got %d)" % _manager.character_id_access_warnings_emitted,
		_manager.character_id_access_warnings_emitted == 0)
	_free_component(component)


# =============================================================================
# 2. Branch reads: every accessor, the aliases, and the latched refusals
# =============================================================================

func _test_branch_reads_and_refusals() -> void:
	print("-- branch reads + refusals --")
	_import_full_build("reads", FX.index_text_valid())
	var component := _make_component()

	_check("bool read (alice Brave true)", component.get_data_asset_bool(FX.ALICE_ID, "Brave", false) == true)
	_check("int read (alice Trust 3)", component.get_data_asset_int(FX.ALICE_ID, "Trust", -1) == 3)
	_check("string read (alice Title Captain)", component.get_data_asset_string(FX.ALICE_ID, "Title") == "Captain")

	# The reserved cf_ ids answer the builtins - STORED keys, never resolved (A5: this
	# surface extends the literal-string DA host API).
	_check("cf_name answers the STORED name key (got '%s')" % component.get_data_asset_string(FX.ALICE_ID, "cf_name"),
		component.get_data_asset_string(FX.ALICE_ID, "cf_name") == "char.alice.name")
	_check("cf_image answers the builtin image key", component.get_data_asset_string(FX.ALICE_ID, "cf_image") == "alice_portrait")
	_check("the first tier is case-insensitive (CF_NAME)", component.get_data_asset_string(FX.ALICE_ID, "CF_NAME") == "char.alice.name")
	_check("'Name' answers the builtin too", component.get_data_asset_string(FX.ALICE_ID, "Name") == "char.alice.name")
	# The double-row protection on a first-tier lane: the builtin arm SHADOWS the custom
	# "Image" row, exactly like every pre-P4 case-insensitive builtin arm.
	_check("'Image' answers the BUILTIN, shadowing the custom row (got '%s')" % component.get_data_asset_string(FX.ALICE_ID, "Image"),
		component.get_data_asset_string(FX.ALICE_ID, "Image") == "alice_portrait")

	# The untyped door reaches arrays and maps, DETACHED.
	var inv = component.get_data_asset_variant(FX.ALICE_ID, "Inventory")
	_check("the variant door reads an array (got %s)" % str(_strings_of(inv.get_array()) if inv else null),
		inv != null and _strings_of(inv.get_array()) == ["sword", "rope"])
	if inv != null:
		inv.get_array().clear()
		var again = component.get_data_asset_variant(FX.ALICE_ID, "Inventory")
		_check("and hands out a DETACHED copy (mutating it reaches nothing)",
			again != null and _strings_of(again.get_array()) == ["sword", "rope"])
	var prices = component.get_data_asset_variant(FX.ALICE_ID, "Prices")
	_check("the variant door reads a map (ale=3)",
		prices != null and prices.is_map() and prices.get_map()["ale"].get_int(-1) == 3)

	# Refusals: default answered, warned ONCE per (id, reason) on the MANAGER pair.
	var before: int = _manager.character_id_access_warnings_emitted
	_check("a mistyped read answers its default", component.get_data_asset_bool(FX.ALICE_ID, "Title", true) == true)
	_check("latched as wrongtype:Title",
		_manager.warned_character_id_access.has("%s|wrongtype:Title" % FX.ALICE_ID))
	component.get_data_asset_bool(FX.ALICE_ID, "Title", true)
	_check("and warned once (got %d, was %d)" % [_manager.character_id_access_warnings_emitted, before],
		_manager.character_id_access_warnings_emitted == before + 1)
	# The string door matches Inventory's ELEMENT type, so this refusal is the isarray
	# rung itself, not a wrongtype shadowing it.
	_check("an array row refuses the scalar door", component.get_data_asset_string(FX.ALICE_ID, "Inventory", "-") == "-")
	_check("latched as isarray:Inventory",
		_manager.warned_character_id_access.has("%s|isarray:Inventory" % FX.ALICE_ID))
	_check("an undeclared variable answers its default", component.get_data_asset_int(FX.ALICE_ID, "Nope", -5) == -5)
	_check("latched as novariable:Nope",
		_manager.warned_character_id_access.has("%s|novariable:Nope" % FX.ALICE_ID))
	_free_component(component)


# =============================================================================
# 3. Branch writes: one state in BOTH directions, never-creates, no signal
# =============================================================================

func _test_branch_writes_one_state_and_signal_silence() -> void:
	print("-- branch writes + one state --")
	_import_full_build("writes", FX.index_text_valid())
	var component := _make_component()
	var host_emissions: Array = []
	component.character_variable_changed.connect(func(path, vname, _value): host_emissions.append([path, vname]))

	var alice = _manager.get_runtime_characters()[FX.ALICE_KEY]

	# Direction 1: DA-surface write -> evaluator (node-lane) read.
	_check("a host int write lands", component.set_data_asset_int(FX.ALICE_ID, "Trust", 7))
	var read_script := Graph.build("scripts/HostRead.sfe", {
		"0": Graph.start(),
		"G": Graph.node("G", Types.NodeType.GET_CHARACTER_VAR, "getCharacterVar",
			{"characterPath": FX.BOB_KEY, "characterId": FX.ALICE_ID, "variableName": "Trust", "variableType": "integer"}),
		"S": Graph.node("S", Types.NodeType.SET_INT, "setInt", {"variable": "readback", "isGlobal": false}),
		"D": Graph.dialogue("D"),
	}, [
		Graph.exec("0", "S"), Graph.exec_flow("S", "D"),
		Graph.data_wire("G", "integer", "S", Handles.IN_INTEGER),
	], {
		"readback": Graph.scalar_var("readback", "readback", Types.VariableType.INTEGER, VariantScript.from_int(-1)),
	})
	_manager.get_project().scripts[read_script.script_path] = read_script
	var runner := _make_component()
	runner.start_dialogue_with_script(read_script.script_path)
	_check("the evaluator reads the host write back (got %d)" % runner.get_int_variable("readback"),
		runner.get_int_variable("readback") == 7)
	runner.stop_dialogue()
	_free_component(runner)

	# Direction 2: node-lane write -> DA-surface read.
	var write_script := Graph.build("scripts/NodeWrite.sfe", {
		"0": Graph.start(),
		"W": Graph.node("W", Types.NodeType.SET_CHARACTER_VAR, "setCharacterVar",
			{"characterPath": FX.BOB_KEY, "characterId": FX.ALICE_ID, "variableName": "Trust",
				"variableType": "integer", "value": VariantScript.from_int(42)}),
		"D": Graph.dialogue("D"),
	}, [
		Graph.exec("0", "W"), Graph.exec_flow("W", "D"),
	])
	_manager.get_project().scripts[write_script.script_path] = write_script
	var writer := _make_component()
	writer.start_dialogue_with_script(write_script.script_path)
	writer.stop_dialogue()
	_free_component(writer)
	_check("the DA surface reads the node write back (got %d)" % component.get_data_asset_int(FX.ALICE_ID, "Trust", -1),
		component.get_data_asset_int(FX.ALICE_ID, "Trust", -1) == 42)

	# Builtin writes through the reserved ids, stored keys in and out.
	_check("a cf_name write lands", component.set_data_asset_string(FX.ALICE_ID, "cf_name", "new.name.key"))
	_check("stored verbatim", alice.character_name == "new.name.key")
	_check("a cf_image write lands", component.set_data_asset_string(FX.ALICE_ID, "cf_image", "tavern"))
	_check("on the builtin, not the custom row", alice.image_key == "tavern"
		and _var_of(alice, "Image").get_string() == "alice-custom-image-row")

	# A3(b): never-creates, on every refusing shape.
	var var_count: int = alice.variables.size()
	_check("an undeclared write refuses", not component.set_data_asset_int(FX.ALICE_ID, "Ghost", 1))
	_check("a mistyped write refuses", not component.set_data_asset_bool(FX.ALICE_ID, "Trust", true))
	_check("an array row refuses the scalar setter", not component.set_data_asset_int(FX.ALICE_ID, "Inventory", 1))
	_check("and none of them created anything (got %d vars)" % alice.variables.size(),
		alice.variables.size() == var_count)
	_check("the refused value is untouched", _var_of(alice, "Trust").get_int(-1) == 42)

	# No overlay touch: character writes live on the character, never in the .sfd overlay.
	_check("the data-asset overlay saw none of it", _overlay_entry_count(_manager.get_data_asset_overlay()) == 0)

	# A2(b): the HOST lanes emit nothing - the signal is node-lane only.
	component.set_character_variable(FX.ALICE_KEY, "Trust", VariantScript.from_int(11))
	_check("public set emits nothing and the DA-surface branch emits nothing (got %d)" % host_emissions.size(),
		host_emissions.is_empty())
	_check("(the public set still landed)", _var_of(alice, "Trust").get_int(-1) == 11)
	_free_component(component)


# =============================================================================
# 4. The host latch: unloaded via a real ghost import + cross-lane independence
# =============================================================================

## The ghost index entry (bridge hit, record unloaded) reaches BOTH lanes' character
## latches - and each owner warns ONCE, independently: a node-lane warn does not consume
## the host-lane latch. A DANGLING id never reaches the host character latch at all: it
## falls through to the DA ladder and gets the pre-P4 noasset treatment.
func _test_host_latch_unloaded_and_cross_lane_independence() -> void:
	print("-- host latch + cross-lane independence --")
	_import_full_build("latch", FX.index_text_with_ghost())
	var component := _make_component()

	# NODE lane first: the ghost id warns once on the CONTEXT.
	var ghost_script := Graph.build("scripts/GhostNode.sfe", {
		"0": Graph.start(),
		"G": Graph.node("G", Types.NodeType.GET_CHARACTER_VAR, "getCharacterVar",
			{"characterPath": "", "characterId": FX.GHOST_ID, "variableName": "Trust", "variableType": "integer"}),
		"S": Graph.node("S", Types.NodeType.SET_INT, "setInt", {"variable": "a", "isGlobal": false}),
		"D": Graph.dialogue("D"),
	}, [
		Graph.exec("0", "S"), Graph.exec_flow("S", "D"),
		Graph.data_wire("G", "integer", "S", Handles.IN_INTEGER),
	], {
		"a": Graph.scalar_var("a", "a", Types.VariableType.INTEGER, VariantScript.from_int(-1)),
	})
	_manager.get_project().scripts[ghost_script.script_path] = ghost_script
	var runner := _make_component()
	runner.start_dialogue_with_script(ghost_script.script_path)
	_check("the node lane warned once on the context (got %d)" % runner._context.character_id_warnings_emitted,
		runner._context.character_id_warnings_emitted == 1)
	_check("without touching the host latch (got %d)" % _manager.character_id_access_warnings_emitted,
		_manager.character_id_access_warnings_emitted == 0)

	# HOST lane: the SAME id and reason warns once on the MANAGER - the node-lane warn did
	# not consume it (inheritance 6).
	_check("the host read answers its default", component.get_data_asset_int(FX.GHOST_ID, "Trust", -3) == -3)
	_check("the host lane warned once, independently (got %d)" % _manager.character_id_access_warnings_emitted,
		_manager.character_id_access_warnings_emitted == 1)
	_check("under the id|unloaded key",
		_manager.warned_character_id_access.has("%s|unloaded" % FX.GHOST_ID))
	component.get_data_asset_int(FX.GHOST_ID, "Trust", -3)
	_check("once means once (got %d)" % _manager.character_id_access_warnings_emitted,
		_manager.character_id_access_warnings_emitted == 1)
	# And the node-lane latch was not consumed by the host warn either: the runner's
	# context still holds its own claim.
	_check("the context still holds its own claim",
		runner._context.warned_character_ids.has("%s|unloaded" % FX.GHOST_ID))
	runner.stop_dialogue()
	_free_component(runner)

	# reset_all_state is a host re-arm event.
	_manager.reset_all_state()
	_check("reset_all_state re-arms the host latch", _manager.character_id_access_warnings_emitted == 0)
	component.get_data_asset_int(FX.GHOST_ID, "Trust", -3)
	_check("and the next host miss warns again (got %d)" % _manager.character_id_access_warnings_emitted,
		_manager.character_id_access_warnings_emitted == 1)

	# A DANGLING id on the host lane: no bridge entry -> the DA ladder keeps it, byte-identical
	# pre-P4 (noasset on the DA access latch), and the character pair never hears of it.
	_check("a dangling id answers the DA default", component.get_data_asset_int(FX.DANGLING_ID, "Trust", -9) == -9)
	_check("on the DA access latch (noasset)",
		_manager.warned_data_asset_access.has("%s||noasset" % FX.DANGLING_ID))
	_check("never the character pair",
		not _manager.warned_character_id_access.has("%s|dangling" % FX.DANGLING_ID))
	_free_component(component)


# =============================================================================
# 5. The A2(a) alias tiers on the PUBLIC character lanes
# =============================================================================

## First tier on get_character_variable (case-insensitive builtin arms, cf_ folded in);
## SECOND tier on set_character_variable: ONLY the exact cf_ spellings divert - the native
## spellings keep the case-sensitive dict behavior byte-identical, which is what the
## double-row image/Image fixture protects.
func _test_public_lane_alias_tiers() -> void:
	print("-- public lane alias tiers --")
	_import_full_build("aliases", FX.index_text_valid())
	var component := _make_component()
	var alice = _manager.get_runtime_characters()[FX.ALICE_KEY]

	# First tier, reads (this lane RESOLVES the name key - A5's resolving door).
	_check("get cf_name answers the builtin", component.get_character_variable(FX.ALICE_KEY, "cf_name").get_string() == "char.alice.name")
	_check("get CF_IMAGE is case-insensitive", component.get_character_variable(FX.ALICE_KEY, "CF_IMAGE").get_string() == "alice_portrait")
	_check("get 'Image' answers the BUILTIN, shadowing the custom row",
		component.get_character_variable(FX.ALICE_KEY, "Image").get_string() == "alice_portrait")

	# Second tier, writes: exact cf_ spellings divert to the builtins...
	component.set_character_variable(FX.ALICE_KEY, "cf_image", VariantScript.from_string("cellar"))
	_check("set cf_image writes the builtin", alice.image_key == "cellar")
	_check("and leaves the custom 'Image' row alone", _var_of(alice, "Image").get_string() == "alice-custom-image-row")
	component.set_character_variable(FX.ALICE_KEY, "cf_name", VariantScript.from_string("renamed.key"))
	_check("set cf_name writes the builtin", alice.character_name == "renamed.key")

	# ...while the native spellings keep the case-sensitive dict byte-identical.
	component.set_character_variable(FX.ALICE_KEY, "Image", VariantScript.from_string("custom-row-write"))
	_check("set 'Image' writes the CUSTOM row", _var_of(alice, "Image").get_string() == "custom-row-write")
	_check("not the builtin", alice.image_key == "cellar")
	var var_count: int = alice.variables.size()
	component.set_character_variable(FX.ALICE_KEY, "image", VariantScript.from_string("nope"))
	_check("set lowercase 'image' is the pre-P4 silent no-op",
		alice.image_key == "cellar" and _var_of(alice, "Image").get_string() == "custom-row-write")
	component.set_character_variable(FX.ALICE_KEY, "Cf_Name", VariantScript.from_string("nope"))
	_check("the second tier is EXACT - 'Cf_Name' diverts nothing", alice.character_name == "renamed.key")
	_check("and none of the no-ops created a variable (got %d)" % alice.variables.size(),
		alice.variables.size() == var_count)
	_free_component(component)


# =============================================================================
# Helpers
# =============================================================================

## Import a build carrying the decoy characters, [param index_text] AND a real one-asset
## data-assets.json, then install it on the manager.
func _import_full_build(label: String, index_text) -> void:
	var build := _temp("%s/build" % label)
	var out := _temp("%s/out" % label)
	FX.write_build(build, index_text)
	FX.write_text(build.path_join("data-assets.json"), JSON.stringify({
		"dataAssets": {
			RULES_ID: {
				"id": RULES_ID,
				"name": "Rules",
				"parent": null,
				"variables": [
					{"id": "0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f", "name": "hp", "type": "integer", "value": 77},
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


func _strings_of(elements: Array) -> Array:
	var out: Array = []
	for element in elements:
		if element is VariantScript:
			out.append(element.get_string())
	return out


## Total entries across every asset bucket of the overlay, whatever its nesting.
func _overlay_entry_count(overlay: Dictionary) -> int:
	var count := 0
	for asset_id in overlay:
		var bucket = overlay[asset_id]
		if bucket is Dictionary:
			count += bucket.size()
	return count


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
