extends SceneTree
const G=preload("res://tests/data_asset_test_graph.gd")
const T=preload("res://addons/storyflow/core/storyflow_types.gd")
const V=preload("res://addons/storyflow/core/storyflow_variant.gd")
const C=preload("res://addons/storyflow/core/storyflow_component.gd")
const I=preload("res://addons/storyflow/editor/storyflow_importer.gd")
const M=preload("res://addons/storyflow/core/storyflow_manager.gd")
const Save=preload("res://addons/storyflow/core/storyflow_save_data.gd")
var checks=0
var failures=0
func check(label:String,ok:bool):
	checks+=1
	if not ok:
		failures+=1
		printerr("FAIL: ",label)
func _initialize():
	await process_frame
	var mgr=M.new()
	mgr.name="StoryFlowRuntime"
	root.add_child(mgr)
	var project=I.new().import_project_from_json({"version":"1.0","dataAssets":{"asset":{"id":"asset","name":"Stats","variables":[
		{"id":"count","name":"Count","type":"integer","value":7},
		{"id":"flag","name":"Flag","type":"boolean","value":false},
		{"id":"list","name":"List","type":"integer","isArray":true,"value":[7]},
		{"id":"rank","name":"Rank","type":"enum","enumValues":["Ready"],"value":"Ready"}
	]}}})
	var script=G.build("probe.json",{
		"0":G.start(),"P":G.pill("P","asset"),"G":G.node("G",T.NodeType.GET_INT,"getInt",{"variable":"removed"}),
		"W":G.setter("W",{"variableId":"count","variable":"Count","variableType":"integer"}),"D":G.dialogue("D"),
		"B":G.accessor("B",{"variableId":"flag","variable":"Flag","variableType":"boolean"}),
		"N":G.node("N",T.NodeType.NOT_BOOL,"notBool",{}),
		"A":G.node("A",T.NodeType.ADD_TO_STRING_ARRAY,"addToStringArray",{})
	},[G.exec("0","D"),G.exec_flow("W","D"),G.pill_wire("P","W"),G.data_wire("G","integer","W","integer-2"),G.pill_wire("P","B"),G.data_wire("B","boolean","N","boolean-")])
	project.scripts["probe.json"]=script
	mgr.set_project(project)
	var components=[]
	for index in 2:
		var component=C.new()
		component.dialogue_ui_scene=null
		root.add_child(component)
		component.start_dialogue_with_script("probe.json")
		components.append(component)
		check("derived condition initially true",component._evaluator.evaluate_boolean_from_node("N"))
		component._context.get_node_state("A").cached_output=V.from_string("completed result")
	check("manager write succeeds",mgr.set_data_asset_bool("asset","Flag",true))
	for component in components:
		check("all contexts see manager write",not component._evaluator.evaluate_boolean_from_node("N"))
		check("execution result survives shared invalidation",component._context.get_node_state("A").cached_output!=null)
	mgr.reset_data_assets()
	check("reset invalidates condition",components[1]._evaluator.evaluate_boolean_from_node("N"))
	components[0]._handle_set_data_asset_var(script.get_node("W"))
	check("missing getter source refuses write",mgr.get_data_asset_int("asset","Count")==7)
	check("manager has generic getter",mgr.has_method("get_data_asset_variant"))
	if mgr.has_method("get_data_asset_variant"):
		var values=mgr.get_data_asset_variant("Stats","List")
		check("generic getter reads array",values.get_array()[0].get_int()==7)
		values.get_array().clear()
		check("generic getter returns detached array",mgr.get_data_asset_variant("asset","List").get_array().size()==1)
	var seed=mgr.get_data_asset_seed()
	var restored=Save._deserialize_data_assets({"asset":{"list":[1,"old"],"count":1.5,"rank":"Old"}},seed)
	check("incompatible saved slots dropped",restored.is_empty())
	restored=Save._deserialize_data_assets({"asset":{"list":[],"count":0,"rank":"Ready"}},seed)
	check("valid empty and zero saved slots survive",restored.get("asset",{}).size()==3)
	check("out-of-range saved integer dropped",Save._bare_value_from_json(9223372036854775808.0,{"type":T.VariableType.INTEGER})==null)
	check("nonfinite saved float dropped",Save._bare_value_from_json(INF,{"type":T.VariableType.FLOAT})==null)
	test_empty_array_shape(mgr,project)
	test_scalar_shape(mgr,project)
	test_character_bridge_cache(mgr,project)
	test_detached_map_result(mgr)
	test_detached_map_text(mgr)
	test_map_shape(mgr)
	test_migration_fixture()
	test_previously_evaluated_boolean_sources(mgr)
	test_enum_metadata_does_not_fail_value_resolution(mgr)
	mgr.set_project(project)
	test_chained_sources(mgr, project)
	for component in components:
		component.stop_dialogue()
		component.free()
	mgr.free()
	print("ALL %d CHECKS PASSED"%checks if failures==0 else "%d OF %d CHECKS FAILED"%[failures,checks])
	quit(0 if failures==0 else 1)

