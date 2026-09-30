extends SceneTree
const Importer = preload("res://addons/storyflow/editor/storyflow_importer.gd")
const Manager = preload("res://addons/storyflow/core/storyflow_manager.gd")
const Project = preload("res://addons/storyflow/core/storyflow_project.gd")
const Character = preload("res://addons/storyflow/core/storyflow_character.gd")
const Context = preload("res://addons/storyflow/core/storyflow_execution_context.gd")
const Text = preload("res://addons/storyflow/core/storyflow_text_interpolator.gd")
const V = preload("res://addons/storyflow/core/storyflow_variant.gd")
const Types = preload("res://addons/storyflow/core/storyflow_types.gd")
var checks := 0
var failures := 0
func check(label: String, actual, expected) -> void:
	checks += 1
	if actual != expected:
		failures += 1
		printerr("FAIL: %s expected %s got %s" % [label, str(expected), str(actual)])
func _initialize() -> void:
	await process_frame
	_shared_fixture()
	var imp = Importer.new()
	var p = Project.new()
	p.data_assets = imp._parse_data_assets({
		"base": {"id":"base", "variables":[{"id":"hp","name":"HP","type":"integer","value":10},{"id":"owner","name":"Owner","type":"character","value":"hero.sfc"},{"id":"next","name":"Next","type":"dataAsset","value":"other"},{"id":"title","name":"Title","type":"string","value":"title"},{"id":"list","name":"List","type":"integer","isArray":true,"value":[1]}]},
		"child": {"id":"child","parent":"base","variables":[],"overrides":{"hp":20}},
		"other": {"id":"other","variables":[{"id":"hp2","name":"HP","type":"integer","value":30},{"id":"next2","name":"Next","type":"dataAsset","value":"child"}]}})
	var hero = Character.new()
	hero.character_name = "Hero"
	hero.variables = imp._parse_character_variables({"stats":{"name":"Stats","type":"dataAsset","value":"child"},"dot":{"name":"Skill.Level","type":"integer","value":17},"literal":{"name":"Literal","type":"string","value":"{count}"}})
	p.characters["hero.sfc"] = hero
	p.global_strings = {"en.title":"Knight", "en.hero_title":"Captain"}
	p.has_localization = true
	p.languages = [{"code":"es","name":"Spanish"}]
	p.language_strings = {"es":{"title":"Caballero","hero_title":"Capitan"}}
	hero.variables["Title"] = imp._parse_character_variables({"title":{"name":"Title","type":"string","value":"hero_title"}})["Title"]
	var mgr = Manager.new()
	mgr.name = "StoryFlowRuntime"
	root.add_child(mgr)
	mgr.set_project(p)
	var ctx = Context.new()
	ctx.localization = mgr.get_localization()
	ctx.local_variables = imp._parse_variables([{"id":"db","name":"DB","type":"dataAsset","value":"child"},{"id":"player","name":"Player","type":"character","value":"hero.sfc"}])
	ctx.local_variable_name_index = {"DB":"db","Player":"player"}
	var text = Text.new()
	text.set_context(ctx)
	text.set_manager(mgr)
	check("Data imported", Types.parse_variable_type("dataAsset") != Types.VariableType.NONE, true)
	check("mixed inherited finite path", text.interpolate("{DB.Owner.Stats.Next.Next.HP} {Player.Skill.Level}"), "20 17")
	check("Data string", text.interpolate("{Player.Stats.Title}"), "Knight")
	var bad = "{DB} {DB.List} {DB.HP.More} {DB.Owner} {DB.Unknown}"
	check("invalid leaves preserved", text.interpolate(bad), bad)
	check("insertions not reexpanded", text.interpolate("{Player.Literal}"), "{count}")
	mgr.set_data_asset_int("child", "HP", 45)
	check("live overlay", text.interpolate("{Player.Stats.HP}"), "45")
	mgr.reset_all_state()
	check("reset", text.interpolate("{Player.Stats.HP}"), "20")
	mgr.get_runtime_character("hero.sfc").variables["Stats"]["value"] = V.from_string("other")
	check("live reassignment", text.interpolate("{Player.Stats.HP}"), "30")
	check("save live references", mgr.save_to_slot("data_reference_parity_test"), true)
	mgr.reset_all_state()
	check("reference reset", text.interpolate("{Player.Stats.HP}"), "20")
	check("load live references", mgr.load_from_slot("data_reference_parity_test"), true)
	check("reference restored", text.interpolate("{Player.Stats.HP}"), "30")
	mgr.get_runtime_character("hero.sfc").variables["Stats"]["value"] = V.from_string("child")
	mgr.set_language("es")
	check("live Data localization", text.interpolate("{Player.Stats.Title}"), "Caballero")
	check("live Character localization", text.interpolate("{DB.Owner.Title}"), "Capitan")
	mgr.set_data_asset_string("child", "Title", "title")
	check("Data key-shaped write literal", text.interpolate("{Player.Stats.Title}"), "title")
	var component = preload("res://addons/storyflow/core/storyflow_component.gd").new()
	root.add_child(component)
	component.set_character_variable("hero.sfc", "Title", V.from_string("hero_title"))
	check("Character key-shaped write literal", text.interpolate("{DB.Owner.Title}"), "hero_title")
	component.free()
	check("save literals", mgr.save_to_slot("data_reference_parity_test"), true)
	mgr.reset_all_state()
	check("reset localized author text", text.interpolate("{DB.Owner.Title}"), "Capitan")
	check("load literals", mgr.load_from_slot("data_reference_parity_test"), true)
	check("Character literal restored", text.interpolate("{DB.Owner.Title}"), "hero_title")
	check("Data literal restored", text.interpolate("{Player.Stats.Title}"), "title")
	mgr.delete_save("data_reference_parity_test")
	ctx.local_variables["db"]["value"] = V.from_string("hero.sfc")
	check("correct kind", text.interpolate("{DB.Name}"), "{DB.Name}")
	mgr.free()
	print("nested references: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)

func _shared_fixture() -> void:
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/engine-contract/nested-reference-interpolation.json"))
	var imp = Importer.new()
	var project = Project.new()
	project.data_assets = imp._parse_data_assets(fixture.dataAssets)
	for row in fixture.characters:
		var character = Character.new()
		character.character_name = row.name
		character.character_path = Character.normalize_path(row.path)
		var raw := {}
		for field in row.variables:
			raw[field.id] = field
		character.variables = imp._parse_character_variables(raw)
		project.characters[character.character_path] = character
		project.character_id_index[row.id] = character.character_path
	var mgr = Manager.new()
	root.add_child(mgr)
	mgr.set_project(project)
	var ctx = Context.new()
	ctx.current_dialogue_state = preload("res://addons/storyflow/core/storyflow_dialogue_state.gd").new()
	ctx.current_dialogue_state.character = preload("res://addons/storyflow/core/storyflow_character_data.gd").new()
	ctx.current_dialogue_state.character.character_path = fixture.assignedCharacterId
	var text = Text.new()
	text.set_context(ctx)
	text.set_manager(mgr)
	for case in fixture.cases:
		ctx.local_variables = imp._parse_variables(case.get("roots", fixture.roots))
		ctx.build_variable_name_index(ctx.local_variables, false)
		check("shared: " + case.name, text.interpolate(case.text), case.expected)
	# A known identity requires a live store hit even when presentation data survives.
	ctx.current_dialogue_state.character.name = "stale"
	mgr.get_runtime_characters().erase(Character.normalize_path(fixture.characters[0].path))
	check("stale speaker", text.interpolate("{Character.Name}"), "{Character.Name}")
	mgr.free()
