extends SceneTree

const Importer = preload("res://addons/storyflow/editor/storyflow_importer.gd")
const Manager = preload("res://addons/storyflow/core/storyflow_manager.gd")
const Component = preload("res://addons/storyflow/core/storyflow_component.gd")
const Context = preload("res://addons/storyflow/core/storyflow_execution_context.gd")
const Evaluator = preload("res://addons/storyflow/core/storyflow_evaluator.gd")
const Locale = preload("res://addons/storyflow/core/storyflow_localization.gd")
const Value = preload("res://addons/storyflow/core/storyflow_variant.gd")
const Save = preload("res://addons/storyflow/core/storyflow_save_data.gd")
const Character = preload("res://addons/storyflow/core/storyflow_character.gd")
const Types = preload("res://addons/storyflow/core/storyflow_types.gd")

var checks := 0
var failures := 0

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("FAIL: " + label)

func localized(source: String, target: String):
	return Importer.new().import_project_from_json({"version": "1.0", "localization": {
		"schemaVersion": "1", "sourceLanguage": source,
		"languages": [{"code": target, "name": target}], "strings": {target: {"key": "Translated"}}
	}})

func _initialize() -> void:
	await process_frame
	_test_languages()
	_test_arrays()
	_test_map_value_projection()
	_test_character_name_provenance()
	_test_reimport()
	_test_project_replacement()
	print("ALL %d CHECKS PASSED" % checks if failures == 0 else "%d OF %d CHECKS FAILED" % [failures, checks])
	quit(0 if failures == 0 else 1)

func _test_languages() -> void:
	var manager = Manager.new()
	root.add_child(manager)
	manager.set_project(localized("fr", "en"))
	check("first install uses French source even with English target", manager.get_language() == "fr")
	manager.set_language("EN")
	manager.set_project(localized("de", "en"))
	check("later install preserves actual host choice", manager.get_language() == "en")
	manager.free()

	manager = Manager.new()
	root.add_child(manager)
	manager.set_language("en")
	manager.set_project(localized("fr", "en"))
	check("explicit pre-install English choice survives", manager.get_language() == "en")
	manager.free()

	var project = localized("fr", "de")
	var locale = Locale.new()
	locale.install_from_project(project)
	check("legacy en source bucket resolves", Locale.look_up(locale, null, {"en.key": "Bonjour"}, "key", "en") == "Bonjour")
	check("new source bucket wins over legacy", Locale.look_up(locale, null, {"en.key": "Legacy", "fr.key": "Bonjour"}, "key", "en") == "Bonjour")
	locale.active_language = "de"
	check("target translation wins over source", Locale.look_up(locale, null, {"fr.key": "Bonjour"}, "key", "en") == "Translated")
	check("missing target falls back to legacy source", Locale.look_up(locale, null, {"en.missing": "Salut"}, "missing", "en") == "Salut")

func array_script():
	return Importer.new().import_script({
		"nodes": {"A": {"type": "getStringArray", "variable": "inventory"},
			"C": {"type": "arrayContainsString", "value": "C.value"},
			"F": {"type": "findInStringArray", "value": "F.value"},
			"E": {"type": "getStringArrayElement"},
			"S": {"type": "setDataAssetVariable", "variableType": "string", "isArray": true}},
		"connections": [
			{"source": "A", "target": "C", "sourceHandle": "source-A-string-array-", "targetHandle": "target-C-string-array-1"},
			{"source": "A", "target": "F", "sourceHandle": "source-A-string-array-", "targetHandle": "target-F-string-array-1"},
			{"source": "A", "target": "E", "sourceHandle": "source-A-string-array-", "targetHandle": "target-E-string-array-1"},
			{"source": "A", "target": "S", "sourceHandle": "source-A-string-array-", "targetHandle": "target-S-string-array-2"}],
		"variables": [{"id": "inventory", "name": "Inventory", "type": "string", "isArray": true, "value": ["inventory.value.0"]}],
		"strings": {"en": {"inventory.value.0": "Sword", "C.value": "Sword", "F.value": "Sword"}}
	})