func test_previously_evaluated_boolean_sources(mgr):
	var project=I.new().import_project_from_json({"version":"1.0","dataAssets":{"asset":{"id":"asset","variables":[
		{"id":"flag","name":"Flag","type":"boolean","value":true}
	]}}})
	for scenario in ["missingBool","missingRunOutput","validBoolFalse","completedRunFalse"]:
		var run_output=scenario in ["missingRunOutput","completedRunFalse"]
		var valid=scenario in ["validBoolFalse","completedRunFalse"]
		var source=G.node("G",T.NodeType.RUN_SCRIPT,"runScript",{}) if run_output else G.node("G",T.NodeType.GET_BOOL,"getBool",{"variable":"source"})
		var wire=G.edge("G","source-G-out-result","W","target-W-boolean-2") if run_output else G.data_wire("G","boolean","W","boolean-2")
		var variables={"source":{"id":"source","type":T.VariableType.BOOLEAN,"value":V.from_bool(false)}} if scenario=="validBoolFalse" else {}
		var script=G.build("cached-source.json",{"0":G.start(),"D":G.dialogue("D"),"P":G.pill("P","asset"),"G":source,"W":G.setter("W",{"variableId":"flag","variableType":"boolean"})},[G.exec("0","D"),G.exec_flow("W","D"),G.pill_wire("P","W"),wire],variables)
		project.scripts["cached-source.json"]=script
		mgr.set_project(project)
		var component=C.new()
		component.dialogue_ui_scene=null
		root.add_child(component)
		component.start_dialogue_with_script("cached-source.json")
		if scenario=="completedRunFalse":
			var state=component._context.get_node_state("G")
			state.output_values={"result":V.from_bool(false)}
			state.has_output_values=true
		check("boolean source first displays false "+scenario,not component._evaluator.evaluate_boolean_from_node("G",wire.source_handle))
		component._handle_set_data_asset_var(script.get_node("W"))
		check("previously evaluated boolean source write "+scenario,mgr.get_data_asset_bool("asset","Flag")==not valid)
		component.stop_dialogue()
		component.free()

