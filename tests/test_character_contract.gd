extends SceneTree
## Headless conforming reader for the P4 characters-engine-contract SS5 golden package
## (tests/fixtures/character-contract/, vendored byte-identical from the editor repo).
##
## THE MANIFEST IS THE DRIVER: manifest.json's caseFiles are iterated in order, every case is
## dispatched on its "kind" (a kind outside the manifest's list FAILS), a case excluded for
## godot is SKIPPED AS DATA (visited, SS9 reason logged, counted consumed), the expect_fail
## case is asserted to MISMATCH (a harness that passes it proves nothing), and the run ends by
## asserting exactly case_count cases were consumed - the manifest's own count IS the guard.
##
## A5 SEATS IN THIS ENGINE: expected.value lands on the surfaces that own language state -
## the node-lane typed reads (evaluate_*_from_node resolves string results through
## _resolve_string_key) and the public/ById getters' builtin Name arm - while expected.stored
## lands on the stored-key doors: the evaluator arm's raw variant, the DA-surface character
## branch, the raw record fields, and the save output. Image `stored` is the characters.json
## asset id; image `value` is the assets-table path the import resolves it to (asserted via
## the copied media file and the portrait resolving to a real texture).
##
## Run from the repository root (import first to build the class cache):
##   godot --headless --import
##   godot --headless --script res://tests/test_character_contract.gd
## Or: powershell -File tests/run_tests.ps1 -GodotExe <path-to-godot>

const CharacterScript := preload("res://addons/storyflow/core/storyflow_character.gd")
const ComponentScript := preload("res://addons/storyflow/core/storyflow_component.gd")
const ContextScript := preload("res://addons/storyflow/core/storyflow_execution_context.gd")
const Doors := preload("res://tests/data_asset_read_doors.gd")
const EvaluatorScript := preload("res://addons/storyflow/core/storyflow_evaluator.gd")
const Graph := preload("res://tests/data_asset_test_graph.gd")
const Handles := preload("res://addons/storyflow/core/storyflow_handles.gd")
const ImporterScript := preload("res://addons/storyflow/editor/storyflow_importer.gd")
const ManagerScript := preload("res://addons/storyflow/core/storyflow_manager.gd")
const Types := preload("res://addons/storyflow/core/storyflow_types.gd")
const VariantScript := preload("res://addons/storyflow/core/storyflow_variant.gd")

const FIXTURE_DIR := "res://tests/fixtures/character-contract"
const SAVE_SLOT := "character_contract"

var _checks: int = 0
var _failures: int = 0
var _temp_root: String = ""
var _manager: Node = null

## The parsed manifest and the package's own strings/assets tables (data, for mapping the
## reference's resolved expectations onto this engine's stored-key save output).
var _manifest: Dictionary = {}
var _pkg_strings: Dictionary = {}
var _pkg_assets: Dictionary = {}

## Consumption accounting: the manifest's case_count is the guard.
var _consumed: int = 0
var _ran_by_kind: Dictionary = {}
var _skipped_excluded: int = 0
var _expect_fail_inverted: int = 0

## The resolution runtime (one import serves every read/speaker case).
var _res_probe: StoryFlowComponent = null
var _res_out: String = ""
var _probe_seq: int = 0

## The writes runtime (ONE runtime for the whole ordered write/sweep/save replay).
var _wr_probe: StoryFlowComponent = null
var _wr_out: String = ""

## The localization runtime (§9): ONE import of the package build WITH its sidecar, the project it
## produced (re-installed after the source-only case imports a second, sidecar-less build), the
## sidecar's own tables as DATA for the tripwire, and a component that never starts a dialogue -
## the OUTSIDE-dialogue door.
var _loc_project = null
var _loc_outside: StoryFlowComponent = null
var _pkg_localization: Dictionary = {}

## The `.sfd` lane (spec SS2's amendment): the vendored seed as DATA, the two-door driver, and the
## component whose parked dialogue keeps the node lane's accessors live.
var _pkg_data_assets: Dictionary = {}
var _loc_doors = null
var _loc_probe: StoryFlowComponent = null