func _test_arrays() -> void:
	var script = array_script()
	var context = Context.new()
	context.current_script = script
	context.local_variables = Value.deep_copy_variables(script.variables)
	var evaluator = Evaluator.new()
	evaluator.initialize(context, {})
	check("Contains reads authored array text", evaluator.evaluate_boolean_from_node("C"))
	check("Find reads authored array text", evaluator.evaluate_integer_from_node("F") == 0)
	check("element reads authored array text", evaluator.evaluate_string_from_node("E") == "Sword")
	var element = context.local_variables.inventory.value.get_array()[0]
	check("search does not replace stored key", element.get_string() == "inventory.value.0")
	var saved = Save._variable_to_json("inventory", context.local_variables.inventory)
	context.local_variables.inventory = Save._variable_from_json("inventory", saved)
	check("authored key survives save/load", evaluator.evaluate_integer_from_node("F") == 0)
	context.local_variables.inventory.value.set_array([Value.from_string("inventory.value.0")])
	check("runtime key-shaped literal is not translated", evaluator.evaluate_integer_from_node("F") == -1)
	check("runtime key-shaped element is displayed literally", evaluator.evaluate_string_from_node("E") == "inventory.value.0")
	saved = Save._variable_to_json("inventory", context.local_variables.inventory)
	context.local_variables.inventory = Save._variable_from_json("inventory", saved)
	check("runtime literal stays literal after save/load", evaluator.evaluate_integer_from_node("F") == -1)
	context.local_variables.inventory.value.set_array([Value.from_string("Sword")])
	check("runtime prose remains searchable", evaluator.evaluate_integer_from_node("F") == 0)
	var project = localized("en", "fr")
	project.language_strings.fr = {"inventory.value.0": "Epee", "C.value": "Epee", "F.value": "Epee"}
	context.localization = Locale.new()
	context.localization.install_from_project(project)
	context.localization.active_language = "fr"
	context.local_variables = Value.deep_copy_variables(script.variables)
	check("array search follows active language", evaluator.evaluate_integer_from_node("F") == 0)
	check("array element follows active language", evaluator.evaluate_string_from_node("E") == "Epee")
	var manager = Manager.new()
	manager.name = "StoryFlowRuntime"
	root.add_child(manager)
	project.global_variables = script.variables
	project.global_strings = script.strings
	manager.set_project(project)
	var component = Component.new()
	component.dialogue_ui_scene = null
	root.add_child(component)
	component._context = context
	component._evaluator = evaluator
	var setter = script.get_node("S")
	var written = component._read_data_asset_set_input(setter, setter.data)
	check("data asset array write captures active prose", written.get_array()[0].get_string() == "Epee")
	context.localization.active_language = "en"
	check("data asset array snapshot stays literal after language switch", evaluator._array_string(written.get_array()[0]) == "Epee")
	check("data asset array write leaves authored source intact", element.get_string() == "inventory.value.0")
	check("asset elements keep raw keys", component._type_data_asset_element(Types.VariableType.IMAGE, element).get_string() == "inventory.value.0")
	check("enum elements keep raw keys", component._type_data_asset_element(Types.VariableType.ENUM, element).get_string() == "inventory.value.0")
	check("host array getter resolves authored element", component.get_array_variable("Inventory")[0].get_string() == "Sword")
	component.set_string_array_variable("Inventory", ["inventory.value.0"])
	check("host array getter preserves runtime key-shaped literal", component.get_array_variable("Inventory")[0].get_string() == "inventory.value.0")
	component.free()
	manager.free()

func _check_character_name(label: String, component, expected: String) -> void:
	check(label + " host", component.get_character_variable("hero", "cf_name").get_string() == expected)
	check(label + " graph", component._evaluator.evaluate_string_from_node("G") == expected)
	check(label + " speaker", component._build_dialogue_state({"id": "D", "data": {"character": "hero"}}).character.name == expected)
	check(label + " interpolation", component._text._resolve_character_field(Value.from_string("hero"), "Name", "hero.Name") == expected)