func test_enum_metadata_does_not_fail_value_resolution(mgr):
	var project=I.new().import_project_from_json({"version":"1.0","dataAssets":{"asset":{"id":"asset","variables":[
		{"id":"rank","name":"Rank","type":"enum","enumValues":["Old","Ready"],"value":"Old"}
	]}}})
	for scenario in ["intToEnum","stringToEnum","missingGetter"]:
		var source=G.node("CONV",T.NodeType.INT_TO_ENUM,"intToEnum",{"value":1})
		if scenario=="stringToEnum":
			source=G.node("CONV",T.NodeType.STRING_TO_ENUM,"stringToEnum",{"value":"Ready"})
		elif scenario=="missingGetter":
			source=G.node("CONV",T.NodeType.GET_ENUM,"getEnum",{"variable":"removed"})
		var nodes={"0":G.start(),"D":G.dialogue("D"),"P":G.pill("P","asset"),"CONV":source,"BAD":G.node("BAD",T.NodeType.SET_ENUM,"setEnum",{"variable":"removed"}),"GOOD":G.node("GOOD",T.NodeType.SET_ENUM,"setEnum",{"variable":"enumvar"}),"W":G.setter("W",{"variableId":"rank","variableType":"enum"})}
		# Neither enum consumer executes. Their metadata supplies the converter's options.
		var edges=[G.exec("0","D"),G.exec_flow("W","D"),G.pill_wire("P","W"),G.data_wire("CONV","enum","BAD","enum-2"),G.data_wire("CONV","enum","GOOD","enum-2"),G.data_wire("CONV","enum","W","enum-2")]
		var script=G.build("enum-metadata.json",nodes,edges,{"enumvar":{"id":"enumvar","name":"EnumVar","type":T.VariableType.ENUM,"enum_values":["Old","Ready"],"value":V.from_enum("Old")}})
		project.scripts["enum-metadata.json"]=script
		mgr.set_project(project)
		var component=C.new()
		component.dialogue_ui_scene=null
		root.add_child(component)
		component.start_dialogue_with_script("enum-metadata.json")
		component._handle_set_data_asset_var(script.get_node("W"))
		check("enum metadata ignores unused orphan but rejects evaluated missing getter "+scenario,mgr.get_data_asset_enum("asset","Rank")==("Old" if scenario=="missingGetter" else "Ready"))
		component.stop_dialogue()
		component.free()

func test_migration_fixture():
	var fixture=JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/engine-contract/data-assets-migration.json"))
	var project=I.new().import_project_from_json({"version":"1.0","dataAssets":fixture.dataAssets})
	var store=load("res://addons/storyflow/core/storyflow_data_asset_store.gd")
	var seed={}
	store.build_seed(project,seed)
	var overlay=Save._deserialize_data_assets(fixture.saved,seed)
	check("shared migration overlay",JSON.parse_string(JSON.stringify(Save._serialize_data_assets(seed,overlay)))==fixture.expectedOverlay)
	for read in fixture.expectedReads:
		var value=store.try_read(seed,overlay,{},read.assetId,read.variableId)
		var declaration=store.find_declaration(seed,read.assetId,read.variableId)
		check("shared migration read "+read.assetId+"."+read.variableId,JSON.parse_string(JSON.stringify(Save._bare_value_to_json(value,declaration)))==read.value)

func test_chained_sources(mgr, project):
	for scenario in ["removed", "dead", "wrongtype", "missingAssetVariable", "missingCharacter", "fallback", "zero"]:
		mgr.reset_data_assets()
		var nodes={"0":G.start(),"P":G.pill("P","asset"),"D":G.dialogue("D"),"PLUS":G.node("PLUS",T.NodeType.PLUS,"plus",{"value1":0,"value2":0}),"W":G.setter("W",{"variableId":"count","variableType":"integer"})}
		var edges=[G.exec("0","D"),G.exec_flow("W","D"),G.pill_wire("P","W"),G.data_wire("PLUS","integer","W","integer-2")]
		var variables={}
		if scenario!="fallback":
			if scenario=="missingAssetVariable":
				nodes.G=G.accessor("G",{"variableId":"removed","variableType":"integer"})
				edges.append(G.pill_wire("P","G"))
			elif scenario=="missingCharacter":
				nodes.G=G.node("G",T.NodeType.GET_CHARACTER_VAR,"getCharacterVar",{"characterPath":"missing.sfc","variableName":"Count","variableType":"integer"})
			elif scenario!="dead":
				nodes.G=G.node("G",T.NodeType.GET_INT,"getInt",{"variable":"source"})
			edges.append(G.data_wire("G","integer","PLUS","integer-1"))
		if scenario=="wrongtype":
			variables.source={"id":"source","type":T.VariableType.STRING,"value":V.from_string("bad")}
		if scenario=="zero":
			variables.source={"id":"source","type":T.VariableType.INTEGER,"value":V.from_int(0)}
		var script=G.build("chain.json",nodes,edges,variables)
		project.scripts["chain.json"]=script
		var component=C.new()
		component.dialogue_ui_scene=null
		root.add_child(component)
		component.start_dialogue_with_script("chain.json")
		component._evaluator.evaluate_integer_from_node("PLUS")
		component._handle_set_data_asset_var(script.get_node("W"))
		check("source scenario "+scenario,mgr.get_data_asset_int("asset","Count")== (0 if scenario in ["fallback","zero"] else 7))
		component.stop_dialogue()
		component.free()