func _initialize() -> void:
	await process_frame
	_temp_root = OS.get_user_data_dir().path_join("sf_character_contract_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(_temp_root)
	_manager = ManagerScript.new()
	_manager.name = "StoryFlowRuntime"
	get_root().add_child(_manager)
	_manager.delete_save(SAVE_SLOT)

	_manifest = _load_fixture(FIXTURE_DIR.path_join("manifest.json"))
	_check("manifest.json loads", not _manifest.is_empty())
	_check("the package names this engine (got %s)" % str(_manifest.get("engines", [])),
		_manifest.get("engines", []).has("godot"))
	var chars_doc := _load_fixture(FIXTURE_DIR.path_join("characters.json"))
	_pkg_strings = chars_doc.get("strings", {}).get("en", {})
	_pkg_assets = chars_doc.get("assets", {})

	var kinds: Array = _manifest.get("kinds", [])
	var case_files: Array = _manifest.get("caseFiles", [])
	_check("the manifest carries caseFiles", not case_files.is_empty())

	for entry in case_files:
		var file_name := str(entry.get("file", ""))
		var doc := _load_fixture(FIXTURE_DIR.path_join(file_name))
		var cases: Array = doc.get("cases", [])
		_check("%s carries its declared case_count (%d, got %d)" % [file_name, int(entry.get("case_count", -1)), cases.size()],
			cases.size() == int(entry.get("case_count", -1)))

		if file_name == "character-resolution.json":
			_prepare_resolution_runtime(cases)
		elif file_name == "character-writes.json":
			_prepare_writes_runtime(cases)
		elif file_name == "localization-resolution.json":
			_prepare_localization_runtime(cases)

		var visited := 0
		for idx in cases.size():
			var case: Dictionary = cases[idx]
			visited += 1
			var kind := str(case.get("kind", ""))
			if not kinds.has(kind):
				_check("case '%s' carries a manifest kind (got '%s')" % [str(case.get("case", "?")), kind], false)
				_consumed += 1
				continue
			var excluded: Dictionary = case.get("excluded", {})
			if excluded.has("godot"):
				print("  SKIP (excluded, SS9): %s - %s" % [str(case.get("case", "?")), str(excluded["godot"])])
				_skipped_excluded += 1
				_consumed += 1
				continue
			match kind:
				"read":
					_run_read_case(case, idx)
				"speaker":
					_run_speaker_case(case)
				"write":
					_run_write_case(case, idx)
				"sweep":
					_run_sweep_case(case, idx)
				"save":
					_run_save_case(case)
				"degraded":
					_run_degraded_case(case, idx)
				"localized":
					_run_localized_case(case)
				"unkeyed":
					_run_unkeyed_case(case)
				"language-table":
					_run_language_table_case(case)
				"source-only":
					_run_source_only_case(case)
				_:
					_check("kind '%s' has a handler" % kind, false)
			_ran_by_kind[kind] = int(_ran_by_kind.get(kind, 0)) + 1
			_consumed += 1
		_check("%s: visited every case (%d of %d)" % [file_name, visited, cases.size()], visited == cases.size())

	var expected_total := int(_manifest.get("case_count", -1))
	_check("consumed exactly case_count cases (%d of %d)" % [_consumed, expected_total],
		_consumed == expected_total)
	_check("the expect_fail case was reported failing (inverted %d of %d)"
		% [_expect_fail_inverted, _manifest.get("expect_fail_cases", []).size()],
		_expect_fail_inverted == _manifest.get("expect_fail_cases", []).size())
	print("Per-kind accounting: %s | skipped-excluded: %d | expect-fail-inverted: %d"
		% [str(_ran_by_kind), _skipped_excluded, _expect_fail_inverted])

	if _res_probe != null:
		_teardown(_res_probe)
		_res_probe = null
	if _wr_probe != null:
		_teardown(_wr_probe)
		_wr_probe = null
	if _loc_outside != null:
		_teardown(_loc_outside)
		_loc_outside = null
	if _loc_probe != null:
		_teardown(_loc_probe)
		_loc_probe = null

	# The §9 language API, beyond the manifest's cases: the live wiring a game actually calls, run
	# after the case replay so it cannot disturb it.
	_run_localization_api()

	_manager.delete_save(SAVE_SLOT)
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
# Package build + import (the vendor-verbatim rule: bytes copied, never re-encoded)
# =============================================================================

## Write the package's inputs VERBATIM into a build dir, plus the minimal
## project.storyflow envelope and the two media files the assets table names.
## [param index_mode]: "verbatim" | "none" | "ghost" (inject [param ghost] as data).
## [param with_localization]: whether localization.json is written beside the artifacts. THE
## SIDECAR'S PRESENCE IS THE §9 MARKER, so "source-only" is expressed here - by not writing the
## file into a real build - and never by emptying a table after an import. The §5 arm's builds
## carry no sidecar, which keeps that arm's conditions byte-unchanged by this task.
func _write_package_build(build_dir: String, index_mode: String, ghost: Dictionary = {}, with_localization: bool = false) -> void:
	DirAccess.make_dir_recursive_absolute(build_dir)
	_write_text(build_dir.path_join("project.storyflow"), JSON.stringify({
		"version": "1.0",
		"metadata": {"title": "CharacterContract"},
		"startupScript": "script",
	}, "\t"))
	for input_file in ["characters.json", "script.json", "data-assets.json"]:
		_write_text(build_dir.path_join(input_file), _read_text(FIXTURE_DIR.path_join(input_file)))
	if index_mode == "verbatim":
		_write_text(build_dir.path_join("character-index.json"), _read_text(FIXTURE_DIR.path_join("character-index.json")))
	elif index_mode == "ghost":
		var payload: Dictionary = _load_fixture(FIXTURE_DIR.path_join("character-index.json"))
		payload["characters"][str(ghost.get("characterId", ""))] = str(ghost.get("recordKey", ""))
		_write_text(build_dir.path_join("character-index.json"), JSON.stringify(payload, "\t"))
	if with_localization:
		_write_text(build_dir.path_join("localization.json"), _read_text(FIXTURE_DIR.path_join("localization.json")))
	# The media the characters.json assets table points at, so the import resolves the
	# stored asset ids to real files at the table's paths.
	for asset_id in _pkg_assets:
		var img := Image.create_empty(2, 2, false, Image.FORMAT_RGBA8)
		img.fill(Color(1, 1, 1, 1))
		var media_path: String = build_dir.path_join(str(_pkg_assets[asset_id].get("path", "")))
		DirAccess.make_dir_recursive_absolute(media_path.get_base_dir())
		img.save_png(media_path)


## Import one package build and install it on the manager. Returns the OUTPUT dir.
func _import_package(label: String, index_mode: String, ghost: Dictionary = {}, with_localization: bool = false) -> String:
	var build := _temp("%s/build" % label)
	var out := _temp("%s/out" % label)
	_write_package_build(build, index_mode, ghost, with_localization)
	var project = ImporterScript.new().import_project(build, out)
	_check("[setup] %s: import returned a project" % label, project != null)
	if project != null:
		_check("[setup] %s: the package script imported" % label, project.scripts.has("script"))
		_manager.set_project(project)
	return out


# =============================================================================
# Resolution runtime (read + speaker)
# =============================================================================

## One import for the whole resolution file, plus a pull-probe script: a getCharacterVar
## node per read case ("c<i>"), array-element readers per expected element ("c<i>_e<j>") and
## getMapValue readers per expected entry ("c<i>_k<j>") - evaluation is pull-based, so no
## exec wiring is needed beyond the start->dialogue park.
func _prepare_resolution_runtime(cases: Array) -> void:
	_res_out = _import_package("resolution", "verbatim")
	var nodes := {"0": Graph.start(), "D": Graph.dialogue("D")}
	var connections: Array = [Graph.exec("0", "D")]
	for idx in cases.size():
		var case: Dictionary = cases[idx]
		if str(case.get("kind", "")) != "read":
			continue
		_add_probe_nodes(nodes, connections, "c%d" % idx,
			case.get("ref", {}), case.get("variable", {}), case.get("expected", {}).get("value"))
	var script := Graph.build("probe/Resolution.sfe", nodes, connections)
	_manager.get_project().scripts[script.script_path] = script
	_res_probe = _make_component()
	_res_probe.start_dialogue_with_script(script.script_path)
	_check("[setup] resolution probe is running", _res_probe._evaluator != null)


## Add the probe reader nodes for one (ref, variable) binding under [param gid].
func _add_probe_nodes(nodes: Dictionary, connections: Array, gid: String, ref: Dictionary, variable: Dictionary, expected_value) -> void:
	nodes[gid] = Graph.node(gid, Types.NodeType.GET_CHARACTER_VAR, "getCharacterVar", _node_data(ref, variable))
	var type_token := str(variable.get("type", ""))
	if bool(variable.get("isArray", false)) and expected_value is Array:
		for j in expected_value.size():
			var gae := "%s_e%d" % [gid, j]
			nodes[gae] = Graph.node(gae, Types.NodeType.GET_STRING_ARRAY_ELEMENT, "getStringArrayElement", {"value": j})
			connections.append(Graph.data_wire(gid, "string-array", gae, Handles.IN_STRING_ARRAY))
	elif type_token == "map" and expected_value is Array:
		var kt := str(variable.get("keyType", "string"))
		var vt := str(variable.get("valueType", "string"))
		for j in expected_value.size():
			var gmv := "%s_k%d" % [gid, j]
			nodes[gmv] = Graph.node(gmv, Types.NodeType.GET_MAP_VALUE, "getMapValue",
				{"keyType": kt, "valueType": vt, "key": str(expected_value[j].get("key", ""))})
			connections.append(Graph.map_wire(gid, gmv, kt, vt, "1"))


## The wire-shape node data for one case ref + variable.
func _node_data(ref: Dictionary, variable: Dictionary) -> Dictionary:
	var data := {
		"characterPath": str(ref.get("characterPath", "")),
		"variableName": str(variable.get("name", "")),
		"variableType": str(variable.get("type", "")),
	}
	if ref.has("characterId"):
		data["characterId"] = str(ref["characterId"])
	if bool(variable.get("isArray", false)):
		data["isArray"] = true
	if variable.has("keyType"):
		data["keyType"] = str(variable["keyType"])
	if variable.has("valueType"):
		data["valueType"] = str(variable["valueType"])
	return data


## One read case: id-first through every surface, value on the resolving doors and stored on
## the stored-key doors (the A5 seats in the header). The expect_fail case runs the same
## doors and must MISMATCH.
func _run_read_case(case: Dictionary, idx: int) -> void:
	var name := str(case.get("case", "?"))
	var ref: Dictionary = case.get("ref", {})
	var variable: Dictionary = case.get("variable", {})
	var expected: Dictionary = case.get("expected", {})
	var type_token := str(variable.get("type", ""))
	var is_array := bool(variable.get("isArray", false))
	var id := str(ref.get("characterId", ""))
	var gid := "c%d" % idx
	var evaluator = _res_probe._evaluator
	_res_probe._context.clear_boolean_memo()

	if bool(case.get("expect_fail", false)):
		var resolved := evaluator.evaluate_string_from_node(gid)
		var stored: String = evaluator._evaluate_character_variable(_node_data(ref, variable), gid).get_string("")
		_check("%s: EXPECT_FAIL reported failing - id-first surfaces mismatch the path-owner expectation (resolved '%s' vs '%s', stored '%s' vs '%s')"
			% [name, resolved, str(expected.get("value")), stored, str(expected.get("stored"))],
			resolved != str(expected.get("value")) and stored != str(expected.get("stored"))
				and _manifest.get("expect_fail_cases", []).has(name))
		_expect_fail_inverted += 1
		return

	var record = _record_for_ref(ref)
	_check("%s: the ref reaches a loaded record" % name, record != null)
	if record == null:
		return

	if is_array:
		_assert_array_read(name, gid, ref, variable, expected, record, id, evaluator)
	elif type_token == "map":
		_assert_map_read(name, gid, ref, variable, expected, record, id, evaluator)
	elif type_token == "image":
		_assert_image_read(name, ref, variable, expected, record, id, evaluator)
	elif type_token in ["boolean", "integer", "float"]:
		_assert_scalar_structural_read(name, gid, ref, variable, expected, record, id, evaluator)
	else:
		_assert_string_read(name, gid, ref, variable, expected, record, id, evaluator)


func _assert_scalar_structural_read(name: String, gid: String, ref: Dictionary, variable: Dictionary, expected: Dictionary, record, id: String, evaluator) -> void:
	var var_name := str(variable.get("name", ""))
	var type_token := str(variable.get("type", ""))
	var value = expected.get("value")
	var node_value = _typed_node_read(evaluator, gid, type_token)
	_check("%s: node lane answers %s (got %s)" % [name, str(value), str(node_value)], _structural_equal(node_value, value))
	var host = _host_variant(ref, var_name)
	_check("%s: host getter answers %s (got %s)" % [name, str(value), str(_native_scalar(host, type_token))],
		host != null and _structural_equal(_native_scalar(host, type_token), value))
	if not id.is_empty():
		var da = _da_scalar_read(id, var_name, type_token)
		_check("%s: DA-surface branch answers %s (got %s)" % [name, str(value), str(da)], _structural_equal(da, value))
	_check("%s: the raw record field holds %s" % [name, str(value)],
		_structural_equal(_native_scalar(_var_of(record, var_name), type_token), value))


func _assert_string_read(name: String, gid: String, ref: Dictionary, variable: Dictionary, expected: Dictionary, record, id: String, evaluator) -> void:
	var var_name := str(variable.get("name", ""))
	var value := str(expected.get("value", ""))
	var stored := str(expected.get("stored", ""))
	var resolved := str(evaluator.evaluate_string_from_node(gid))
	_check("%s: node lane RESOLVES to '%s' (got '%s')" % [name, value, resolved], resolved == value)
	var arm: String = evaluator._evaluate_character_variable(_node_data(ref, variable), gid).get_string("")
	_check("%s: evaluator arm answers the STORED key '%s' (got '%s')" % [name, stored, arm], arm == stored)
	var host = _host_variant(ref, var_name)
	if CharacterScript.is_name_token(var_name):
		_check("%s: the public getter's Name arm resolves to '%s' (got '%s')" % [name, value, host.get_string("")],
			host != null and host.get_string("") == value)
		_check("%s: the raw record name field holds '%s'" % [name, stored], record.character_name == stored)
	else:
		_check("%s: the public getter answers the stored key '%s' (got '%s')" % [name, stored, host.get_string("") if host else "<null>"],
			host != null and host.get_string("") == stored)
		_check("%s: the raw record row holds '%s'" % [name, stored], _var_of(record, var_name).get_string("") == stored)
	if not id.is_empty():
		var da := _res_probe.get_data_asset_string(id, var_name, "<miss>")
		_check("%s: DA-surface branch answers the stored key '%s' (got '%s')" % [name, stored, da], da == stored)


func _assert_image_read(name: String, ref: Dictionary, variable: Dictionary, expected: Dictionary, record, id: String, evaluator) -> void:
	var var_name := str(variable.get("name", ""))
	var value := str(expected.get("value", ""))
	var stored := str(expected.get("stored", ""))
	var arm: String = evaluator._evaluate_character_variable(_node_data(ref, variable), "").get_string("")
	_check("%s: evaluator arm answers the stored asset id '%s' (got '%s')" % [name, stored, arm], arm == stored)
	var host = _host_variant(ref, var_name)
	_check("%s: the public getter answers the stored asset id '%s'" % [name, stored],
		host != null and host.get_string("") == stored)
	_check("%s: the raw record image field holds '%s'" % [name, stored], record.image_key == stored)
	if not id.is_empty():
		var da := _res_probe.get_data_asset_string(id, var_name, "<miss>")
		_check("%s: DA-surface branch answers the stored asset id '%s' (got '%s')" % [name, stored, da], da == stored)
	# The `value` half: the assets table maps the stored id to exactly this path, the import
	# published the media at that path, and the engine resolves the id to a real texture.
	_check("%s: the assets table maps '%s' -> '%s'" % [name, stored, value],
		str(_pkg_assets.get(stored, {}).get("path", "")) == value)
	_check("%s: the import published the media at '%s'" % [name, value],
		FileAccess.file_exists(_res_out.path_join(value)))
	_check("%s: the portrait resolves through the stored id" % name,
		_res_probe.get_character_portrait(record.character_path) != null)


func _assert_array_read(name: String, gid: String, ref: Dictionary, variable: Dictionary, expected: Dictionary, record, id: String, evaluator) -> void:
	var var_name := str(variable.get("name", ""))
	var value: Array = expected.get("value", [])
	var stored: Array = expected.get("stored", [])
	var arm = evaluator._evaluate_character_variable(_node_data(ref, variable), gid)
	var arm_native := _strings_of(arm.get_array())
	_check("%s: evaluator arm answers the stored elements %s (got %s)" % [name, str(stored), str(arm_native)],
		_structural_equal(arm_native, stored))
	_check("%s: element count matches (%d)" % [name, value.size()], arm.get_array().size() == value.size())
	for j in value.size():
		var element := str(evaluator.evaluate_string_from_node("%s_e%d" % [gid, j]))
		_check("%s: node lane resolves element %d to '%s' (got '%s')" % [name, j, str(value[j]), element],
			element == str(value[j]))
	var host = _host_variant(ref, var_name)
	_check("%s: the public getter answers the stored elements" % name,
		host != null and _structural_equal(_strings_of(host.get_array()), stored))
	_check("%s: the raw record row holds the stored elements" % name,
		_structural_equal(_strings_of(_var_of(record, var_name).get_array()), stored))
	if not id.is_empty():
		var da = _res_probe.get_data_asset_variant(id, var_name)
		_check("%s: DA-surface variant door answers the stored elements" % name,
			da != null and _structural_equal(_strings_of(da.get_array()), stored))


func _assert_map_read(name: String, gid: String, ref: Dictionary, variable: Dictionary, expected: Dictionary, record, id: String, evaluator) -> void:
	var var_name := str(variable.get("name", ""))
	var value: Array = expected.get("value", [])
	var stored: Array = expected.get("stored", [])
	var arm = evaluator._evaluate_character_variable(_node_data(ref, variable), gid)
	var arm_entries := _entries_of(arm.get_map())
	_check("%s: evaluator arm answers the stored entry list %s (got %s)" % [name, str(stored), str(arm_entries)],
		_structural_equal(arm_entries, stored))
	_check("%s: entry ORDER matches the expectation" % name,
		_keys_of(arm_entries) == _keys_of(value) and arm_entries.size() == value.size())
	for j in value.size():
		var entry_value := str(evaluator.evaluate_string_from_node("%s_k%d" % [gid, j]))
		_check("%s: node lane resolves entry '%s' to '%s' (got '%s')" % [name, str(value[j].get("key")), str(value[j].get("value")), entry_value],
			entry_value == str(value[j].get("value")))
	var host = _host_variant(ref, var_name)
	_check("%s: the public getter answers the stored entry list" % name,
		host != null and _structural_equal(_entries_of(host.get_map()), stored))
	_check("%s: the raw record row holds the stored entry list" % name,
		_structural_equal(_entries_of(_var_of(record, var_name).get_map()), stored))
	if not id.is_empty():
		var da = _res_probe.get_data_asset_variant(id, var_name)
		_check("%s: DA-surface variant door answers the stored entry list" % name,
			da != null and _structural_equal(_entries_of(da.get_map()), stored))


## One speaker case: a real dialogue whose node carries the case's character/characterRefId
## pair; the rendered state must serve the ID-owner's resolved name, the raw record must hold
## the stored keys, and the bridge must map the ref id to the expected record key.
func _run_speaker_case(case: Dictionary) -> void:
	var name := str(case.get("case", "?"))
	var ref: Dictionary = case.get("ref", {})
	var expected: Dictionary = case.get("expected", {})
	var record_key := str(expected.get("recordKey", ""))
	var exp_name: Dictionary = expected.get("name", {})
	var exp_image: Dictionary = expected.get("image", {})
	var ref_id := str(ref.get("characterRefId", ref.get("characterId", "")))

	_probe_seq += 1
	var path := "probe/Speaker%d.sfe" % _probe_seq
	var script := Graph.build(path, {
		"0": Graph.start(),
		"D": Graph.node("D", Types.NodeType.DIALOGUE, "dialogue", {
			"title": "", "text": "t",
			"character": str(ref.get("character", ref.get("characterPath", ""))),
			"characterRefId": ref_id,
		}),
	}, [Graph.exec("0", "D")])
	_manager.get_project().scripts[path] = script
	var component := _make_component()
	component.start_dialogue_with_script(path)
	var state = component._context.current_dialogue_state
	_check("%s: the dialogue rendered a speaker" % name, state != null and state.character != null)
	if state != null and state.character != null:
		_check("%s: the speaker name RESOLVES to '%s' (got '%s')" % [name, str(exp_name.get("value")), state.character.name],
			state.character.name == str(exp_name.get("value")))
		_check("%s: the portrait resolved to a real texture" % name, state.character.image != null)
	_check("%s: the bridge maps the ref id to '%s'" % [name, record_key],
		component.get_character_path_by_id(ref_id) == record_key)
	var record = _manager.get_runtime_characters().get(record_key)
	_check("%s: the expected record is loaded" % name, record != null)
	if record != null:
		_check("%s: the record stores the name key '%s' (got '%s')" % [name, str(exp_name.get("stored")), record.character_name],
			record.character_name == str(exp_name.get("stored")))
		_check("%s: the record stores the asset id '%s' (got '%s')" % [name, str(exp_image.get("storedAssetId")), record.image_key],
			record.image_key == str(exp_image.get("storedAssetId")))
	_check("%s: the assets table maps the stored id to '%s'" % [name, str(exp_image.get("value"))],
		str(_pkg_assets.get(str(exp_image.get("storedAssetId")), {}).get("path", "")) == str(exp_image.get("value")))
	_teardown(component)


# =============================================================================
# Writes runtime (write + sweep + save, ONE runtime, replayed in order)
# =============================================================================

## Fresh import for the ordered replay, plus a pull-probe holding a reader node per
## node-surface read ("w<i>_r<j>") and per sweep resolution ("s<j>", with element/entry
## readers) - values are read live at evaluation time, so building the probe up front is
## safe and the writes land before their reads run.
func _prepare_writes_runtime(cases: Array) -> void:
	# The resolution probe's dialogue ends here: the writes replay owns the manager from now
	# on, and the save case's load_from_slot refuses while any dialogue is active.
	if _res_probe != null:
		_teardown(_res_probe)
		_res_probe = null
	_wr_out = _import_package("writes", "verbatim")
	var nodes := {"0": Graph.start(), "D": Graph.dialogue("D")}
	var connections: Array = [Graph.exec("0", "D")]
	for idx in cases.size():
		var case: Dictionary = cases[idx]
		var kind := str(case.get("kind", ""))
		if kind == "write":
			var variable: Dictionary = case.get("write", {}).get("variable", {})
			var reads: Array = case.get("reads", [])
			for j in reads.size():
				var read: Dictionary = reads[j]
				if str(read.get("surface", "")) != "node":
					continue
				var expected = read.get("expected")
				_add_probe_nodes(nodes, connections, "w%d_r%d" % [idx, j], read.get("ref", {}), variable, expected)
		elif kind == "sweep":
			var resolutions: Array = case.get("resolutions", [])
			for j in resolutions.size():
				var resolution: Dictionary = resolutions[j]
				_add_probe_nodes(nodes, connections, "s%d" % j,
					{"characterId": resolution.get("characterId", "")},
					resolution.get("variable", {}), resolution.get("value"))
	var script := Graph.build("probe/Writes.sfe", nodes, connections)
	_manager.get_project().scripts[script.script_path] = script
	_wr_probe = _make_component()
	_wr_probe.start_dialogue_with_script(script.script_path)
	_check("[setup] writes probe is running", _wr_probe._evaluator != null)


func _run_write_case(case: Dictionary, idx: int) -> void:
	var name := str(case.get("case", "?"))
	var write: Dictionary = case.get("write", {})
	var variable: Dictionary = write.get("variable", {})
	var surface := str(write.get("surface", ""))
	var ref: Dictionary = write.get("ref", {})

	if surface == "node":
		_run_node_write("w%d" % idx, ref, variable, write.get("value"))
		_check("%s: the node-lane write executed" % name, true)
	elif surface == "host":
		var minted := _mint(variable, write.get("value"))
		if ref.has("characterId"):
			_check("%s: the host ById write lands" % name,
				_wr_probe.set_character_variable_by_id(str(ref["characterId"]), str(variable.get("name", "")), minted))
		else:
			_wr_probe.set_character_variable(str(ref.get("characterPath", "")), str(variable.get("name", "")), minted)
			_check("%s: the host path write executed" % name, true)
	else:
		_check("%s: write surface '%s' is known" % [name, surface], false)
		return

	var reads: Array = case.get("reads", [])
	for j in reads.size():
		_assert_write_read(name, case, idx, j)
	_check("%s: asserted every listed read (%d)" % [name, reads.size()], reads.size() > 0)


func _assert_write_read(name: String, case: Dictionary, idx: int, j: int) -> void:
	var variable: Dictionary = case.get("write", {}).get("variable", {})
	var read: Dictionary = case.get("reads", [])[j]
	var surface := str(read.get("surface", ""))
	var expected = read.get("expected")
	var var_name := str(variable.get("name", ""))
	_wr_probe._context.clear_boolean_memo()

	if surface == "node":
		var actual = _typed_node_native(_wr_probe._evaluator, "w%d_r%d" % [idx, j], read.get("ref", {}), variable)
		_check("%s: node surface reads back %s (got %s)" % [name, str(expected), str(actual)],
			_structural_equal(actual, expected))
	elif surface == "host":
		var host = _host_variant(read.get("ref", {}), var_name)
		var actual = _native_of(host, variable) if host != null else null
		_check("%s: host surface reads back %s (got %s)" % [name, str(expected), str(actual)],
			host != null and _structural_equal(actual, expected))
	elif surface == "speaker":
		_probe_seq += 1
		var path := "probe/WriteSpeaker%d.sfe" % _probe_seq
		var script := Graph.build(path, {
			"0": Graph.start(),
			"D": Graph.node("D", Types.NodeType.DIALOGUE, "dialogue", {
				"title": "", "text": "t", "character": "",
				"characterRefId": str(read.get("ref", {}).get("characterId", "")),
			}),
		}, [Graph.exec("0", "D")])
		_manager.get_project().scripts[path] = script
		var component := _make_component()
		component.start_dialogue_with_script(path)
		var state = component._context.current_dialogue_state
		_check("%s: speaker surface serves '%s' (got '%s')" % [name, str(expected), state.character.name if state and state.character else "<none>"],
			state != null and state.character != null and state.character.name == str(expected))
		_teardown(component)
	else:
		_check("%s: read surface '%s' is known" % [name, surface], false)


## Replay one node-lane write through a REAL setCharacterVar execution.
func _run_node_write(label: String, ref: Dictionary, variable: Dictionary, raw_value) -> void:
	var data := _node_data(ref, variable)
	var nodes := {"0": Graph.start(), "D": Graph.dialogue("D")}
	var connections: Array = []
	var variables: Dictionary = {}
	if str(variable.get("type", "")) == "map":
		var entries: Dictionary = {}
		if raw_value is Array:
			for entry in raw_value:
				entries[str(entry.get("key", ""))] = VariantScript.from_string(str(entry.get("value", "")))
		variables["src"] = Graph.map_var("src", "src", entries)
		nodes["GSRC"] = Graph.node("GSRC", Types.NodeType.GET_MAP, "getMap",
			{"variable": "src", "isGlobal": false, "keyType": str(variable.get("keyType", "string")), "valueType": str(variable.get("valueType", "string"))})
		connections.append(Graph.map_wire("GSRC", "W",
			str(variable.get("keyType", "string")), str(variable.get("valueType", "string")), "input"))
	else:
		data["value"] = _mint(variable, raw_value)
	nodes["W"] = Graph.node("W", Types.NodeType.SET_CHARACTER_VAR, "setCharacterVar", data)
	connections.append(Graph.exec("0", "W"))
	connections.append(Graph.exec_flow("W", "D"))
	var script := Graph.build("probe/%s.sfe" % label, nodes, connections, variables)
	_manager.get_project().scripts[script.script_path] = script
	var runner := _make_component()
	runner.start_dialogue_with_script(script.script_path)
	_teardown(runner)


## The post-write sweep: the full resolution table, on the node lane's resolving readers and
## on the host ById getter (custom string-family values resolved through the engine's one
## string chokepoint, since this engine's host getter answers stored keys - the A5 seats).
func _run_sweep_case(case: Dictionary, _idx: int) -> void:
	var name := str(case.get("case", "?"))
	var resolutions: Array = case.get("resolutions", [])
	_check("%s: the sweep carries resolutions" % name, not resolutions.is_empty())
	var evaluator = _wr_probe._evaluator
	for j in resolutions.size():
		var resolution: Dictionary = resolutions[j]
		var variable: Dictionary = resolution.get("variable", {})
		var id := str(resolution.get("characterId", ""))
		var value = resolution.get("value")
		var var_name := str(variable.get("name", ""))
		var type_token := str(variable.get("type", ""))
		var entry_label := "%s[%d] %s.%s" % [name, j, id.substr(0, 10), var_name]
		_wr_probe._context.clear_boolean_memo()

		# Node lane, resolving.
		if bool(variable.get("isArray", false)) and value is Array:
			var arm = evaluator._evaluate_character_variable(_node_data({"characterId": id}, variable), "s%d" % j)
			_check("%s: node element count %d" % [entry_label, value.size()], arm.get_array().size() == value.size())
			for k in value.size():
				var element := str(evaluator.evaluate_string_from_node("s%d_e%d" % [j, k]))
				_check("%s: node element %d = '%s' (got '%s')" % [entry_label, k, str(value[k]), element], element == str(value[k]))
		elif type_token == "map" and value is Array:
			var arm = evaluator._evaluate_character_variable(_node_data({"characterId": id}, variable), "s%d" % j)
			var arm_entries := _entries_of(arm.get_map())
			_check("%s: node entry order %s (got %s)" % [entry_label, str(_keys_of(value)), str(_keys_of(arm_entries))],
				_keys_of(arm_entries) == _keys_of(value) and arm_entries.size() == value.size())
			for k in value.size():
				var entry_value := str(evaluator.evaluate_string_from_node("s%d_k%d" % [j, k]))
				_check("%s: node entry '%s' = '%s' (got '%s')" % [entry_label, str(value[k].get("key")), str(value[k].get("value")), entry_value],
					entry_value == str(value[k].get("value")))
		else:
			var node_value = _typed_node_read(evaluator, "s%d" % j, type_token)
			_check("%s: node lane answers %s (got %s)" % [entry_label, str(value), str(node_value)],
				_structural_equal(node_value, value))

		# Host lane: the ById getter, string leaves resolved through _resolve_string_key.
		var host = _wr_probe.get_character_variable_by_id(id, var_name)
		var host_native = _resolved_native(_native_of(host, variable), evaluator) if host != null else null
		_check("%s: host lane answers %s (got %s)" % [entry_label, str(value), str(host_native)],
			host != null and _structural_equal(host_native, value))
	_check("%s: swept every resolution (%d)" % [name, resolutions.size()], resolutions.size() > 0)


## The save double-capture, through the REAL save_to_slot/load_from_slot: the characters
## section matches the reference shape structurally (this engine's stored keys mapped
## through the package's strings/assets tables, per A5's save invariant), and the dataAssets
## key is empty of characters - empty outright here, since the replay wrote no data assets.
func _run_save_case(case: Dictionary) -> void:
	var name := str(case.get("case", "?"))
	_check("%s: save_to_slot writes" % name, _manager.save_to_slot(SAVE_SLOT))
	var doc := _read_save_doc()
	_check("%s: the save parsed" % name, not doc.is_empty())

	var expected_chars: Dictionary = case.get("saveCharacters", {})
	var actual_chars: Dictionary = doc.get("characters", {})
	var expected_keys: Array = expected_chars.keys()
	expected_keys.sort()
	var actual_keys: Array = actual_chars.keys()
	actual_keys.sort()
	_check("%s: the characters section carries exactly the expected records (got %s)" % [name, str(actual_keys)],
		actual_keys == expected_keys)

	for record_key in expected_chars:
		var expected_record: Dictionary = expected_chars[record_key]
		var actual_record: Dictionary = actual_chars.get(record_key, {})
		var label := "%s: %s" % [name, str(record_key)]
		_check("%s name '%s' (stored '%s')" % [label, str(expected_record.get("name")), str(actual_record.get("name"))],
			_resolve_pkg_string(str(actual_record.get("name", ""))) == str(expected_record.get("name", "")))
		_check("%s image '%s' (stored '%s')" % [label, str(expected_record.get("image")), str(actual_record.get("image"))],
			_resolve_pkg_asset(str(actual_record.get("image", ""))) == str(expected_record.get("image", "")))
		var expected_vars: Dictionary = expected_record.get("variables", {})
		var actual_vars: Dictionary = actual_record.get("variables", {})
		var expected_var_names: Array = expected_vars.keys()
		expected_var_names.sort()
		var actual_var_names: Array = actual_vars.keys()
		actual_var_names.sort()
		_check("%s declares exactly the expected variables (got %s)" % [label, str(actual_var_names)],
			actual_var_names == expected_var_names)
		for vname in expected_vars:
			var row: Dictionary = actual_vars.get(vname, {})
			var actual_value = _resolve_save_row_value(row)
			_check("%s.%s = %s (got %s)" % [label, str(vname), str(expected_vars[vname]), str(actual_value)],
				_structural_equal(actual_value, expected_vars[vname]))

	var data_assets = doc.get("dataAssets")
	_check("%s: the dataAssets key is present and CHARACTERLESS (structural %s, got %s)" % [name, str(case.get("saveDataAssets")), str(data_assets)],
		data_assets is Dictionary and _structural_equal_dicts(data_assets, case.get("saveDataAssets", {})))

	# The load half of the real path: disturb a written value, load, and the id lane reads
	# the save back. The probe's dialogue must end first - load refuses while one is active.
	_check("%s: disturb before load" % name,
		_wr_probe.set_character_variable_by_id("da_hero0000000000000000000000000a", "Coins", VariantScript.from_int(1)))
	_wr_probe.stop_dialogue()
	_check("%s: load_from_slot restores" % name, _manager.load_from_slot(SAVE_SLOT))
	var coins := _wr_probe.get_character_variable_by_id("da_hero0000000000000000000000000a", "Coins").get_int(-1)
	_check("%s: the loaded save serves the replayed value (got %d)" % [name, coins], coins == 777)
	_teardown(_wr_probe)
	_wr_probe = null


# =============================================================================
# Degraded ladder (one isolated freshly-seeded store per case)
# =============================================================================

func _run_degraded_case(case: Dictionary, idx: int) -> void:
	var name := str(case.get("case", "?"))
	var ref: Dictionary = case.get("ref", {})
	var variable: Dictionary = case.get("variable", {})
	var var_name := str(variable.get("name", ""))
	var type_token := str(variable.get("type", ""))
	var mutation := str(case.get("seedMutation", ""))
	var wired: Dictionary = case.get("wired", {})

	var index_mode := "verbatim"
	if mutation == "inject-ghost-index-entry":
		index_mode = "ghost"
	elif mutation == "no-index":
		index_mode = "none"
	_import_package("deg%d" % idx, index_mode, case.get("ghost", {}))
	if mutation == "no-index":
		_check("%s: the no-index build leaves the bridge empty" % name, _manager.get_character_id_bridge().is_empty())

	# The per-case probe: a reader node "g" (wired when the case says so) plus a park.
	var nodes := {"0": Graph.start(), "D": Graph.dialogue("D")}
	var connections: Array = [Graph.exec("0", "D")]
	var variables: Dictionary = {}
	var read_variable := variable.duplicate()
	if case.has("set") and case.get("set", {}).has("postRead") and case.get("set", {}).get("outcome") == "refused":
		# The type-mismatch case: the postRead reads the DECLARED string value.
		read_variable["type"] = "string"
	nodes["g"] = Graph.node("g", Types.NodeType.GET_CHARACTER_VAR, "getCharacterVar", _node_data(ref, read_variable))
	if not wired.is_empty():
		variables["who"] = Graph.scalar_var("who", "who", Types.VariableType.STRING,
			VariantScript.from_string(str(wired.get("characterRef", ""))))
		nodes["WHO"] = Graph.node("WHO", Types.NodeType.GET_STRING, "getString", {"variable": "who", "isGlobal": false})
		connections.append(Graph.data_wire("WHO", "string", "g", Handles.IN_CHARACTER_INPUT))
	var probe_script := Graph.build("probe/Deg%d.sfe" % idx, nodes, connections, variables)
	_manager.get_project().scripts[probe_script.script_path] = probe_script
	var probe := _make_component()
	probe.start_dialogue_with_script(probe_script.script_path)
	var evaluator = probe._evaluator

	if case.has("get"):
		var get_spec: Dictionary = case.get("get", {})
		var expected = get_spec.get("value")
		var actual = _degraded_node_read(evaluator, "g", ref, read_variable)
		_check("%s: get outcome '%s' answers %s (got %s)" % [name, str(get_spec.get("outcome")), str(expected), str(actual)],
			_structural_equal(actual, expected))

	if case.has("set"):
		var set_spec: Dictionary = case.get("set", {})
		var outcome := str(set_spec.get("outcome", ""))
		if outcome == "refused":
			var pre_record = _record_for_ref(ref)
			var pre_count: int = pre_record.variables.size() if pre_record != null else -1
			if set_spec.has("postRead"):
				# The node-snapshot type mismatch: replay the REAL node write, then the
				# declared value must still answer.
				_run_node_write("deg%d_w" % idx, ref, variable, set_spec.get("value"))
				probe._context.clear_boolean_memo()
				var post := str(evaluator.evaluate_string_from_node("g"))
				_check("%s: the mismatched node write refused - postRead '%s' (got '%s')" % [name, str(set_spec.get("postRead")), post],
					post == str(set_spec.get("postRead")))
			else:
				var minted := _mint(variable, set_spec.get("value"))
				_check("%s: the ById write refuses (false)" % name,
					not probe.set_character_variable_by_id(str(ref.get("characterId", "")), var_name, minted))
			if case.has("postCondition"):
				var record = _record_for_ref(ref)
				_check("%s: %s (still %d of %d declared, no '%s')" % [name, str(case.get("postCondition")), record.variables.size(), pre_count, var_name],
					record != null and record.variables.size() == pre_count and not record.variables.has(var_name))
		elif outcome == "written":
			var target_ref := ref
			if not wired.is_empty():
				_run_wired_node_write("deg%d_w" % idx, ref, variable, set_spec.get("value"), str(wired.get("characterRef", "")))
				target_ref = {"characterId": str(wired.get("characterRef", ""))}
			else:
				_run_node_write("deg%d_w" % idx, ref, variable, set_spec.get("value"))
			probe._context.clear_boolean_memo()
			var post = _degraded_node_read_by_ref(evaluator, target_ref, variable)
			_check("%s: the write landed - postRead %s (got %s)" % [name, str(set_spec.get("postRead")), str(post)],
				_structural_equal(post, set_spec.get("postRead")))
		else:
			_check("%s: set outcome '%s' is known" % [name, outcome], false)

	_teardown(probe)


## A degraded-case node read through the probe's "g" reader (wired cases included).
func _degraded_node_read(evaluator, gid: String, ref: Dictionary, variable: Dictionary):
	var type_token := str(variable.get("type", ""))
	if bool(variable.get("isArray", false)):
		return _strings_of(evaluator._evaluate_character_variable(_node_data(ref, variable), gid).get_array())
	if type_token == "map":
		return _entries_of(evaluator._evaluate_character_variable(_node_data(ref, variable), gid).get_map())
	return _typed_node_read(evaluator, gid, type_token)


## A post-write node read straight through the evaluator arm for [param ref] (used where the
## probe's reader is bound to a different ref, e.g. the wired write's target).
func _degraded_node_read_by_ref(evaluator, ref: Dictionary, variable: Dictionary):
	var variant = evaluator._evaluate_character_variable(_node_data(ref, variable), "")
	return _native_of(variant, variable)


## The wired write: the SCV node's inline binding stays dangling while the wire hands over
## the target - the write must land on the WIRED character.
func _run_wired_node_write(label: String, ref: Dictionary, variable: Dictionary, raw_value, wired_ref: String) -> void:
	var data := _node_data(ref, variable)
	data["value"] = _mint(variable, raw_value)
	var script := Graph.build("probe/%s.sfe" % label, {
		"0": Graph.start(),
		"WHO": Graph.node("WHO", Types.NodeType.GET_STRING, "getString", {"variable": "who", "isGlobal": false}),
		"W": Graph.node("W", Types.NodeType.SET_CHARACTER_VAR, "setCharacterVar", data),
		"D": Graph.dialogue("D"),
	}, [
		Graph.exec("0", "W"), Graph.exec_flow("W", "D"),
		Graph.data_wire("WHO", "string", "W", Handles.IN_CHARACTER_INPUT),
	], {
		"who": Graph.scalar_var("who", "who", Types.VariableType.STRING, VariantScript.from_string(wired_ref)),
	})
	_manager.get_project().scripts[script.script_path] = script
	var runner := _make_component()
	runner.start_dialogue_with_script(script.script_path)
	_teardown(runner)


# =============================================================================
# Localization arm (spec §9: localized / language-table / source-only)
# =============================================================================

## ONE import of the package build WITH its localization.json, plus the sidecar's own tables as
## DATA (the tripwire asserts the resolve equals the OLD translation the sidecar carries) and the
## outside-dialogue component every characters.json-keyed case cross-checks through.
func _prepare_localization_runtime(cases: Array) -> void:
	_import_package("localization", "verbatim", {}, true)
	_loc_project = _manager.get_project()
	_pkg_localization = _load_fixture(FIXTURE_DIR.path_join("localization.json"))
	_check("[setup] localization: the sidecar build imports as a LOCALIZED project",
		_loc_project != null and _loc_project.has_localization)
	_check("[setup] localization: the roster is the source language plus the author's registry (got %d)"
		% _manager.get_languages().size(), _manager.get_languages().size() == 3)
	_check("[setup] localization: a fresh import starts in the project's source language (got '%s')"
		% _manager.get_language(), _manager.get_language() == "en")
	_loc_outside = _make_component()

	# THE `.sfd` DOORS, prepared from the cases themselves: one probe accessor per (asset,
	# variable) an `unkeyed` case names, so the node lane can be asked the same question the host
	# accessors are. The manifest is explicit that a harness which byte-copies a value out of
	# data-assets.json proves nothing about the door where the mistake is made.
	_pkg_data_assets = _load_fixture(FIXTURE_DIR.path_join("data-assets.json"))
	_loc_doors = Doors.new()
	_loc_doors.doc = _pkg_data_assets
	var targets: Array = []
	for case in cases:
		if str(case.get("kind", "")) == "unkeyed":
			targets.append({"assetId": str(case.get("dataAssetId", "")), "variableId": str(case.get("variableId", ""))})
	if targets.is_empty():
		return
	var probe = _loc_doors.probe_script("probe/Unkeyed.sfe", targets)
	_loc_project.scripts[probe.script_path] = probe
	_loc_probe = _make_component()
	_loc_probe.start_dialogue_with_script(probe.script_path)
	_check("[setup] localization: the .sfd probe graph is running", _loc_probe._evaluator != null)
	_loc_doors.component = _loc_probe


## THE NODE-LANE DOOR: the evaluator's _resolve_string_key, which is where every string-typed
## value in this engine - a dialogue field's key, a character variable's stored key, an array
## element, a map entry value - is turned into text. Built standalone (a context plus an
## evaluator) rather than driven through a running graph so the id under test is the ONLY input.
##
## The language is NOT passed in: it comes from the manager through the context's localization
## reference, because that is who owns it once the project ships a sidecar. A case selects a
## language by calling set_language, exactly as a game does. [param fallback_language] is the
## PRE-LOCALIZATION code, which only matters to the source-only case.
func _localized_resolve_in(project, script, string_id: String, fallback_language: String) -> String:
	var ctx := ContextScript.new()
	ctx.current_script = script
	ctx.localization = _manager.get_localization()
	var evaluator := EvaluatorScript.new()
	evaluator.initialize(ctx, {}, {}, fallback_language, project.global_strings)
	return evaluator._resolve_string_key(string_id)


## The node-lane door against the package's own imported project and its one script.
func _localized_resolve(string_id: String) -> String:
	var project = _manager.get_project()
	return _localized_resolve_in(project, project.get_storyflow_script("script"), string_id, "en")


## THE REACH RULE. Read the named character's named variable and take THE KEY IT STORES - never
## rebuild the id from the character being read. The public ById getter answers stored values
## verbatim for a non-name string variable (the §5 seat map), which is exactly the pre-resolution
## record the rule asks to be followed: read it, cross-check it against the case's storedKey, then
## USE WHAT WAS READ.
##
## An inherited value's key names the DECLARING ANCESTOR, so an implementation that composes
## `<characterBeingRead>.<variableId>.value` produces an id nothing carries, passes every
## non-inherited case, and resolves this one to the raw id.
func _localized_string_id(case: Dictionary, name: String) -> String:
	if not case.has("reach"):
		return str(case.get("stringId", ""))
	var reach: Dictionary = case["reach"]
	var stored: StoryFlowVariant = _loc_outside.get_character_variable_by_id(
		str(reach.get("characterId", "")), str(reach.get("variableName", "")))
	var followed := stored.get_string("") if stored != null else ""
	_check("%s: the character record stores the ancestor-owned key '%s' (got '%s')"
		% [name, str(reach.get("storedKey", "")), followed],
		followed == str(reach.get("storedKey", "")))
	return followed


## One (language, stringId) expectation, through the node lane - and, for a characters.json-keyed
## id, through the OUTSIDE-dialogue door as well, which is what proves the two doors run one
## shared ladder and cannot come apart.
func _run_localized_case(case: Dictionary) -> void:
	var name := str(case.get("case", "?"))
	var language := str(case.get("language", ""))
	var expected := str(case.get("expected", ""))
	var string_id := _localized_string_id(case, name)

	_check("%s: the language the case names is settable" % name, _manager.set_language(language))
	var resolved := _localized_resolve(string_id)

	if bool(case.get("expect_fail", false)):
		_run_localized_expect_fail(case, name, language, expected, string_id, resolved)
		return

	_check("%s: %s['%s'] resolves to '%s' (got '%s')" % [name, language, string_id, expected, resolved],
		resolved == expected)
	# NEVER null and never an accidental empty string - the shape the whole contract rests on,
	# asserted per case rather than once.
	_check("%s: the resolve is never empty" % name, not resolved.is_empty())

	if str(case.get("keyedIn", "")) == "characters.json":
		var outside := _loc_outside.get_localized_string(string_id)
		_check("%s: the outside-dialogue door agrees (got '%s')" % [name, outside], outside == expected)


## INVERTED: this case's `expected` is the CURRENT SOURCE of an outdated row, which is what an
## engine that recomputes status produces. Ruling 2 says the OLD translation ships, so reporting
## this case as passing would prove exactly that defect.
##
## THREE assertions, not one: a mismatch alone would also be satisfied by resolving to the raw id
## or to some third string, and each of those is a different silent defect. The resolve must miss
## in the ONE direction the ruling names - by shipping the OLD translation the sidecar carries.
func _run_localized_expect_fail(case: Dictionary, name: String, language: String, expected: String, string_id: String, resolved: String) -> void:
	_check("%s: EXPECT_FAIL reported failing - the deliberately wrong current source '%s' is not what resolved (got '%s')"
		% [name, expected, resolved],
		resolved != expected and _manifest.get("expect_fail_cases", []).has(name))
	var table = _pkg_localization.get("strings", {}).get(language, {})
	var sidecar_row := str(table.get(string_id, "<no row>"))
	_check("%s: it misses by shipping the OLD translation the sidecar carries ('%s', got '%s')"
		% [name, sidecar_row, resolved], resolved == sidecar_row)
	_check("%s: and not by falling through to the raw id" % name, resolved != string_id)
	_expect_fail_inverted += 1


## THE `unkeyed` KIND (spec §2's amendment of 2026-08-27): a `.sfd` value that ships LITERAL,
## driven through THIS ENGINE'S OWN data-asset accessors once per language.
##
## The manifest is explicit that a harness which only byte-copies the value out of data-assets.json
## proves nothing, and it is right: every `.sfd` rule is about THE ID A READ DOOR REACHES A TABLE
## WITH, and a byte comparison never gets near that door. So this reads the bytes (a drifted
## literal is a stale case, not a passing one), then asks the REAL doors — both of them, required
## to agree — then checks the absence, then, where the case carries a `collidesWith`, resolves the
## id a WRONG implementation would have built and confirms the doors did not answer with it.
##
## THAT LAST STEP IS WHAT MAKES THE OVERRIDE CASE TEETH RATHER THAN DECORATION in principle. In
## THIS engine it still cannot fail, and the reason is written out in full at
## tests/test_data_asset_localization.gd's _test_key_shaped_override: this plugin never BUILDS an
## id, it resolves the bytes the exporter wrote, and the package's override stores ordinary prose,
## which keys nothing. The engine-owned test carries the bytes that do bite.
func _run_unkeyed_case(case: Dictionary) -> void:
	var name := str(case.get("case", "?"))
	var asset_id := str(case.get("dataAssetId", ""))
	var variable_id := str(case.get("variableId", ""))
	var literal := str(case.get("literal", ""))
	var expected: Dictionary = case.get("expected", {})

	# 1. THE BYTES, where `from` says an engine reads them.
	var stored: String = _loc_doors.stored_bytes(asset_id, variable_id, str(case.get("from", "")))
	_check("%s: the artifact still carries this literal ('%s', got '%s')" % [name, literal, stored],
		stored == literal)

	# 2. THE DOORS, once per language the case names. The language is the manager's and a `.sfd`
	#    value resolves at READ time, which is exactly what makes driving the doors per language
	#    mean something.
	for language in expected:
		var text := str(expected[language])
		_check("%s: the case expects the literal in %s" % [name, language], text == literal)
		_check("%s: the language %s is settable" % [name, language], _manager.set_language(str(language)))

		var result: Dictionary = _loc_doors.read(asset_id, variable_id)
		_check("%s: %s.%s answers on both .sfd doors, which agree" % [name, asset_id, variable_id],
			result["host"] != null and result["node"] != null and result["agree"])
		_check("%s: the accessor answers the literal in %s (got '%s')" % [name, language, result["text"]],
			result["text"] == text)

		# 4. THE TEETH. The id a walker of overrides would have built resolves to somebody ELSE's
		#    prose in this language, and the door did not hand that back.
		if case.has("collidesWith"):
			var collides: Dictionary = case["collidesWith"]
			var colliding_id := str(collides.get("stringId", ""))
			var colliding_text := str(collides.get("resolved", {}).get(language, ""))
			_check("%s: %s resolves the colliding id '%s' to '%s'" % [name, language, colliding_id, colliding_text],
				_localized_resolve(colliding_id) == colliding_text)
			_check("%s: the collision is real in %s, so the case has teeth" % [name, language],
				colliding_text != literal)
			_check("%s: the accessor did NOT serve the colliding text in %s" % [name, language],
				result["text"] != colliding_text)

	# 3. THE ABSENCE, which IS the contract: no table anywhere keys an id an implementation might
	#    have minted for this value. The raw-fallback tier answers an unkeyed id with ITSELF, so
	#    "resolves to itself" is how a total lookup says "nothing keys this".
	for absent_id in case.get("absentIds", []):
		for language in _pkg_localization.get("strings", {}):
			var table: Dictionary = _pkg_localization["strings"][language]
			_check("%s: the %s table carries no row for '%s'" % [name, language, str(absent_id)],
				not table.has(str(absent_id)))
		_manager.set_language("fr")
		_check("%s: '%s' keys no artifact either" % [name, str(absent_id)],
			_localized_resolve(str(absent_id)) == str(absent_id))


## The COMPLETE resolved table for one language: every id the export shipped, so an implementation
## cannot pass by covering only the named cases.
func _run_language_table_case(case: Dictionary) -> void:
	var name := str(case.get("case", "?"))
	var language := str(case.get("language", ""))
	var expected: Dictionary = case.get("expected", {})
	_check("%s: the language the case names is settable" % name, _manager.set_language(language))
	_check("%s: the table carried rows to compare" % name, not expected.is_empty())
	for string_id in expected:
		var resolved := _localized_resolve(str(string_id))
		_check("%s: %s['%s'] resolves to '%s' (got '%s')" % [name, language, str(string_id), str(expected[string_id]), resolved],
			resolved == str(expected[string_id]))
		_check("%s: the resolve is never empty for '%s'" % [name, str(string_id)], not resolved.is_empty())


## THE ABSENCE BRANCH, against a SECOND project imported from a build folder that GENUINELY
## carries no localization.json. Nothing is emptied and nothing is mutated: the marker is the FILE
## EXISTING, so only a real import of a real pre-localization build proves it.
func _run_source_only_case(case: Dictionary) -> void:
	var name := str(case.get("case", "?"))
	var expected: Dictionary = case.get("expected", {})

	_import_package("srconly", "verbatim", {}, false)
	var source_only = _manager.get_project()
	_check("%s: a build with no sidecar is not a localized project" % name,
		source_only != null and not source_only.has_localization)
	var loc = _manager.get_localization()
	_check("%s: it registers no language tables" % name, loc.tables.is_empty())
	_check("%s: it offers no target languages" % name, loc.languages.is_empty())
	_check("%s: its source language is the pre-localization default (got '%s')" % [name, loc.source_language],
		loc.source_language == "en")
	_check("%s: and it offers no language roster at all" % name, _manager.get_languages().is_empty())
	_check("%s: the active language fell back to the source language (got '%s')" % [name, _manager.get_language()],
		_manager.get_language() == "en")

	var script = source_only.get_storyflow_script("script")
	for string_id in expected:
		# Every shipped id, resolved as this plugin behaved before localization existed - and
		# again asked for a language it does not carry, which still answers source text because
		# there is no table to overlay.
		var in_source := _localized_resolve_in(source_only, script, str(string_id), "en")
		_check("%s: source-only['%s'] resolves to '%s' (got '%s')" % [name, str(string_id), str(expected[string_id]), in_source],
			in_source == str(expected[string_id]))
		var in_fr := _localized_resolve_in(source_only, script, str(string_id), "fr")
		_check("%s: source-only['%s'] asked in fr still answers source text (got '%s')" % [name, str(string_id), in_fr],
			in_fr == str(expected[string_id]))

	# The remaining cases run against the package's own localized project again.
	_manager.set_project(_loc_project)


## The §9 language API as a game drives it, through the RENDERED dialogue lane (the text
## interpolator) rather than the node lane the cases use - so the language is proved to reach the
## screen, not only the resolver.
func _run_localization_api() -> void:
	_import_package("locapi", "verbatim", {}, true)
	var api_project = _manager.get_project()
	var component := _make_component()
	component.start_dialogue_with_script("script")

	# The case replay above left the player in a target language and this fresh import CARRIED it:
	# re-installing content a player's language is still shipped by must not undo their choice.
	# (The opposite case - a project that does NOT ship it - is asserted at the end.)
	_check("api: a re-import carries a chosen language the new project also ships (got '%s')"
		% _manager.get_language(), _manager.get_language() == "fr")
	_check("api: the walk starts from the source language", _manager.set_language("en"))

	var languages: Array = _manager.get_languages()
	_check("api: the roster is source-first (got %s)" % str(languages),
		languages.size() == 3 and str(languages[0].get("code")) == "en"
			and str(languages[0].get("name")) == "en")
	_check("api: then the author's registry order with their labels",
		str(languages[1].get("code")) == "fr" and str(languages[1].get("name")) == "French"
			and str(languages[2].get("code")) == "es" and str(languages[2].get("name")) == "Spanish")

	# Node 1 is RENDERED through the real dialogue builder rather than reached by advancing the
	# graph: the vendored script.json's edges carry no handles (it is a binding fixture whose nodes
	# the §5 cases READ rather than run), so the executor parks at its start node. Everything that
	# matters here still travels verbatim from the vendored data - node 1's title/text ids, its
	# speaker ref, and the imported script's own strings table, which is the source tier every
	# untranslated expectation below falls through to.
	var state = component._build_dialogue_state(api_project.get_storyflow_script("script").get_node("1"))
	_check("api: the dialogue rendered", state != null)
	_check("api: the source line's title (got '%s')" % state.title, state.title == "Greeting")
	_check("api: the source line's text (got '%s')" % state.text, state.text == "Well met.")
	_check("api: the source speaker name (got '%s')" % state.character.name, state.character.name == "Sir Roland")

	# A registered code in ANY casing, answered in the REGISTERED casing.
	_check("api: set_language accepts a registered code in any casing", _manager.set_language("FR"))
	_check("api: and reports the canonical casing back (got '%s')" % _manager.get_language(),
		_manager.get_language() == "fr")

	# The switch reaches the RENDERED state on the next render, mid-dialogue.
	state = component._build_dialogue_state(api_project.get_storyflow_script("script").get_node("1"))
	_check("api: an OUTDATED row ships the old translation, not the new source (got '%s')" % state.title,
		state.title == "Salutations")
	_check("api: a translated row ships the translation (got '%s')" % state.text,
		state.text == "Bien le bonjour.")
	# UNLIKE THE UNITY PORT, which bakes display names at import and lags a mid-session switch:
	# this engine stores the name KEY on the runtime record and resolves it per read, so the
	# speaker label flips immediately (the Unreal posture).
	_check("api: the speaker label flips too - names resolve at READ time here (got '%s')" % state.character.name,
		state.character.name == "Sire Roland")

	# An unknown or empty code is a NO-OP: a typo must never move the player out of the language
	# they picked.
	_check("api: set_language refuses a code this project does not carry", not _manager.set_language("de"))
	_check("api: and leaves the player where they were", _manager.get_language() == "fr")
	_check("api: set_language refuses an empty code", not _manager.set_language(""))
	_check("api: and still leaves the player where they were", _manager.get_language() == "fr")
	state = component._build_dialogue_state(api_project.get_storyflow_script("script").get_node("1"))
	_check("api: the refused switch changed nothing on screen", state.title == "Salutations")

	# Per-language tables are independent: the id French serves OUTDATED is Done in Spanish.
	_check("api: set_language switches to the second language", _manager.set_language("es"))
	state = component._build_dialogue_state(api_project.get_storyflow_script("script").get_node("1"))
	_check("api: per-language tables are independent (title, got '%s')" % state.title, state.title == "Saludo")
	_check("api: per-language tables are independent (text, got '%s')" % state.text, state.text == "Well met.")

	# A reset keeps the choice: a language is a player SETTING, not session state.
	_manager.reset_all_state()
	_check("api: the active language survives a full state reset", _manager.get_language() == "es")

	# Back to the source language: a legitimate choice, with no table of its own.
	_check("api: the source language is settable", _manager.set_language("en"))
	state = component._build_dialogue_state(api_project.get_storyflow_script("script").get_node("1"))
	_check("api: the source text comes back (got '%s')" % state.title, state.title == "Greeting")

	# NEVER-NULL SHAPE at the public door: a value that keyed no table anywhere is its own text,
	# in the source language and in a target language alike.
	_check("api: an unkeyed value resolves to itself in the source language",
		component.get_localized_string("nothing keyed this") == "nothing keyed this")
	_manager.set_language("fr")
	_check("api: and in a target language too",
		component.get_localized_string("nothing keyed this") == "nothing keyed this")

	# The choice survives a re-set of a project that still carries it (re-installing content
	# mid-game must not undo a choice), and a project that does NOT carry it snaps to that
	# project's source language rather than leaving the game reading a language nothing ships.
	_manager.set_project(api_project)
	_check("api: the choice survives a re-set of a project that carries it", _manager.get_language() == "fr")
	_import_package("locapi_none", "verbatim", {}, false)
	_check("api: a project without the code snaps to its source language", _manager.get_language() == "en")
	_check("api: and a re-import replaces the tables rather than appending to them",
		_manager.get_localization().tables.is_empty() and _manager.get_localization().languages.is_empty())

	_teardown(component)

	# A SAVE LOAD must leave the language alone for the same reason a reset does: it is a player
	# SETTING, not story state. Run with the dialogue torn down, because a load is refused while
	# one is active.
	_import_package("locapi_save", "verbatim", {}, true)
	_check("api: a second localized import does not stack the registry (got %d rows)"
		% _manager.get_languages().size(), _manager.get_languages().size() == 3)
	_check("api: the language for the save", _manager.set_language("es"))
	_check("api: a save is written", _manager.save_to_slot(SAVE_SLOT))
	_check("api: the player then switches", _manager.set_language("fr"))
	_check("api: the save loads", _manager.load_from_slot(SAVE_SLOT))
	_check("api: and the LOAD left the language alone (got '%s')" % _manager.get_language(),
		_manager.get_language() == "fr")

	_run_localization_in_place_pin()


## THE IN-PLACE MUTATION DOCTRINE on the localization state, pinned exactly the way the character
## id bridge's is (tests/test_character_index.gd): the manager's StoryFlowLocalization is assigned
## ONCE and MUTATED IN PLACE forever, never rebound.
##
## Documented is not enforced, and this is the v1.2.3 stranding lesson's own shape: a running
## dialogue takes a NON-OWNING reference to this object at dialogue start, so an install or a
## reset that REASSIGNED it would leave the live context reading the pre-change object - the game
## split into two languages mid-sentence, silently, with both halves internally consistent.
##
## IDENTITY IS ASSERTED WITH is_same, never ==: the point is the OBJECT, not its contents.
func _run_localization_in_place_pin() -> void:
	_import_package("locpin", "verbatim", {}, true)
	var loc_view = _manager.get_localization()
	var component := _make_component()
	component.start_dialogue_with_script("script")

	# THE HANDOVER: what the running dialogue holds is the manager's own object, not a copy.
	_check("pin: the running dialogue holds the MANAGER's localization object",
		is_same(component._context.localization, loc_view))

	# A mid-dialogue switch reaches that live reference, and the screen with it.
	_check("pin: the switch is accepted", _manager.set_language("es"))
	_check("pin: the running context's non-owning reference observes the new language (got '%s')"
		% component._context.localization.active_language,
		component._context.localization.active_language == "es")
	var node: Dictionary = _manager.get_project().get_storyflow_script("script").get_node("1")
	_check("pin: and the next render reads it (got '%s')" % component._build_dialogue_state(node).title,
		component._build_dialogue_state(node).title == "Saludo")

	# A REFILL through the pre-install reference: a table erased through the view must come back
	# through the SAME object when the project is re-installed, and the player's choice with it.
	loc_view.tables.erase("es")
	_check("pin: the view really lost the table", not loc_view.tables.has("es"))
	_manager.set_project(_manager.get_project())
	_check("pin: set_project refills through the pre-install reference (got %d tables)"
		% loc_view.tables.size(), loc_view.tables.size() == 2 and loc_view.tables.has("es"))
	_check("pin: and never rebound the object", is_same(_manager.get_localization(), loc_view))
	_check("pin: the player's choice rode through the re-install (got '%s')" % loc_view.active_language,
		loc_view.active_language == "es")
	_check("pin: the running dialogue is still on the same object", is_same(component._context.localization, loc_view))

	# EMPTYING is in-place too: installing a project with NO sidecar clears the tables through the
	# same object rather than swapping in a fresh one, and snaps the language to what ships.
	_import_package("locpin_none", "verbatim", {}, false)
	_check("pin: a sidecar-less install empties the tables in place", loc_view.tables.is_empty())
	_check("pin: still the same object after the emptying", is_same(_manager.get_localization(), loc_view))
	_check("pin: and the language snapped to the source language (got '%s')" % loc_view.active_language,
		loc_view.active_language == "en")

	# A state reset touches neither the object nor the choice.
	_manager.set_project(_loc_project)
	_check("pin: the localized project re-installs through the same object",
		is_same(_manager.get_localization(), loc_view) and loc_view.tables.size() == 2)
	_check("pin: a chosen language before the reset", _manager.set_language("fr"))
	_manager.reset_all_state()
	_check("pin: reset_all_state leaves the object untouched", is_same(_manager.get_localization(), loc_view))
	_check("pin: and leaves the tables filled (got %d)" % loc_view.tables.size(), loc_view.tables.size() == 2)
	_check("pin: and leaves the player's choice alone (got '%s')" % loc_view.active_language,
		loc_view.active_language == "fr")

	_teardown(component)


# =============================================================================
# Surface helpers
# =============================================================================

## The host getter behind one ref: ById when the ref carries an id, the path getter otherwise.
func _host_variant(ref: Dictionary, var_name: String):
	var probe := _wr_probe if _wr_probe != null else _res_probe
	if ref.has("characterId"):
		return probe.get_character_variable_by_id(str(ref["characterId"]), var_name)
	return probe.get_character_variable(str(ref.get("characterPath", "")), var_name)


## The DA-surface typed read for one scalar structural type. Booleans have no out-of-band
## sentinel, so the read runs once against each default: agreement means the real value
## answered, disagreement means the defaults did (a miss, reported as null).
func _da_scalar_read(id: String, var_name: String, type_token: String):
	var probe := _wr_probe if _wr_probe != null else _res_probe
	match type_token:
		"boolean":
			var with_true := probe.get_data_asset_bool(id, var_name, true)
			var with_false := probe.get_data_asset_bool(id, var_name, false)
			return with_true if with_true == with_false else null
		"integer":
			return probe.get_data_asset_int(id, var_name, -987654)
		"float":
			return probe.get_data_asset_float(id, var_name, -987654.0)
	return null


func _typed_node_read(evaluator, gid: String, type_token: String):
	match type_token:
		"boolean":
			return evaluator.evaluate_boolean_from_node(gid)
		"integer":
			return evaluator.evaluate_integer_from_node(gid)
		"float":
			return evaluator.evaluate_float_from_node(gid)
	return str(evaluator.evaluate_string_from_node(gid))


## A node-surface read for a write case's read entry: typed scalars through the probe's
## reader node, arrays and maps through the evaluator arm (their literal runtime values).
func _typed_node_native(evaluator, gid: String, ref: Dictionary, variable: Dictionary):
	var type_token := str(variable.get("type", ""))
	if bool(variable.get("isArray", false)):
		return _strings_of(evaluator._evaluate_character_variable(_node_data(ref, variable), gid).get_array())
	if type_token == "map":
		return _entries_of(evaluator._evaluate_character_variable(_node_data(ref, variable), gid).get_map())
	return _typed_node_read(evaluator, gid, type_token)


## The character record one case ref reaches, as data: the bridge for ids, the normalized
## key for paths.
func _record_for_ref(ref: Dictionary):
	if ref.has("characterId"):
		var key := str(_manager.get_character_id_bridge().get(str(ref["characterId"]), ""))
		return _manager.get_runtime_characters().get(key)
	return _manager.get_runtime_character(str(ref.get("characterPath", "")))


func _mint(variable: Dictionary, raw) -> StoryFlowVariant:
	var type_token := str(variable.get("type", ""))
	if bool(variable.get("isArray", false)):
		var elements: Array = []
		if raw is Array:
			for element in raw:
				elements.append(VariantScript.from_string(str(element)))
		var variant := VariantScript.new()
		variant.set_array(elements)
		return variant
	if type_token == "map":
		var entries: Dictionary = {}
		if raw is Array:
			for entry in raw:
				entries[str(entry.get("key", ""))] = VariantScript.from_string(str(entry.get("value", "")))
		return VariantScript.from_map(entries)
	match type_token:
		"boolean":
			return VariantScript.from_bool(bool(raw))
		"integer":
			return VariantScript.from_int(int(raw))
		"float":
			return VariantScript.from_float(float(raw))
	return VariantScript.from_string(str(raw))


# =============================================================================
# Comparison helpers (the manifest's comparisons map)
# =============================================================================

## Structural JSON value equality: array order significant, maps as ordered {key, value}
## entry lists, numbers by exact representation (every number in the package is binary-exact).
func _structural_equal(actual, expected) -> bool:
	if expected is bool:
		return actual is bool and actual == expected
	if expected is float or expected is int:
		if actual is bool or not (actual is float or actual is int):
			return false
		return float(actual) == float(expected)
	if expected is String:
		return actual is String and actual == expected
	if expected is Array:
		if not actual is Array or actual.size() != expected.size():
			return false
		for i in expected.size():
			if not _structural_equal(actual[i], expected[i]):
				return false
		return true
	if expected is Dictionary:
		if not actual is Dictionary:
			return false
		return _structural_equal_dicts(actual, expected)
	return actual == null and expected == null


func _structural_equal_dicts(actual: Dictionary, expected: Dictionary) -> bool:
	if actual.size() != expected.size():
		return false
	for key in expected:
		if not actual.has(key) or not _structural_equal(actual[key], expected[key]):
			return false
	return true


func _native_scalar(variant, type_token: String):
	if variant == null:
		return null
	match type_token:
		"boolean":
			return variant.get_bool(false)
		"integer":
			return variant.get_int(0)
		"float":
			return variant.get_float(0.0)
	return variant.get_string("")


func _native_of(variant, variable: Dictionary):
	if variant == null:
		return null
	if bool(variable.get("isArray", false)):
		return _strings_of(variant.get_array())
	if str(variable.get("type", "")) == "map":
		return _entries_of(variant.get_map())
	return _native_scalar(variant, str(variable.get("type", "")))


## Resolve every string leaf of a native value through the engine's one string chokepoint.
func _resolved_native(native, evaluator):
	if native is String:
		return str(evaluator._resolve_string_key(native))
	if native is Array:
		var out: Array = []
		for element in native:
			out.append(_resolved_native(element, evaluator))
		return out
	if native is Dictionary:
		var out_entry := {}
		for key in native:
			out_entry[key] = _resolved_native(native[key], evaluator) if key == "value" else native[key]
		return out_entry
	return native


func _strings_of(elements: Array) -> Array:
	var out: Array = []
	for element in elements:
		if element is VariantScript:
			out.append(element.get_string(""))
	return out


func _entries_of(map: Dictionary) -> Array:
	var entries: Array = []
	for key in map:
		var value = map[key]
		entries.append({"key": str(key), "value": value.get_string("") if value is VariantScript else null})
	return entries


func _keys_of(entries: Array) -> Array:
	var keys: Array = []
	for entry in entries:
		keys.append(str(entry.get("key", "")))
	return keys


# =============================================================================
# Save-document helpers (A5: this engine's save writes stored keys; the reference's
# expectations are resolved text, so the package's own tables map one onto the other)
# =============================================================================

func _read_save_doc() -> Dictionary:
	var file := FileAccess.open("user://storyflow_saves/%s.json" % SAVE_SLOT, FileAccess.READ)
	if file == null:
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}


