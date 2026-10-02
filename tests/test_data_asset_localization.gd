extends SceneTree
## Legacy exports only: the frozen fixtures omit localizationVersion. Version 2 coverage lives
## in test_data_asset_override_localization.gd; its file overrides can localize.
## Headless tests for the .sfd LOCALIZATION GATE — localization spec §2's amendment of
## 2026-08-27, which SUPERSEDES engine-contract 2.1's literal-value posture: a Data Asset's
## DECLARED string values are player-facing prose that ship as stable keys in data-assets.json's
## own strings table, while its OVERRIDES and every SESSION WRITE stay verbatim forever.
##
## THREE THINGS THE GOLDEN PACKAGE CANNOT PIN FOR THIS ENGINE, and one file for all three:
##
##   1. THE PRESENCE SHAPES (tests/test_character_contract.gd's `unkeyed` arm drives the two
##      ABSENCE shapes). Every .sfd rule is about the ID A READ DOOR REACHES a table with, and a
##      wrong id fails as a WRONG VALUE rather than as a miss, so the three id shapes, an
##      override beside the declaration it shadows, a descendant's own declaration and the type
##      gate are all driven through the real doors, once per language. Expectations are COMPUTED
##      from the vendored sidecar through the string chokepoint, never transcribed: a
##      hand-written expectation is one more copy of the rule under test and would agree with a
##      wrong door as happily as with a right one.
##   2. THE KEY-SHAPED OVERRIDE, inline. The package's own override case cannot fail this plugin
##      (see _test_key_shaped_override for why, in full), so the arm needs bytes the package does
##      not carry.
##   3. seedVsWritten, which manifest.localization.dataAssets STATES and says plainly it does not
##      pin: no case in the package writes a .sfd value, so each engine owns its write / save /
##      load / read case rather than reading a green package run as coverage of it.
##
## The package files are the VENDORED ones (tests/fixtures/character-contract/, byte-identical to
## the editor's); only the .sfd inputs are needed here, so the builds carry data-assets.json and
## localization.json and nothing else.
##
## Run from the repository root (import first to build the class cache):
##   godot --headless --import
##   godot --headless --script res://tests/test_data_asset_localization.gd
## Or: powershell -File tests/run_tests.ps1 -GodotExe <path-to-godot>

const ComponentScript := preload("res://addons/storyflow/core/storyflow_component.gd")
const Doors := preload("res://tests/data_asset_read_doors.gd")
const Graph := preload("res://tests/data_asset_test_graph.gd")
const Handles := preload("res://addons/storyflow/core/storyflow_handles.gd")
const ImporterScript := preload("res://addons/storyflow/editor/storyflow_importer.gd")
const LocalizationScript := preload("res://addons/storyflow/core/storyflow_localization.gd")
const ManagerScript := preload("res://addons/storyflow/core/storyflow_manager.gd")
const Types := preload("res://addons/storyflow/core/storyflow_types.gd")

const FIXTURE_DIR := "res://tests/fixtures/character-contract"
const SAVE_SLOT := "data_asset_localization"

const ITEM_BASE := "da_itembase0000000000000000000000"
const ITEM_RELIC := "da_itemrelic000000000000000000000"

var _checks: int = 0
var _failures: int = 0
var _temp_root: String = ""
var _manager: Node = null