func test_map_shape(mgr):
	for empty in [false,true]:
		var project=I.new().import_project_from_json({"version":"1.0","dataAssets":{"maps":{"id":"maps","name":"Maps","variables":[
			{"id":"source","name":"Source","type":"map","keyType":"string","valueType":"integer","value":[] if empty else [{"key":"a","value":1}]},
			{"id":"dest","name":"Dest","type":"map","keyType":"string","valueType":"string","value":[]}
		]}}})
		var script=G.build("maps.json",{"0":G.start(),"D":G.dialogue("D"),"P":G.pill("P","maps"),"G":G.accessor("G",{"variableId":"source","variableType":"map","keyType":"string","valueType":"integer"}),"W":G.setter("W",{"variableId":"dest","variableType":"map","keyType":"string","valueType":"string"})},[G.exec("0","D"),G.exec_flow("W","D"),G.pill_wire("P","G"),G.pill_wire("P","W"),G.data_wire("G","map-string-integer","W","map-string-string-2")])
		project.scripts["maps.json"]=script
		mgr.set_project(project)
		var component=C.new()
		component.dialogue_ui_scene=null
		root.add_child(component)
		component.start_dialogue_with_script("maps.json")
		component._handle_set_data_asset_var(script.get_node("W"))
		check("mismatched map refuses including empty="+str(empty),mgr.get_data_asset_overlay().is_empty())
		component.stop_dialogue()
		component.free()

func test_character_bridge_cache(mgr, project):
	var character=load("res://addons/storyflow/core/storyflow_character.gd").new()
	character.variables.Count={"type":T.VariableType.BOOLEAN,"value":V.from_bool(false)}
	mgr.get_runtime_characters()["hero.sfc"]=character
	mgr.get_character_id_bridge()["da_00000000000000000000000000000001"]="hero.sfc"
	var script=G.build("bridge.json",{"0":G.start(),"D":G.dialogue("D"),"G":G.node("G",T.NodeType.GET_CHARACTER_VAR,"getCharacterVar",{"characterPath":"hero.sfc","variableName":"Count"}),"N":G.node("N",T.NodeType.NOT_BOOL,"notBool",{})},[G.exec("0","D"),G.data_wire("G","boolean","N","boolean-")])
	project.scripts["bridge.json"]=script
	var components=[]
	for index in 2:
		var component=C.new()
		component.dialogue_ui_scene=null
		root.add_child(component)
		component.start_dialogue_with_script("bridge.json")
		components.append(component)
		check("bridge condition initially true",component._evaluator.evaluate_boolean_from_node("N"))
	check("manager character bridge write",mgr.set_data_asset_bool("da_00000000000000000000000000000001","Count",true))
	for component in components:
		check("shared character bridge condition invalidates",not component._evaluator.evaluate_boolean_from_node("N"))
		component.stop_dialogue()
		component.free()

