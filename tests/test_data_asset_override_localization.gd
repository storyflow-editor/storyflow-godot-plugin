extends SceneTree
## Version 2 localizes authored overrides; declaration opt-outs and session writes stay literal.

const Importer := preload("res://addons/storyflow/editor/storyflow_importer.gd")
const Manager := preload("res://addons/storyflow/core/storyflow_manager.gd")
const Component := preload("res://addons/storyflow/core/storyflow_component.gd")
const Doors := preload("res://tests/data_asset_read_doors.gd")
const VariantValue := preload("res://addons/storyflow/core/storyflow_variant.gd")
const Store := preload("res://addons/storyflow/core/storyflow_data_asset_store.gd")

const SLOT := "override_localization_v2_test"
const MAP_KEY := "hand.slot/opaque"
const SHARED_V2 := "res://tests/fixtures/character-contract-v2/"
var checks := 0
var failures := 0
var manager: Node
var temp_root: String

func _initialize() -> void:
	await process_frame
	manager = Manager.new()
	manager.name = "StoryFlowRuntime"
	root.add_child(manager)
	temp_root = OS.get_user_data_dir().path_join("sf_override_locale_%d" % Time.get_ticks_usec())
	_test_version_two()
	_test_versions()
	_test_disk_reload()
	_test_shared_v2_export()
	manager.delete_save(SLOT)
	_remove_temp(temp_root)
	manager.free()
	print("%d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("FAIL: ", label)

func document() -> Dictionary:
	var source := {
		"title.value": "Base title", "list.value.0": "Base list", "map.value." + MAP_KEY: "Base map",
		"data.child.title.value": "Child title", "data.child.list.value.0": "Child list",
		"data.child.map.value." + MAP_KEY: "Child map", "data.leaf.title.value": "Leaf title",
	}
	return {"localizationVersion": 2, "strings": {"en": source}, "dataAssets": {
		"base": {"name": "Base", "variables": [
			{"id": "title", "name": "Title", "type": "string", "value": "title.value"},
			{"id": "list", "name": "List", "type": "string", "isArray": true, "value": ["list.value.0"]},
			{"id": "map", "name": "Map", "type": "map", "keyType": "string", "valueType": "string", "value": [{"key": MAP_KEY, "value": "map.value." + MAP_KEY}]},
			{"id": "literal", "name": "Literal", "type": "string", "localizable": false, "value": "title.value"},
			{"id": "literal-list", "name": "LiteralList", "type": "string", "isArray": true, "localizable": false, "value": ["title.value"]},
			{"id": "literal-map", "name": "LiteralMap", "type": "map", "keyType": "string", "valueType": "string", "localizable": false, "value": [{"key": MAP_KEY, "value": "title.value"}]},
		]},
		"child": {"name": "Child", "parent": "base", "variables": [], "overrides": {
			"title": "data.child.title.value", "list": ["data.child.list.value.0"],
			"map": [{"key": MAP_KEY, "value": "data.child.map.value." + MAP_KEY}],
			"literal": "data.child.title.value", "literal-list": ["data.child.title.value"],
			"literal-map": [{"key": MAP_KEY, "value": "data.child.title.value"}],
		}},
		"grandchild": {"name": "Grandchild", "parent": "child", "variables": []},
		"leaf": {"name": "Leaf", "parent": "grandchild", "variables": [], "overrides": {"title": "data.leaf.title.value"}},
	}}

func localization() -> Dictionary:
	return {"schemaVersion": "1", "sourceLanguage": "en", "languages": [{"code": "fr", "name": "French"}, {"code": "es", "name": "Spanish"}], "strings": {
		"fr": {"title.value": "Titre base", "data.child.title.value": "Titre enfant", "data.child.list.value.0": "Liste enfant", "data.child.map.value." + MAP_KEY: "Carte enfant", "data.leaf.title.value": "Titre feuille"},
		"es": {"data.child.title.value": "Titulo hijo"},
	}}

func import_inline(doc: Dictionary):
	var project = Importer.new().import_project_from_json({"version": "1.0", "dataAssets": doc, "localization": localization()})
	manager.set_project(project)
	manager.set_language("fr")
	return project

func _test_version_two() -> void:
	var doc := document()
	var project = import_inline(doc)
	var doors := Doors.new()
	doors.doc = doc
	var targets: Array = []
	for asset in ["base", "child", "grandchild", "leaf"]:
		for variable in ["title", "list", "map", "literal", "literal-list", "literal-map"]:
			targets.append({"assetId": asset, "variableId": variable})
	var script = doors.probe_script("override-probe.sfe", targets)
	project.scripts[script.script_path] = script
	var component := Component.new()
	component.dialogue_ui_scene = null
	root.add_child(component)
	component.start_dialogue_with_script(script.script_path)
	doors.component = component
	check("unchanged declaration key localizes", read(doors, "base", "title").get_string() == "Titre base")
	for asset in ["child", "grandchild"]:
		check(asset + " uses authoring override scalar key", read(doors, asset, "title").get_string() == "Titre enfant")
		check(asset + " override array localizes", read(doors, asset, "list").get_array()[0].get_string() == "Liste enfant")
		var entries: Dictionary = read(doors, asset, "map").get_map()
		check(asset + " map key is opaque", entries.keys() == [MAP_KEY])
		check(asset + " override map value localizes", entries[MAP_KEY].get_string() == "Carte enfant")
	check("nearest authored override wins", read(doors, "leaf", "title").get_string() == "Titre feuille")
	for asset in ["base", "child", "grandchild"]:
		var literal := "title.value" if asset == "base" else "data.child.title.value"
		check(asset + " declaration opt-out scalar", read(doors, asset, "literal").get_string() == literal)
		check(asset + " declaration opt-out array", read(doors, asset, "literal-list").get_array()[0].get_string() == literal)
		check(asset + " declaration opt-out map", read(doors, asset, "literal-map").get_map()[MAP_KEY].get_string() == literal)
	manager.set_language("es")
	check("language switch refreshes override", read(doors, "grandchild", "title").get_string() == "Titulo hijo")
	check("missing translation uses override source", read(doors, "child", "list").get_array()[0].get_string() == "Child list")
	check("raw resolver retains authored key", Store.try_resolve(manager.get_data_asset_seed(), {}, "child", "title").get_string() == "data.child.title.value")
	check("session scalar write succeeds", manager.set_data_asset_string("child", "Title", "data.leaf.title.value"))
	check("session array write succeeds", manager.set_data_asset_array("child", "List", [VariantValue.from_string("data.child.list.value.0")]))
	check("session map write succeeds", manager.set_data_asset_map("child", "Map", [MAP_KEY], [VariantValue.from_string("data.child.map.value." + MAP_KEY)]))
	manager.set_language("fr")
	check("session scalar stays literal through inheritance", read(doors, "grandchild", "title").get_string() == "data.leaf.title.value")
	check("save succeeds", manager.save_to_slot(SLOT))
	manager.reset_data_assets()
	check("reset restores authored override localization", read(doors, "child", "title").get_string() == "Titre enfant")
	component.stop_dialogue()
	check("restore succeeds", manager.load_from_slot(SLOT))
	component.start_dialogue_with_script(script.script_path)
	check("restored scalar stays literal", read(doors, "grandchild", "title").get_string() == "data.leaf.title.value")
	check("restored array stays literal", read(doors, "grandchild", "list").get_array()[0].get_string() == "data.child.list.value.0")
	check("restored map stays literal", read(doors, "grandchild", "map").get_map()[MAP_KEY].get_string() == "data.child.map.value." + MAP_KEY)
	component.stop_dialogue()
	component.free()

func read(doors, asset: String, variable: String):
	var result: Dictionary = doors.read(asset, variable)
	check("host and bound node agree: " + asset + "." + variable, result.agree and result.host != null)
	return result.host

func _test_versions() -> void:
	for version in [null, 1, "2", 2]:
		var doc := document()
		if version == null:
			doc.erase("localizationVersion")
		else:
			doc.localizationVersion = version
		import_inline(doc)
		var expected := "Titre enfant" if version is int and version == 2 else "data.child.title.value"
		check("version gate " + str(version), manager.get_data_asset_string("child", "Title") == expected)
		check("legacy declaration still translates " + str(version), manager.get_data_asset_string("base", "Title") == "Titre base")
		check("opt-out applies in every version " + str(version), manager.get_data_asset_string("base", "Literal") == "title.value")

func _test_disk_reload() -> void:
	var build := temp_root.path_join("build")
	var output := temp_root.path_join("out")
	DirAccess.make_dir_recursive_absolute(build)
	write_json(build.path_join("project.storyflow"), {"version": "1.0", "metadata": {"title": "Override locale"}})
	write_json(build.path_join("localization.json"), localization())
	write_json(build.path_join("data-assets.json"), document())
	var importer := Importer.new()
	manager.set_project(importer.import_project(build, output))
	manager.set_language("fr")
	check("disk numeric version enables overrides", manager.get_data_asset_string("child", "Title") == "Titre enfant")
	manager.set_project(importer.load_project_local(output))
	manager.set_language("fr")
	check("copied import reload retains version", manager.get_data_asset_string("grandchild", "Title") == "Titre enfant")
	check("copied import retains opt-out", manager.get_data_asset_string("child", "Literal") == "data.child.title.value")
	var legacy := document()
	legacy.erase("localizationVersion")
	write_json(build.path_join("data-assets.json"), legacy)
	manager.set_project(importer.import_project(build, output))
	manager.set_language("fr")
	check("legacy reimport replaces version two", manager.get_data_asset_string("child", "Title") == "data.child.title.value")
	manager.set_project(importer.load_project_local(output))
	manager.set_language("fr")
	check("legacy reload does not retain stale version", manager.get_data_asset_string("child", "Title") == "data.child.title.value")

func write_json(path: String, value: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(value))
	file.close()

## The current export's accessor subset, vendored verbatim alongside the frozen legacy package.
## Character-resolution and overlay-only cases retain their existing dedicated contract reader.
func _test_shared_v2_export() -> void:
	var doc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(SHARED_V2 + "data-assets.json"))
	var translations: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(SHARED_V2 + "localization.json"))
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(SHARED_V2 + "localization-resolution.json"))
	check("shared v2 export version", doc.get("localizationVersion") == 2)
	var project = Importer.new().import_project_from_json({"version": "1.0", "dataAssets": doc, "localization": translations})
	manager.set_project(project)
	var doors := Doors.new()
	doors.doc = doc
	var targets: Dictionary = {}
	var localized_cases: Array = []
	var literal_cases: Array = []
	for c in fixture.get("cases", []):
		var kind := str(c.get("kind", ""))
		if kind == "data-asset-localized":
			localized_cases.append(c)
		elif kind == "unkeyed":
			literal_cases.append(c)
		else:
			continue
		targets[str(c.dataAssetId) + "|" + str(c.variableId)] = {"assetId": c.dataAssetId, "variableId": c.variableId}
	check("shared localized accessor count", localized_cases.size() == 14)
	check("shared literal accessor count", literal_cases.size() == 3)
	var script = doors.probe_script("shared-v2-probe.sfe", targets.values())
	project.scripts[script.script_path] = script
	var component := Component.new()
	component.dialogue_ui_scene = null
	root.add_child(component)
	component.start_dialogue_with_script(script.script_path)
	doors.component = component
	# Keep the same store and component across language changes, including switching back.
	for language in ["fr", "es", "fr"]:
		manager.set_language(language)
		for c in localized_cases:
			if c.language != language:
				continue
			var declaration: Dictionary = doors.declaration_json(c.variableId)
			var actual = read(doors, c.dataAssetId, c.variableId)
			check("shared " + c.case, _fixture_value(actual, declaration) == c.expected)
			var raw = Store.try_resolve(manager.get_data_asset_seed(), {}, c.dataAssetId, c.variableId)
			check("shared authored bytes " + c.case, _fixture_value(raw, declaration) == c.storedValue)
		for c in literal_cases:
			check("shared " + c.case + " " + language, read(doors, c.dataAssetId, c.variableId).get_string() == c.expected[language])
	component.stop_dialogue()
	component.free()

func _fixture_value(value, declaration: Dictionary):
	if value == null:
		return null
	if bool(declaration.get("isArray", false)):
		var items: Array = []
		for item in value.get_array():
			items.append(item.get_string())
		return items
	if declaration.get("type") == "map":
		var entries: Array = []
		var map: Dictionary = value.get_map()
		for key in map:
			entries.append({"key": key, "value": map[key].get_string()})
		return entries
	return value.get_string()

func _remove_temp(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for entry in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(entry))
	for entry in DirAccess.get_directories_at(path):
		_remove_temp(path.path_join(entry))
	DirAccess.remove_absolute(path)