func _initialize() -> void:
	await process_frame
	_temp_root = OS.get_user_data_dir().path_join("sf_da_localization_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(_temp_root)
	_manager = ManagerScript.new()
	_manager.name = "StoryFlowRuntime"
	get_root().add_child(_manager)
	_manager.delete_save(SAVE_SLOT)

	_test_read_door()
	_test_container_reads()
	_test_key_shaped_override()
	_test_seed_versus_written()

	_manager.delete_save(SAVE_SLOT)
	_rm_rf(_temp_root)

	if _failures == 0:
		print("ALL %d CHECKS PASSED" % _checks)
	else:
		print("%d OF %d CHECKS FAILED" % [_failures, _checks])
	quit(1 if _failures > 0 else 0)


## Records one assertion and ANSWERS IT BACK, so a check that guards the next few (an array
## carrying the elements they index into) can be written as one `if`.
func _check(label: String, ok: bool) -> bool:
	_checks += 1
	if ok:
		print("  PASS: %s" % label)
	else:
		_failures += 1
		printerr("  FAIL: %s" % label)
	return ok


# =============================================================================
# 1. The read door: the PRESENCE shapes
# =============================================================================

## WHAT A BYTE COMPARISON CANNOT SEE. The four things asked here, per language, are the four the
## id rule is made of:
##   1. the three id shapes — scalar, array element by index, map entry value by key (and a map's
##      KEYS untouched, asserted rather than implied: a lookup over a key is the mistake that
##      costs a map its shape);
##   2. an override BESIDE the declaration it shadows, which must not move while the declaration
##      does — adjacent on purpose, since with no asset segment walking overrides is a plausible
##      reading whose damage is invisible unless the two are read together;
##   3. a DESCENDANT'S OWN declaration, which keys — the half of the rule an asset-segment reading
##      loses, because it is the VARIABLE that is unique, not the asset;
##   4. the type gate at the door: an enum whose value is a string stays literal.
func _test_read_door() -> void:
	print("-- the .sfd read door, per language --")
	var project = _import_localized("readdoor")
	if project == null:
		return

	var doors := Doors.new()
	doors.doc = _load_fixture(FIXTURE_DIR.path_join("data-assets.json"))
	_check("[setup] the vendored .sfd seed parsed", not doors.doc.is_empty())
	var component := _run_probe(doors, "probe/ReadDoor.sfe", [
		{"assetId": ITEM_BASE, "variableId": "v-item-name"},
		{"assetId": ITEM_BASE, "variableId": "v-item-desc"},
		{"assetId": ITEM_BASE, "variableId": "v-item-tags"},
		{"assetId": ITEM_BASE, "variableId": "v-item-slots"},
		{"assetId": ITEM_BASE, "variableId": "v-item-rarity"},
		{"assetId": ITEM_RELIC, "variableId": "v-item-desc"},
		{"assetId": ITEM_RELIC, "variableId": "v-relic-oath"},
	])

	for language in ["fr", "es"]:
		_check("the engine accepts %s" % language, _manager.set_language(language))

		# 2. The override and the declaration it shadows, out of ONE store and adjacent.
		var override := _read(doors, language + " override", ITEM_RELIC, "v-item-desc")
		_check("%s: an override ships literal, in every language" % language,
			override["text"] == "A blade that hums with old grief.")
		var shadowed := _read(doors, language + " declaration", ITEM_BASE, "v-item-desc")
		_check("%s: the declaration it shadows localizes" % language,
			shadowed["text"] == _resolved(project, "v-item-desc.value"))
		_check("%s: and the two are genuinely different texts" % language,
			override["text"] != shadowed["text"])

		# 1. The three id shapes, each read whole, as game code reads it.
		_check("%s: a scalar keys <variableId>.value" % language,
			_read(doors, language + " scalar", ITEM_BASE, "v-item-name")["text"] == _resolved(project, "v-item-name.value"))

		var tags = _read(doors, language + " array", ITEM_BASE, "v-item-tags")["host"]
		var elements: Array = tags.get_array() if tags != null else []
		if _check("%s: the array read carries both elements" % language, elements.size() == 2):
			_check("%s: element 0 keys .value.0" % language,
				elements[0].get_string("") == _resolved(project, "v-item-tags.value.0"))
			_check("%s: element 1 keys .value.1" % language,
				elements[1].get_string("") == _resolved(project, "v-item-tags.value.1"))

		var slots = _read(doors, language + " map", ITEM_BASE, "v-item-slots")["host"]
		var entries: Dictionary = slots.get_map() if slots != null else {}
		if _check("%s: the map read carries both entries" % language, entries.size() == 2):
			_check("%s: the map KEYS are identifiers and are untouched" % language,
				entries.has("hand") and entries.has("back"))
			_check("%s: the hand value keys .value.hand" % language,
				entries["hand"].get_string("") == _resolved(project, "v-item-slots.value.hand"))
			_check("%s: the back value keys .value.back" % language,
				entries["back"].get_string("") == _resolved(project, "v-item-slots.value.back"))

		# 3. A descendant's OWN declaration keys, on the same chain as the base's.
		_check("%s: a descendant's own declaration keys too" % language,
			_read(doors, language + " descendant", ITEM_RELIC, "v-relic-oath")["text"] == _resolved(project, "v-relic-oath.value"))

		# 4. The type gate at the door: the DECLARED type decides, never the value's shape.
		_check("%s: an enum whose value is a string stays literal" % language,
			_read(doors, language + " enum", ITEM_BASE, "v-item-rarity")["text"] == "Common")

	# THE FR/ES DIVERGENCE in one assertion: the same id answers differently in the two languages,
	# so a door that resolved once and cached across a language switch fails here. It is also the
	# READ-TIME posture stated: nothing was re-imported and no dialogue restarted between them.
	_manager.set_language("fr")
	var french: String = _read(doors, "fr switch", ITEM_BASE, "v-item-name")["text"]
	_manager.set_language("es")
	var spanish: String = _read(doors, "es switch", ITEM_BASE, "v-item-name")["text"]
	_check("a mid-session set_language reaches the very next .sfd read", french != spanish)
	_check("fr serves the translation (got '%s')" % french, french == "Epee de fer")
	_check("es has no row for it, so it serves the source (got '%s')" % spanish, spanish == "Iron Sword")

	_teardown(component)


# =============================================================================
# 1b. THE CONTAINER RESIDUE, measured rather than assumed
# =============================================================================

## A .sfd ARRAY ELEMENT and a .sfd MAP VALUE read by a DOWNSTREAM node — a getStringArrayElement,
## a getMapValue — which is the one path where a value the store already localized re-enters the
## evaluator's shape-gated string ladder as that node's own result. (The .sfd accessor arm returns
## early and is exempt; its downstream consumers are ordinary node types and cannot be.)
##
## The evaluator's tail records that residue as a KNOWN LIMIT, harmless for declared prose because
## a translated line keys nothing and the raw-fallback tier hands it straight back. THIS IS THAT
## CLAIM MEASURED: the elements come out translated, through the real nodes, in a real target
## language. The residue is only a hazard for a translation that happens to BE a live table key,
## which is the same accepted duplicate-source class the amendment names, and closing it would
## mean tainting values with their origin all the way through the evaluator.
##
## WHAT IT DOES NOT PROVE, said plainly: this path has TWO lookups in it now, and a green here
## does not say which one did the work — before the amendment the shape-gated tail resolved these
## elements on its own, accidentally and only in the source language. The GATE is pinned by
## _test_read_door, which reads the same container through the doors directly.
func _test_container_reads() -> void:
	print("-- a .sfd container element read by a downstream node --")
	var project = _import_localized("container")
	if project == null:
		return

	var doors := Doors.new()
	doors.doc = _load_fixture(FIXTURE_DIR.path_join("data-assets.json"))
	var script = Graph.build("probe/Container.sfe", {
		"0": Graph.start(),
		"D": Graph.dialogue("D"),
		"P": Graph.pill("P", ITEM_BASE),
		"GA": Graph.accessor("GA", doors.pins_from(doors.declaration_json("v-item-tags"), "v-item-tags")),
		"GM": Graph.accessor("GM", doors.pins_from(doors.declaration_json("v-item-slots"), "v-item-slots")),
		"GE": Graph.node("GE", Types.NodeType.GET_STRING_ARRAY_ELEMENT, "getStringArrayElement", {"value": 0}),
		"GV": Graph.node("GV", Types.NodeType.GET_MAP_VALUE, "getMapValue",
			{"keyType": "string", "valueType": "string", "key": "hand"}),
	}, [
		Graph.exec("0", "D"),
		Graph.pill_wire("P", "GA"), Graph.pill_wire("P", "GM"),
		Graph.data_wire("GA", "string-array", "GE", Handles.IN_STRING_ARRAY),
		Graph.map_wire("GM", "GV", "string", "string", "1"),
	])
	_manager.get_project().scripts[script.script_path] = script
	var component := _make_component()
	component.start_dialogue_with_script(script.script_path)
	_check("[setup] the container probe graph is running", component._evaluator != null)

	_check("the engine accepts fr", _manager.set_language("fr"))
	var element: String = component._evaluator.evaluate_string_from_node("GE", "")
	_check("an array element read downstream still answers the translation (got '%s')" % element,
		element == "Arme")
	var entry: String = component._evaluator.evaluate_string_from_node("GV", "")
	_check("and so does a map entry value (got '%s')" % entry, entry == "Main directrice")

	_teardown(component)


# =============================================================================
# 2. declarationsOnly: the override arm, in the form THIS engine meets it
# =============================================================================

## WHY THIS EXISTS WHEN THE GOLDEN PACKAGE ALREADY CARRIES sfd-override-ships-literal.
##
## That case cannot fail this plugin, and it is worth writing down why rather than reading its
## green as coverage. The reference implementation resolves a .sfd value by BUILDING an id
## (`<variableId>.value`) at the door, so localizing an override there immediately serves the
## ancestor's translation — the bug the editor fixed at b18c4de0. THIS engine never builds an id:
## the exporter already put the key in the value and the door resolves the bytes it read. The
## package's override stores ordinary prose, prose keys nothing, and the ladder's raw-fallback
## tier answers an unkeyed string with itself — so on those bytes the gate's Override arm is
## unobservable, and deleting it changes no result.
##
## The arm is still load-bearing, because the collision the manifest describes is about BYTES: the
## moment an override's stored value IS a shipped string id, a door that localized overrides hands
## back somebody else's prose. So this builds the smallest seed that carries it — a base declaring
## TWO keyed strings, a child overriding one of them with THE OTHER'S KEY — and reads it through
## the real doors in a real target language.
##
## INLINE rather than vendored: the golden package's bytes are the editor's and must not grow a
## row for one engine's test (the same rule the .sfd node suites already follow for shapes the
## shared fixtures cannot carry).
##
## THE TWO DECLARATIONS ARE ASSERTED FIRST, and that is not decoration: without them a plugin that
## localizes NOTHING AT ALL would pass, which is the failure mode a lone negative assertion always
## admits.
func _test_key_shaped_override() -> void:
	print("-- a key-shaped .sfd override is never localized --")
	var data_assets := {
		"dataAssets": {
			"da_gatebase00000000000000000000": {
				"id": "da_gatebase00000000000000000000", "name": "gate-base", "parent": null,
				"variables": [
					{"id": "v-gate-desc", "name": "Description", "type": "string", "value": "v-gate-desc.value"},
					{"id": "v-gate-other", "name": "Other", "type": "string", "value": "v-gate-other.value"},
				],
				"overrides": {},
			},
			"da_gatechild0000000000000000000": {
				"id": "da_gatechild0000000000000000000", "name": "gate-child",
				"parent": "da_gatebase00000000000000000000",
				"variables": [],
				"overrides": {"v-gate-desc": "v-gate-other.value"},
			},
		},
		"strings": {"en": {
			"v-gate-desc.value": "The base description.",
			"v-gate-other.value": "A different authored line.",
		}},
	}
	var localization := {
		"schemaVersion": "1",
		"sourceLanguage": "en",
		"languages": [{"code": "fr", "name": "French"}],
		"strings": {"fr": {
			"v-gate-desc.value": "La description de base.",
			"v-gate-other.value": "Une autre ligne.",
		}},
	}

	var project = _import_build("gate", {
		"data-assets.json": JSON.stringify(data_assets, "\t"),
		"localization.json": JSON.stringify(localization, "\t"),
	})
	if project == null:
		return

	var doors := Doors.new()
	doors.doc = data_assets
	var component := _run_probe(doors, "probe/Gate.sfe", [
		{"assetId": "da_gatebase00000000000000000000", "variableId": "v-gate-desc"},
		{"assetId": "da_gatebase00000000000000000000", "variableId": "v-gate-other"},
		{"assetId": "da_gatechild0000000000000000000", "variableId": "v-gate-desc"},
	])
	_check("the engine accepts fr", _manager.set_language("fr"))

	_check("the base's declared Description localizes",
		_read(doors, "gate base desc", "da_gatebase00000000000000000000", "v-gate-desc")["text"] == "La description de base.")
	_check("and so does the other declaration, whose key the override carries",
		_read(doors, "gate base other", "da_gatebase00000000000000000000", "v-gate-other")["text"] == "Une autre ligne.")

	# THE OVERRIDE. Its stored bytes are a real shipped key, so a door that localized overrides
	# answers "Une autre ligne." here — the other declaration's prose, served for a text the
	# descendant deliberately replaced. Verbatim is the only right answer.
	var overridden := _read(doors, "gate child desc", "da_gatechild0000000000000000000", "v-gate-desc")
	_check("an override is handed back verbatim, key-shaped or not (got '%s')" % overridden["text"],
		overridden["text"] == "v-gate-other.value")
	_check("and specifically NOT the other declaration's translation",
		overridden["text"] != "Une autre ligne.")

	_teardown(component)


# =============================================================================
# 3. seedVsWritten: the rule the golden package STATES but does not pin
# =============================================================================

## A SEED LOCALIZES; A WRITTEN VALUE NEVER DOES, including after a save/load, since the save
## carries the overlay and a restored write was never content.
##
## THE KEY-SHAPED WRITE IS THE POINT. The manifest's warning is that an engine must gate on WHERE
## A VALUE CAME FROM and never on whether it LOOKS like a key, so this writes a value that is
## character-for-character a real string-table key. An implementation that resolved anything
## key-shaped hands back the translation of a string the game has since redefined — and in the
## source language it looks perfect. The counter-assertion at the end is what gives that its
## teeth: the id really is keyed, to somebody's prose, in the language the read ran in.
##
## Driven through the TYPED host setter/getter pair a game actually calls, which shares the gate
## with the untyped door the read-door test drives but not its code path.
func _test_seed_versus_written() -> void:
	print("-- a seed localizes, a written value never does --")
	var project = _import_localized("seedwritten")
	if project == null:
		return
	var host := _make_component()
	_check("the engine accepts fr", _manager.set_language("fr"))

	# The seed, before anything is written: prose, and it localizes.
	_check("an untouched declaration localizes",
		host.get_data_asset_string(ITEM_BASE, "Item Name") == "Epee de fer")

	# THE WRITE. From here on this variable is live data, not the author's string.
	_check("a session write lands",
		host.set_data_asset_string(ITEM_BASE, "Item Name", "Runed Sword"))
	_check("and the very next read hands it back verbatim, in fr",
		host.get_data_asset_string(ITEM_BASE, "Item Name") == "Runed Sword")

	# THE KEY-SHAPED WRITE, on the variable beside it: a value that IS a table key, byte for byte.
	_check("a key-shaped write lands",
		host.set_data_asset_string(ITEM_BASE, "Description", "v-item-desc.value"))
	_check("and is NOT translated, because provenance decides and not shape",
		host.get_data_asset_string(ITEM_BASE, "Description") == "v-item-desc.value")

	_check("the save succeeds with no dialogue running", _manager.save_to_slot(SAVE_SLOT))

	# A restart drops the session: the seed is back, and translated again.
	_manager.reset_data_assets()
	_check("the reset restores the seed, which localizes",
		host.get_data_asset_string(ITEM_BASE, "Item Name") == "Epee de fer")

	# THE LOAD, then a switch into a language the write was never made in.
	_check("the load succeeds", _manager.load_from_slot(SAVE_SLOT))
	_check("the engine accepts es", _manager.set_language("es"))

	_check("a restored write is still live data, verbatim, in a second language",
		host.get_data_asset_string(ITEM_BASE, "Item Name") == "Runed Sword")
	_check("and the key-shaped one is still not translated",
		host.get_data_asset_string(ITEM_BASE, "Description") == "v-item-desc.value")
	# The counter-assertion that gives the line above teeth: this is what a shape-gated
	# implementation would have handed back instead.
	_check("es really does key that id to somebody's prose",
		_resolved(project, "v-item-desc.value") == "Una hoja sencilla, bien forjada.")

	# And a declaration the session never touched still localizes after the load — the load
	# restored an OVERLAY, not a whole store, so the seed under it is still content.
	var slots = host.get_data_asset_variant(ITEM_BASE, "Slots")
	var entries: Dictionary = slots.get_map() if slots != null else {}
	if _check("the untouched map is found with both entries", entries.size() == 2):
		_check("whose values still localize in es",
			entries["back"].get_string("") == "En la vaina")

	_teardown(host)


# =============================================================================
# Harness
# =============================================================================

## The sidecar's own answer for an id, through the SAME chokepoint every string in this plugin
## runs — the shared ladder, with no script, exactly as the .sfd gate reaches it. This is the
## EXPECTATION side of the read-door assertions, derived rather than transcribed.
func _resolved(project, string_id: String) -> String:
	var locale := LocalizationScript.reading_locale(
		_manager.get_localization(), project.global_strings, "en")
	var text = LocalizationScript.look_up(
		locale["localization"], null, locale["global_strings"], string_id, locale["fallback_language"])
	return string_id if text == null else str(text)


## One read through BOTH doors, asserting they agree before the caller looks at the value. The
## agreement check is made HERE so no call site can forget it.
func _read(doors, label: String, asset_id: String, variable_id: String) -> Dictionary:
	var result: Dictionary = doors.read(asset_id, variable_id)
	_check("%s: %s.%s resolves through both .sfd doors, which agree" % [label, asset_id, variable_id],
		result["host"] != null and result["node"] != null and result["agree"])
	return result


## Import the vendored package's .sfd inputs WITH their sidecar. Nothing else is needed: every id
## the .sfd cases touch keys in data-assets.json, and the sidecar's other rows are harmless.
func _import_localized(label: String):
	return _import_build(label, {
		"data-assets.json": _read_text(FIXTURE_DIR.path_join("data-assets.json")),
		"localization.json": _read_text(FIXTURE_DIR.path_join("localization.json")),
	})


## Write one build folder and import it onto the manager, returning the project.
func _import_build(label: String, files: Dictionary):
	var build := _temp("%s/build" % label)
	DirAccess.make_dir_recursive_absolute(build)
	_write_text(build.path_join("project.storyflow"), JSON.stringify({
		"version": "1.0",
		"metadata": {"title": "DataAssetLocalization"},
	}, "\t"))
	for file_name in files:
		_write_text(build.path_join(str(file_name)), str(files[file_name]))
	var project = ImporterScript.new().import_project(build, _temp("%s/out" % label))
	if not _check("[setup] %s: the build imports" % label, project != null):
		return null
	_check("[setup] %s: it imports as a LOCALIZED project" % label, project.has_localization)
	_manager.set_project(project)
	return project


## A component parked on the probe script, with the doors driver pointed at it.
func _run_probe(doors, path: String, targets: Array) -> Node:
	var script = doors.probe_script(path, targets)
	_manager.get_project().scripts[script.script_path] = script
	var component := _make_component()
	component.start_dialogue_with_script(script.script_path)
	_check("[setup] the probe graph is running", component._evaluator != null)
	doors.component = component
	return component


func _make_component() -> Node:
	var component := ComponentScript.new()
	component.dialogue_ui_scene = null
	get_root().add_child(component)
	return component


func _teardown(component: Node) -> void:
	component.stop_dialogue()
	get_root().remove_child(component)
	component.queue_free()


func _temp(relative: String) -> String:
	return _temp_root.path_join(relative)


func _load_fixture(path: String) -> Dictionary:
	var parsed = JSON.parse_string(_read_text(path))
	return parsed if parsed is Dictionary else {}


func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	return "" if file == null else file.get_as_text()


func _write_text(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()


func _rm_rf(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := path.path_join(entry)
		if dir.current_is_dir():
			_rm_rf(full)
		else:
			DirAccess.remove_absolute(full)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)