func test_detached_map_result(mgr):
	var project=I.new().import_project_from_json({"version":"1.0","dataAssets":{"maps":{"id":"maps","name":"Maps","variables":[
		{"id":"source","name":"Source","type":"map","keyType":"string","valueType":"integer","value":[{"key":"old","value":1}]},
		{"id":"dest","name":"Dest","type":"map","keyType":"string","valueType":"integer","value":[]}
	]}}})
	var script=G.build("maps.json",{"0":G.start(),"D":G.dialogue("D"),"P":G.pill("P","maps"),"G":G.accessor("G",{"variableId":"source","variableType":"map","keyType":"string","valueType":"integer"}),"M":G.node("M",T.NodeType.SET_MAP_VALUE,"setMapValue",{"keyType":"string","valueType":"integer","key":"new","value":9}),"W":G.setter("W",{"variableId":"dest","variableType":"map","keyType":"string","valueType":"integer"})},[G.exec("0","D"),G.exec_flow("W","D"),G.pill_wire("P","G"),G.pill_wire("P","W"),G.map_wire("G","M","string","integer","2"),G.map_wire("M","W","string","integer","2")])
	project.scripts["maps.json"]=script
	mgr.set_project(project)
	var component=C.new()
	component.dialogue_ui_scene=null
	root.add_child(component)
	component.start_dialogue_with_script("maps.json")
	component._handle_map_modify(script.get_node("M"))
	check("detached map mutation preserves source",mgr.get_data_asset_variant("maps","Source").get_map().size()==1)
	mgr.reset_data_assets()
	component._handle_set_data_asset_var(script.get_node("W"))
	check("explicit map Set consumes detached mutation across invalidation",mgr.get_data_asset_variant("maps","Dest").get_map().size()==2)
	component.stop_dialogue()
	component.free()