func _test_map_value_projection() -> void:
	var script = Importer.new().import_script({
		"nodes": {"M": {"type": "getMap", "variable": "m"},
			"V": {"type": "mapValues", "keyType": "string", "valueType": "string"},
			"K": {"type": "mapKeys", "keyType": "string", "valueType": "string"},
			"E": {"type": "getStringArrayElement"}, "R": {"type": "getRandomStringArrayElement"},
			"F": {"type": "forEachStringLoop"}, "KE": {"type": "getStringArrayElement"},
			"C": {"type": "arrayContainsString", "value": "needle"}},
		"connections": [
			{"source": "M", "target": "V", "sourceHandle": "source-M-map-string-string-", "targetHandle": "target-V-map-string-string-1"},
			{"source": "M", "target": "K", "sourceHandle": "source-M-map-string-string-", "targetHandle": "target-K-map-string-string-1"},
			{"source": "K", "target": "KE", "sourceHandle": "source-K-string-array-", "targetHandle": "target-KE-string-array-1"},
			{"source": "V", "target": "E", "sourceHandle": "source-V-string-array-", "targetHandle": "target-E-string-array-1"},
			{"source": "V", "target": "R", "sourceHandle": "source-V-string-array-", "targetHandle": "target-R-string-array-1"},
			{"source": "V", "target": "C", "sourceHandle": "source-V-string-array-", "targetHandle": "target-C-string-array-1"}],
		"variables": [{"id": "m", "name": "Map", "type": "map", "keyType": "string", "valueType": "string",
			"value": [{"key": "m.value.0", "value": "m.value.0"}]}],
		"strings": {"en": {"m.value.0": "Sword", "needle": "Sword"}}
	})
	var context = Context.new()
	context.current_script = script
	context.local_variables = Value.deep_copy_variables(script.variables)
	var evaluator = Evaluator.new()
	evaluator.initialize(context, {})
	check("mapValues element resolves authored prose", evaluator.evaluate_string_from_node("E") == "Sword")
	check("mapValues random element resolves authored prose", evaluator.evaluate_string_from_node("R") == "Sword")
	check("mapValues membership resolves authored prose", evaluator.evaluate_boolean_from_node("C"))
	context.get_node_state("F").cached_output = context.local_variables.m.value.get_map()["m.value.0"].duplicate_variant()
	check("mapValues foreach element resolves authored prose", evaluator.evaluate_string_from_node("F") == "Sword")
	check("mapKeys stays literal beside localized values", evaluator.evaluate_string_from_node("KE") == "m.value.0")
	var project = localized("en", "fr")
	project.language_strings.fr = {"m.value.0": "Epee"}
	context.localization = Locale.new()
	context.localization.install_from_project(project)
	context.localization.active_language = "fr"
	check("mapValues follows active language", evaluator.evaluate_string_from_node("E") == "Epee")
	var saved = Save._variable_to_json("m", context.local_variables.m)
	context.local_variables.m = Save._variable_from_json("m", saved)
	check("mapValues authored provenance survives save", evaluator.evaluate_string_from_node("E") == "Epee")
	context.local_variables.m.value.get_map()["m.value.0"] = Value.from_string("m.value.0")
	check("mapValues runtime key-shaped string stays literal", evaluator.evaluate_string_from_node("E") == "m.value.0")
	saved = Save._variable_to_json("m", context.local_variables.m)
	context.local_variables.m = Save._variable_from_json("m", saved)
	check("mapValues runtime literal survives save", evaluator.evaluate_string_from_node("E") == "m.value.0")
	check("projection leaves imported source intact", script.variables.m.value.get_map()["m.value.0"].get_string() == "m.value.0")