func _resolve_pkg_string(stored: String) -> String:
	return str(_pkg_strings.get(stored, stored))


func _resolve_pkg_asset(stored: String) -> String:
	if stored.is_empty():
		return ""
	return str(_pkg_assets.get(stored, {}).get("path", stored))


## One save row's value in the reference's resolved form: string-family leaves through the
## strings table, everything else verbatim.
func _resolve_save_row_value(row: Dictionary):
	var value = row.get("value")
	var type_name := str(row.get("type", ""))
	if str(row.get("type", "")) == "Map" and value is Array:
		var entries: Array = []
		for entry in value:
			entries.append({"key": entry.get("key"), "value": _resolve_pkg_string(str(entry.get("value")))})
		return entries
	if bool(row.get("isArray", false)) and value is Array:
		var out: Array = []
		for element in value:
			out.append(_resolve_pkg_string(str(element)) if type_name == "String" else element)
		return out
	if type_name == "String" and value is String:
		return _resolve_pkg_string(value)
	return value


# =============================================================================
# Plumbing
# =============================================================================

func _load_fixture(path: String) -> Dictionary:
	var parsed = JSON.parse_string(_read_text(path))
	return parsed if parsed is Dictionary else {}


func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		printerr("  SETUP FAILURE: cannot read %s" % path)
		return ""
	var text := file.get_as_text()
	file.close()
	return text


func _write_text(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr("  SETUP FAILURE: cannot write %s" % path)
		return
	file.store_string(text)
	file.close()


func _make_component() -> StoryFlowComponent:
	var component := ComponentScript.new()
	component.dialogue_ui_scene = null
	get_root().add_child(component)
	return component


func _teardown(component: StoryFlowComponent) -> void:
	component.stop_dialogue()
	get_root().remove_child(component)
	component.queue_free()


func _var_of(character, variable_name: String) -> StoryFlowVariant:
	var value = character.variables.get(variable_name, {}).get("value")
	return value if value is VariantScript else VariantScript.new()


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