func test_detached_map_text(mgr):
	for scenario in ["inline", "wiredAuthored", "wiredLiteral"]:
		for language in ["en", "fr"]:
			var importer=I.new()
			var project=importer.import_project_from_json({"version":"1.0","dataAssets":{"maps":{"id":"maps","variables":[
				{"id":"source","name":"Source","type":"map","keyType":"string","valueType":"string","value":[]},
				{"id":"dest","name":"Dest","type":"map","keyType":"string","valueType":"string","value":[]},
				{"id":"input","name":"Input","type":"string","value":""}
			]}},"localization":{"schemaVersion":"1","sourceLanguage":"en","languages":[{"code":"fr","name":"French"}],"strings":{"fr":{
				"M.value":"literal.fr", "literal.en":"Wrong French second lookup", "literal.fr":"Wrong French second lookup",
				"wired.key":"Wrong French wired lookup", "keep.key":"Wrong French existing lookup",
				"existing":"Wrong French key", "new":"Wrong French key"
			}}}})
			# Use the real import path: the exporter keys an inline string map value as M.value.
			var mutator=importer.import_script({"nodes":{"M":{"type":"setMapValue","keyType":"string","valueType":"string","key":"new","value":"M.value"}}}).get_node("M")
			var nodes={
				"0":G.start(), "D":G.dialogue("D"), "P":G.pill("P","maps"),
				"G":G.accessor("G",{"variableId":"source","variableType":"map","keyType":"string","valueType":"string"}),
				"M":mutator, "W":G.setter("W",{"variableId":"dest","variableType":"map","keyType":"string","valueType":"string"}),
				"DG":G.accessor("DG",{"variableId":"dest","variableType":"map","keyType":"string","valueType":"string"}),
				"R":G.node("R",T.NodeType.GET_MAP_VALUE,"getMapValue",{"keyType":"string","valueType":"string","key":"new"}),
				"AFTER":G.node("AFTER",T.NodeType.GET_MAP_VALUE,"getMapValue",{"keyType":"string","valueType":"string","key":"new"}),
				"KEEP":G.node("KEEP",T.NodeType.GET_MAP_VALUE,"getMapValue",{"keyType":"string","valueType":"string","key":"existing"}),
				"ML":G.node("ML",T.NodeType.FOR_EACH_MAP,"forEachMap",{"keyType":"string","valueType":"string"}),
				"DL":G.node("DL",T.NodeType.FOR_EACH_MAP,"forEachMap",{"keyType":"string","valueType":"string"}),
				"MV":G.node("MV",T.NodeType.MAP_VALUES,"mapValues",{"keyType":"string","valueType":"string"}),
				"MK":G.node("MK",T.NodeType.MAP_KEYS,"mapKeys",{"keyType":"string","valueType":"string"}),
				"VA":G.node("VA",T.NodeType.GET_STRING_ARRAY_ELEMENT,"getStringArrayElement",{"value":1}),
				"KA":G.node("KA",T.NodeType.GET_STRING_ARRAY_ELEMENT,"getStringArrayElement",{"value":1})
			}
			var edges=[G.exec("0","D"),G.exec_flow("W","D"),G.pill_wire("P","G"),G.pill_wire("P","W"),G.pill_wire("P","DG"),
				G.map_wire("G","M","string","string","2"),G.map_wire("M","W","string","string","2"),
				G.map_wire("M","R","string","string","1"),G.map_wire("DG","AFTER","string","string","1"),G.map_wire("DG","KEEP","string","string","1"),
				G.map_wire("M","ML","string","string","map"),G.map_wire("DG","DL","string","string","map"),
				G.edge("ML","source-ML-loopBody","D","target-D-"),G.edge("ML","source-ML-completed","D","target-D-"),
				G.edge("DL","source-DL-loopBody","D","target-D-"),G.edge("DL","source-DL-completed","D","target-D-"),
				G.map_wire("M","MV","string","string","1"),G.map_wire("M","MK","string","string","1"),
				G.data_wire("MV","string-array","VA","string-array"),G.data_wire("MK","string-array","KA","string-array")]
			if scenario=="wiredAuthored":
				nodes.INPUT=G.node("INPUT",T.NodeType.GET_STRING,"getString",{"variable":"word"})
				edges.append(G.data_wire("INPUT","string","M","string-4"))
			elif scenario=="wiredLiteral":
				nodes.INPUT=G.accessor("INPUT",{"variableId":"input","variableType":"string"})
				edges.append(G.pill_wire("P","INPUT"))
				edges.append(G.data_wire("INPUT","string","M","string-4"))
			var strings={"en.M.value":"literal.en", "en.literal.en":"Wrong English second lookup", "en.literal.fr":"Wrong English second lookup",
				"en.wired.key":"Wrong English wired lookup", "en.keep.key":"Wrong English existing lookup",
				"en.existing":"Wrong English key", "en.new":"Wrong English key"}
			var script=G.build("map-text.json",nodes,edges,{"word":{"id":"word","name":"Word","type":T.VariableType.STRING,"value":V.from_string("M.value")}},strings)
			project.scripts["map-text.json"]=script
			var reader=G.build("map-reader.json",{"0":nodes["0"],"D":nodes.D,"P":nodes.P,"DG":nodes.DG,"AFTER":nodes.AFTER,"KEEP":nodes.KEEP},
				[G.exec("0","D"),G.pill_wire("P","DG"),G.map_wire("DG","AFTER","string","string","1"),G.map_wire("DG","KEEP","string","string","1")],{},
				{"en.literal.en":"Wrong reader lookup","en.literal.fr":"Wrong reader lookup","en.wired.key":"Wrong reader lookup","en.keep.key":"Wrong reader lookup"})
			project.scripts["map-reader.json"]=reader
			mgr.set_project(project)
			mgr.set_language(language)
			mgr.set_data_asset_map("maps","Source",["existing"],[V.from_string("keep.key")])
			mgr.set_data_asset_string("maps","Input","wired.key")
			var component=C.new()
			component.dialogue_ui_scene=null
			root.add_child(component)
			component.start_dialogue_with_script("map-text.json")
			var expected="wired.key" if scenario=="wiredLiteral" else ("literal.fr" if language=="fr" else "literal.en")
			var label=scenario+" "+language
			component._handle_map_modify(script.get_node("M"))
			check("detached text is resolved once before Set "+label,component._evaluator.evaluate_string_from_node("R","source-R-string-value")==expected)
			check("detached mutation keeps source unchanged "+label,mgr.get_data_asset_variant("maps","Source").get_map().size()==1)
			# Completed output must survive a language switch and an unrelated shared write.
			mgr.set_language("en" if language=="fr" else "fr")
			mgr.set_data_asset_string("maps","Input","later")
			check("map values projection preserves captured text "+label,component._evaluator.evaluate_string_from_node("VA")==expected)
			check("map keys projection preserves literal key "+label,component._evaluator.evaluate_string_from_node("KA")=="new")
			component._handle_set_data_asset_var(script.get_node("W"))
			var saved=mgr.get_data_asset_variant("maps","Dest").get_map()
			check("host reads captured map text "+label,saved.get("new",V.new()).get_string()==expected)
			check("host preserves existing literal entry "+label,saved.get("existing",V.new()).get_string()=="keep.key")
			check("same script does not translate captured map text again "+label,component._evaluator.evaluate_string_from_node("AFTER","source-AFTER-string-value")==expected)
			check("same script preserves existing literal entry "+label,component._evaluator.evaluate_string_from_node("KEEP","source-KEEP-string-value")=="keep.key")
			# Normal W -> D dialogue entry refreshes derived values; the completed
			# mutation's output must remain available to downstream consumers.
			check("dialogue entry preserves detached map value "+label,component._evaluator.evaluate_string_from_node("R","source-R-string-value")==expected)
			check("dialogue entry preserves map values projection "+label,component._evaluator.evaluate_string_from_node("VA")==expected)
			check("dialogue entry preserves map keys projection "+label,component._evaluator.evaluate_string_from_node("KA")=="new")
			for loop_id in ["ML","DL"]:
				component._handle_for_each_map(script.get_node(loop_id))
				check("map loop preserves existing literal key "+loop_id+" "+label,component._evaluator.evaluate_string_from_node(loop_id,"source-"+loop_id+"-string-key")=="existing")
				check("map loop preserves existing literal value "+loop_id+" "+label,component._evaluator.evaluate_string_from_node(loop_id,"source-"+loop_id+"-string-value")=="keep.key")
				check("loop cache refresh preserves detached map value "+loop_id+" "+label,component._evaluator.evaluate_string_from_node("R","source-R-string-value")==expected)
				check("loop cache refresh preserves map values projection "+loop_id+" "+label,component._evaluator.evaluate_string_from_node("VA")==expected)
				component._continue_for_each_loop(loop_id)
				check("map loop preserves added literal key "+loop_id+" "+label,component._evaluator.evaluate_string_from_node(loop_id,"source-"+loop_id+"-string-key")=="new")
				check("map loop preserves captured text "+loop_id+" "+label,component._evaluator.evaluate_string_from_node(loop_id,"source-"+loop_id+"-string-value")==expected)
				component._continue_for_each_loop(loop_id)
			component.stop_dialogue()
			component.start_dialogue_with_script("map-reader.json")
			check("other script reads captured map text "+label,component._evaluator.evaluate_string_from_node("AFTER","source-AFTER-string-value")==expected)
			check("other script preserves existing literal entry "+label,component._evaluator.evaluate_string_from_node("KEEP","source-KEEP-string-value")=="keep.key")
			component.stop_dialogue()
			component.start_dialogue_with_script("map-text.json")
			check("fresh context clears completed detached output "+label,component._evaluator.evaluate_string_from_node("R","source-R-string-value")=="" and component._evaluator.evaluate_string_from_node("VA")=="")
			component.stop_dialogue()
			component.free()