func _test_character_name_provenance() -> void:
	var manager = Manager.new()
	manager.name = "StoryFlowRuntime"
	root.add_child(manager)
	var project = localized("en", "fr")
	project.global_strings = {"en.hero.cf_name": "Knight"}
	project.language_strings.fr = {"hero.cf_name": "Chevalier", "S.value": "hero.cf_name"}
	var hero = Character.new()
	hero.character_path = "hero"
	hero.character_name = "hero.cf_name"
	project.characters.hero = hero
	project.character_id_index.da_hero = "hero"
	manager.set_project(project)
	manager.set_language("fr")
	var component = Component.new()
	component.dialogue_ui_scene = null
	root.add_child(component)
	component._context.current_script = Importer.new().import_script({"nodes": {
		"G": {"type": "getCharacterVar", "characterPath": "hero", "variableName": "Name", "variableType": "string"},
		"S": {"type": "setCharacterVar", "characterPath": "hero", "variableName": "Name", "variableType": "string", "value": "S.value"}
	}})
	component._context.localization = manager.get_localization()
	component._evaluator = Evaluator.new()
	component._evaluator.initialize(component._context, {}, manager.get_runtime_characters(), "en", project.global_strings, manager)
	component._text.set_manager(manager)
	_check_character_name("authored name localizes", component, "Chevalier")
	var slot = "localization_name_%d" % Time.get_ticks_usec()
	check("authored name saves", manager.save_to_slot(slot))
	component.set_character_variable("hero", "cf_name", Value.from_string("hero.cf_name"))
	_check_character_name("runtime key-shaped name stays literal", component, "hero.cf_name")
	check("authored save restores", manager.load_from_slot(slot))
	_check_character_name("authored save retains localization", component, "Chevalier")
	component.set_character_variable("hero", "cf_name", Value.from_string("hero.cf_name"))
	check("runtime name saves", manager.save_to_slot(slot))
	manager.reset_runtime_characters()
	_check_character_name("reset restores authored identity", component, "Chevalier")
	check("runtime name restores", manager.load_from_slot(slot))
	_check_character_name("runtime save retains literal identity", component, "hero.cf_name")
	var saved = Save._serialize_characters(manager.get_runtime_characters())
	saved.hero.erase("nameIsLiteral")
	write_json(Save.SAVE_DIR + slot + ".json", {"version": "1", "characters": saved})
	manager.reset_runtime_characters()
	check("legacy ambiguous name restores", manager.load_from_slot(slot))
	_check_character_name("legacy ambiguous name stays literal", component, "hero.cf_name")
	manager.reset_runtime_characters()
	check("data asset host writes name", component.set_data_asset_string("da_hero", "cf_name", "hero.cf_name"))
	_check_character_name("data asset name write stays literal", component, "hero.cf_name")
	check("duplicated runtime name keeps provenance", manager.get_runtime_character("hero").duplicate_character().name_is_literal)
	manager.reset_runtime_characters()
	component._handle_set_character_var(component._context.current_script.get_node("S"))
	_check_character_name("graph name write stays literal", component, "hero.cf_name")
	DirAccess.remove_absolute(Save.SAVE_DIR + slot + ".json")
	component.free()
	manager.free()

func write_json(path: String, value: Dictionary) -> void:
	var file = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(value))

func _test_reimport() -> void:
	var directory = OS.get_user_data_dir().path_join("localization_hardening_%d" % Time.get_ticks_usec())
	var source = directory.path_join("source")
	var output = directory.path_join("output")
	DirAccess.make_dir_recursive_absolute(source)
	write_json(source.path_join("project.storyflow"), {"version": "1.0"})
	write_json(source.path_join("localization.json"), {"schemaVersion": "1", "sourceLanguage": "en", "languages": [], "strings": {}})
	Importer.new().import_project(source, output)
	write_json(output.path_join("user.json"), {"keep": true})
	DirAccess.remove_absolute(source.path_join("localization.json"))
	Importer.new().import_project(source, output)
	check("removed sidecar does not survive output reload", not Importer.new().load_project_local(output).has_localization)
	check("reimport preserves unrelated user file", FileAccess.file_exists(output.path_join("user.json")))
	remove_tree(directory)

func remove_tree(path: String) -> void:
	for file in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file))
	for directory in DirAccess.get_directories_at(path):
		remove_tree(path.path_join(directory))
	DirAccess.remove_absolute(path)

func _test_project_replacement() -> void:
	var manager = Manager.new()
	manager.name = "StoryFlowRuntime"
	root.add_child(manager)
	var old = Importer.new().import_project_from_json({"version": "1.0", "globalStrings": {"en": {"key": "OLD"}}})
	var script = Importer.new().import_script({"nodes": {"0": {"type": "start"}, "D": {"type": "dialogue", "text": "key"}}, "connections": [{"source": "0", "target": "D", "sourceHandle": "source-0-", "targetHandle": "target-D-"}]})
	old.scripts["main.json"] = script
	manager.set_project(old)
	var component = Component.new()
	component.dialogue_ui_scene = null
	root.add_child(component)
	component.start_dialogue_with_script("main.json")
	check("replacement test starts real dialogue", component._context.is_executing)
	manager.set_project(Importer.new().import_project_from_json({"version": "1.0", "globalStrings": {"en": {"key": "NEW"}}}))
	check("live evaluator reads incoming source strings", component._evaluator._resolve_string_key("key") == "NEW")
	check("live evaluator data-asset locale reads incoming source strings", component._evaluator._data_asset_locale().global_strings.get("en.key") == "NEW")
	component.stop_dialogue()
	component.free()
	manager.free()