func test_scalar_shape(mgr,project):
	var character=load("res://addons/storyflow/core/storyflow_character.gd").new()
	character.character_name="Hero"
	character.image_key="hero.png"
	mgr.get_runtime_characters()["hero.sfc"]=character
	for scenario in ["Name","Image","runScriptArray","runScriptEmptyArray"]:
		mgr.reset_data_assets()
		var source=G.node("G",T.NodeType.GET_CHARACTER_VAR,"getCharacterVar",{"characterPath":"hero.sfc","variableName":scenario,"variableType":"integer"})
		var wire=G.data_wire("G","integer","W","integer-2")
		if scenario.begins_with("runScript"):
			source=G.node("G",T.NodeType.RUN_SCRIPT,"runScript",{"scriptOutputs":[{"id":"result","type":"integer","isArray":true}]})
			wire=G.edge("G","source-G-out-result","W","target-W-integer-2")
		var script=G.build("shape.json",{"0":G.start(),"D":G.dialogue("D"),"P":G.pill("P","asset"),"G":source,"W":G.setter("W",{"variableId":"count","variableType":"integer"})},[G.exec("0","D"),G.exec_flow("W","D"),G.pill_wire("P","W"),wire])
		project.scripts["shape.json"]=script
		var component=C.new()
		component.dialogue_ui_scene=null
		root.add_child(component)
		component.start_dialogue_with_script("shape.json")
		if scenario.begins_with("runScript"):
			var value=V.from_array([] if scenario=="runScriptEmptyArray" else [V.from_int(42)])
			value.type=T.VariableType.INTEGER
			var state=component._context.get_node_state("G")
			state.output_values={"result":value}
			state.has_output_values=true
		component._handle_set_data_asset_var(script.get_node("W"))
		check("scalar source shape refuses "+scenario,mgr.get_data_asset_int("asset","Count")==7)
		component.stop_dialogue()
		component.free()

func test_empty_array_shape(mgr,project):
	var character=load("res://addons/storyflow/core/storyflow_character.gd").new()
	var value=V.from_array([])
	value.type=T.VariableType.STRING
	character.variables.List={"type":T.VariableType.STRING,"is_array":true,"value":value}
	mgr.get_runtime_characters()["hero.sfc"]=character
	for scenario in ["ordinary","character","runScript"]:
		mgr.reset_data_assets()
		var source=G.node("G",T.NodeType.GET_STRING_ARRAY,"getStringArray",{"variable":"source"})
		if scenario=="character":
			source=G.node("G",T.NodeType.GET_CHARACTER_VAR,"getCharacterVar",{"characterPath":"hero.sfc","variableName":"List"})
		elif scenario=="runScript":
			source=G.node("G",T.NodeType.RUN_SCRIPT,"runScript",{})
		var script=G.build("empty-array.json",{"0":G.start(),"D":G.dialogue("D"),"P":G.pill("P","asset"),"G":source,"W":G.setter("W",{"variableId":"list","variableType":"integer","isArray":true})},[G.exec("0","D"),G.exec_flow("W","D"),G.pill_wire("P","W"),G.data_wire("G","string-array","W","integer-array-2")],{"source":{"id":"source","type":T.VariableType.STRING,"is_array":true,"value":value}})
		project.scripts["empty-array.json"]=script
		var component=C.new()
		component.dialogue_ui_scene=null
		root.add_child(component)
		component.start_dialogue_with_script("empty-array.json")
		var state=component._context.get_node_state("G")
		state.output_values={"result":value}
		state.has_output_values=true
		component._handle_set_data_asset_var(script.get_node("W"))
		check(scenario+" empty wrong-type array refuses whole Set",mgr.get_data_asset_overlay().is_empty())
		component.stop_dialogue()
		component.free()
