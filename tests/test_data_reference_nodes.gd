extends SceneTree
const Importer = preload("res://addons/storyflow/editor/storyflow_importer.gd")
const Manager = preload("res://addons/storyflow/core/storyflow_manager.gd")
const Project = preload("res://addons/storyflow/core/storyflow_project.gd")
const Component = preload("res://addons/storyflow/core/storyflow_component.gd")
const Context = preload("res://addons/storyflow/core/storyflow_execution_context.gd")
const Evaluator = preload("res://addons/storyflow/core/storyflow_evaluator.gd")
const V = preload("res://addons/storyflow/core/storyflow_variant.gd")
const Types = preload("res://addons/storyflow/core/storyflow_types.gd")
const Graph = preload("res://tests/data_asset_test_graph.gd")
var checks := 0
var failures := 0
func check(label: String, actual, expected) -> void:
	checks += 1
	if actual != expected:
		failures += 1
		printerr("FAIL: %s expected %s got %s" % [label, str(expected), str(actual)])
func n(id: String, kind: String, data: Dictionary = {}) -> Dictionary:
	check("known " + kind, Types.parse_node_type(kind) != Types.NodeType.UNKNOWN, true)
	return Graph.node(id, Types.parse_node_type(kind), kind, data)
func _initialize() -> void:
	await process_frame
	var imp = Importer.new()
	var project = Project.new()
	project.data_assets = imp._parse_data_assets({"child":{"id":"child","variables":[{"id":"hp","name":"HP","type":"integer","value":20},{"id":"next","name":"Next","type":"dataAsset","value":"other"},{"id":"refs","name":"Refs","type":"dataAsset","isArray":true,"value":["other"]}]},"other":{"id":"other","variables":[{"id":"hp","name":"HP","type":"integer","value":30}]}})
	var manager = Manager.new()
	manager.name = "StoryFlowRuntime"
	root.add_child(manager)
	manager.set_project(project)
	var exported_element = imp.import_script({
		"nodes":{"EL":{"type":"setDataAssetArrayElement","value1":0,"value2":"other"}},
		"connections":[
			{"source":"INDEX","target":"EL","sourceHandle":"source-INDEX-integer-","targetHandle":"target-EL-integer-3"},
			{"source":"P","target":"EL","sourceHandle":"source-P-dataAsset-","targetHandle":"target-EL-dataAsset-4"},
			{"source":"A","target":"EL","sourceHandle":"source-A-dataAsset-array-","targetHandle":"target-EL-dataAsset-array-2"}]})
	var nodes = {
		"0":Graph.start(), "P":Graph.pill("P", "child"),
		"S":n("S","setDataAssetRef",{"variable":"ref"}),
		"G":n("G","getDataAssetRef",{"variable":"ref"}),
		"A":n("A","getDataAssetRefArray",{"variable":"refs"}),
		"ADD":n("ADD","addToDataAssetArray"),
		"E":n("E","getDataAssetArrayElement",{"value":1}),
		"R":n("R","getRandomDataAssetArrayElement"),
		"L":n("L","arrayLengthDataAsset"),
		"C":n("C","arrayContainsDataAsset",{"value":"child"}),
		"F":n("F","findInDataAssetArray",{"value":"child"}),
		"DA":Graph.accessor("DA",{"variableId":"hp","variableType":"integer"}),
		"NEXT":Graph.accessor("NEXT",{"variableId":"next","variableType":"dataAsset"}),
		"HP":Graph.accessor("HP",{"variableId":"hp","variableType":"integer"}),
		"M":n("M","getMap",{"variable":"map","keyType":"string","valueType":"dataAsset"}),
		"MV":n("MV","getMapValue",{"keyType":"string","valueType":"dataAsset","key":"slot"}),
		"TXT":n("TXT","getString",{"variable":"text"}),
		"CALL":n("CALL","runScript",{"script":"callee.sfe","scriptParameters":[{"id":"in","name":"Param","type":"dataAsset"},{"id":"list","name":"List","type":"dataAsset","isArray":true}],"scriptOutputs":[{"id":"out","name":"Param","type":"dataAsset"},{"id":"arr","name":"List","type":"dataAsset","isArray":true}]}),
		"ARR":n("ARR","setDataAssetRefArray",{"variable":"copy"}),
		"EL":exported_element.nodes.EL,
		"INDEX":n("INDEX","getInt",{"variable":"idx"}),
		"DAARR":Graph.accessor("DAARR",{"variableId":"refs","variableType":"dataAsset","isArray":true}),
		"DAEL":n("DAEL","setDataAssetArrayElement",{"value1":V.from_int(0),"value2":V.from_string("child")}),
		"RSW":Graph.setter("RSW",{"variableId":"next","variableType":"dataAsset"}),
		"RSWA":Graph.setter("RSWA",{"variableId":"refs","variableType":"dataAsset","isArray":true}),
		"LOOP":n("LOOP","forEachDataAssetLoop"),
		"BODY":n("BODY","setDataAssetRef",{"variable":"ref"}),
		"REMOVE":n("REMOVE","removeFromDataAssetArray",{"value":V.from_int(0)}),
		"CLEAR":n("CLEAR","clearDataAssetArray"),
		"MW":n("MW","setMapValue",{"keyType":"string","valueType":"dataAsset","key":"slot"}),
		"DW":Graph.setter("DW",{"variableId":"next","variableType":"dataAsset"}),
		"D":Graph.dialogue("D")}
	var edges = [Graph.exec("0","S"),Graph.exec_flow("S","ADD"),Graph.exec_flow("ADD","CALL"),Graph.edge("CALL","source-CALL-output","D","target-D-"),
		Graph.data_wire("P","dataAsset","S","dataAsset-2"),
		Graph.data_wire("G","dataAsset","CALL","dataAsset-param-in"),Graph.data_wire("A","dataAsset-array","CALL","dataAsset-array-param-list"),
		Graph.data_wire("A","dataAsset-array","ADD","dataAsset-array-2"),Graph.data_wire("G","dataAsset","ADD","dataAsset-3"),
		Graph.pill_wire("G","DA"),Graph.pill_wire("G","NEXT"),Graph.pill_wire("NEXT","HP"),
		Graph.map_wire("M","MV","string","dataAsset","1"),
		Graph.pill_wire("P","DAARR"),Graph.data_wire("DAARR","dataAsset-array","DAEL","dataAsset-array-2"),
		Graph.pill_wire("P","RSW"),Graph.pill_wire("P","RSWA"),
		Graph.edge("CALL","source-CALL-out-out","RSW","target-RSW-dataAsset-2"),
		Graph.edge("CALL","source-CALL-out-arr","RSWA","target-RSWA-dataAsset-array-2"),
		Graph.data_wire("A","dataAsset-array","LOOP","dataAsset-array-loop"),
		Graph.edge("LOOP","source-LOOP-loopBody","BODY","target-BODY-"),
		Graph.edge("LOOP","source-LOOP-completed","D","target-D-"),
		Graph.data_wire("LOOP","dataAsset","BODY","dataAsset-2"),
		Graph.data_wire("A","dataAsset-array","REMOVE","dataAsset-array-2"),
		Graph.data_wire("A","dataAsset-array","CLEAR","dataAsset-array-2"),
		Graph.map_wire("M","MW","string","dataAsset","2"),Graph.data_wire("P","dataAsset","MW","dataAsset-4"),
		Graph.pill_wire("P","DW"),Graph.data_wire("P","dataAsset","DW","dataAsset-2"),
		Graph.edge("CALL","source-CALL-out-arr","ARR","target-ARR-dataAsset-array-1")]
	edges.append_array(exported_element.connections)
	for id in ["E","R","L","C","F"]:
		edges.append(Graph.data_wire("A","dataAsset-array",id,"dataAsset-array-1"))
	var variables = imp._parse_variables([
		{"id":"idx","name":"Index","type":"integer","value":1},
		{"id":"ref","name":"DB","type":"dataAsset","value":""},
		{"id":"refs","name":"Refs","type":"dataAsset","isArray":true,"value":["other"]},
		{"id":"copy","name":"Copy","type":"dataAsset","isArray":true,"value":[]},
		{"id":"map","name":"Map","type":"map","keyType":"string","valueType":"dataAsset","value":[{"key":"slot","value":"other"}]},
		{"id":"text","name":"Text","type":"string","value":"child"}])
	var script = Graph.build("data-ref.sfe",nodes,edges,variables)
	project.scripts[script.script_path] = script
	project.scripts["callee.sfe"] = Graph.build("callee.sfe", {"0":Graph.start(),"END":n("END","end")}, [Graph.exec("0","END")], imp._parse_variables([
		{"id":"p","name":"Param","type":"dataAsset","value":"","isInput":true,"isOutput":true},
		{"id":"a","name":"List","type":"dataAsset","value":[],"isArray":true,"isInput":true,"isOutput":true}]))
	var component = Component.new()
	component.dialogue_ui_scene = null
	root.add_child(component)
	component.start_dialogue_with_script(script.script_path)
	var eval = component._evaluator
	check("Set/Get reference",eval.evaluate_data_from_node("G"),"child")
	check("reference binds accessor",eval.evaluate_integer_from_node("DA"),20)
	check("accessor reference chains",eval.evaluate_integer_from_node("HP"),30)
	check("array append",eval.evaluate_integer_from_node("L"),2)
	check("array element",eval.evaluate_data_from_node("E"),"child")
	check("random array reference",eval.evaluate_data_from_node("R") in ["child","other"],true)
	check("contains",eval.evaluate_boolean_from_node("C"),true)
	check("find",eval.evaluate_integer_from_node("F"),1)
	check("map reference",eval.evaluate_data_from_node("MV"),"other")
	check("string not reference",eval.evaluate_data_from_node("TXT"),"")
	check("executed RunScript scalar param/output",eval.evaluate_data_from_node("CALL","source-CALL-out-out"),"child")
	check("executed RunScript array param/output",eval.evaluate_data_array_input("ARR","dataAsset-array").size(),2)
	var state = component._context.get_node_state("CALL")
	state.has_output_values = true
	state.output_values = {"out":V.from_string("other"),"arr":V.from_array([V.from_string("child")])}
	state.output_arrays = {"out":false,"arr":true}
	check("RunScript scalar",eval.evaluate_data_from_node("CALL","source-CALL-out-out"),"other")
	check("RunScript array",eval.evaluate_data_array_input("ARR","dataAsset-array").size(),1)
	component._process_node(nodes.ARR)
	check("set array stores refs",component._context.local_variables.copy.value.get_array()[0].get_string(),"child")
	component._context.local_variables.refs.value = V.from_array([V.from_string("other"),V.from_string("other")])
	component._process_node(nodes.EL)
	check("wired index overrides exported fallback",component._context.local_variables.refs.value.get_array()[0].get_string(),"other")
	check("set element uses Data pin",component._context.local_variables.refs.value.get_array()[1].get_string(),"child")
	var cached = component._context.get_node_state("EL").cached_output
	check("exported element caches result", cached != null, true)
	component._process_node(nodes.DAEL)
	check("exported element writes accessor array", manager.get_data_asset_variant("child","Refs").get_array()[0].get_string(),"child")
	# Failed Data output reads must poison the enclosing Data Asset write, never clear it.
	state.has_output_values = false
	var incomplete_before = component._context.resolution_failures
	eval.evaluate_data_from_node("CALL","source-CALL-out-out")
	check("unfinished scalar call signals failure",component._context.resolution_failures > incomplete_before,true)
	incomplete_before = component._context.resolution_failures
	eval.evaluate_data_array_input("ARR","dataAsset-array")
	check("unfinished array call signals failure",component._context.resolution_failures > incomplete_before,true)
	state.has_output_values = true
	var malformed = [null,V.from_int(9),V.from_array([])]
	for value in malformed:
		state.output_values = {} if value == null else {"out":value}
		state.output_arrays = {"out":value != null and value.get_array().is_empty() and value.type == Types.VariableType.NONE}
		var before = component._context.resolution_failures
		eval.evaluate_data_from_node("CALL","source-CALL-out-out")
		check("malformed scalar signals failure",component._context.resolution_failures > before,true)
		component._process_node(nodes.RSW)
		check("malformed scalar refuses write",manager.get_data_asset_variant("child","Next").get_string(),"other")
	for value in [null,V.from_string("other"),V.from_array([V.from_int(9)])]:
		state.output_values = {} if value == null else {"arr":value}
		state.output_arrays = {"arr":false if value is V and value.type == Types.VariableType.STRING else true}
		var before = component._context.resolution_failures
		eval.evaluate_data_array_input("ARR","dataAsset-array")
		check("malformed array signals failure",component._context.resolution_failures > before,true)
		component._process_node(nodes.RSWA)
		check("malformed array refuses write",manager.get_data_asset_variant("child","Refs").get_array().size(),1)
	# A caller's stale Data declaration cannot legitimize a callee's string output, even empty.
	project.scripts["callee.sfe"].variables.p.type = Types.VariableType.STRING
	project.scripts["callee.sfe"].variables.a.type = Types.VariableType.STRING
	project.scripts["callee.sfe"].variables.a.value = V.from_array([])
	nodes.CALL.data.scriptParameters = []
	component._process_node(nodes.CALL)
	var before = component._context.resolution_failures
	eval.evaluate_data_from_node("CALL","source-CALL-out-out")
	check("actual output type overrides caller scalar declaration",component._context.resolution_failures > before,true)
	before = component._context.resolution_failures
	eval.evaluate_data_array_input("ARR","dataAsset-array")
	check("empty output uses actual declared element type",component._context.resolution_failures > before,true)
	component._process_node(nodes.LOOP)
	check("Data foreach element",eval.evaluate_data_from_node("G"),"child")
	component._process_node(nodes.MW)
	check("Data map write",eval.evaluate_data_from_node("MV"),"child")
	component._process_node(nodes.DW)
	check("Data field write",eval.evaluate_integer_from_node("HP"),20)
	component._process_node(nodes.REMOVE)
	check("Data array remove",component._context.local_variables.refs.value.get_array().size(),1)
	component._process_node(nodes.CLEAR)
	check("Data array clear",component._context.local_variables.refs.value.get_array().size(),0)
	component.stop_dialogue()
	component.free()
	manager.free()
	_test_data_array_isolation()
	print("data reference nodes: %d checks, %d failures" % [checks,failures])
	quit(1 if failures else 0)


func _array_strings(values: Array) -> Array:
	var result := []
	for value in values:
		result.append(value.get_string())
	return result


func _array_source_value(component, manager, kind: String) -> Array:
	match kind:
		"script": return component._context.local_variables.refs.value.get_array()
		"global": return manager.get_global_variables().refs.value.get_array()
		"character": return manager.get_runtime_character("hero.sfc").variables.Refs.value.get_array()
		_: return manager.get_data_asset_variant("asset", "Refs").get_array()


func _test_data_array_isolation() -> void:
	var imp = Importer.new()
	for kind in ["script", "global", "character", "data"]:
		var project = Project.new()
		var rows = [{"id":"refs","name":"Refs","type":"dataAsset","isArray":true,"value":["start"]},
			{"id":"char","name":"CharacterRef","type":"character","value":"da_hero"}]
		project.character_id_index = {"da_hero":"hero.sfc","da_decoy":"decoy.sfc"}
		project.global_variables = imp._parse_variables(rows)
		project.data_assets = imp._parse_data_assets({"asset":{"id":"asset","variables":[rows[0]]}})
		for path in ["hero.sfc", "decoy.sfc"]:
			var character = preload("res://addons/storyflow/core/storyflow_character.gd").new()
			character.variables = imp._parse_character_variables({"refs":rows[0]})
			project.characters[path] = character
		var manager = Manager.new()
		manager.name = "StoryFlowRuntime"
		root.add_child(manager)
		manager.set_project(project)
		var source = n("SOURCE", "getDataAssetRefArray", {"variable":"refs", "isGlobal":kind == "global"})
		if kind == "character":
			source = n("SOURCE", "getCharacterVar", {"characterPath":"decoy.sfc","characterId":"da_decoy","variableName":"Refs","variableType":"dataAsset","isArray":true})
		elif kind == "data":
			source = Graph.accessor("SOURCE", {"variableId":"refs","variableType":"dataAsset","isArray":true})
		var nodes = {"0":Graph.start(),"D":Graph.dialogue("D"),"SOURCE":source,
			"CHAR":n("CHAR","getCharacter",{"variable":"char"}),"P":Graph.pill("P","asset"),"VALUE":Graph.pill("VALUE","extra"),
			"ADD":n("ADD","addToDataAssetArray"),"ADD2":n("ADD2","addToDataAssetArray",{"value":"third"}),
			"REMOVE":n("REMOVE","removeFromDataAssetArray",{"value":V.from_int(0)}),
			"CLEAR":n("CLEAR","clearDataAssetArray"),"DIRECT":n("DIRECT","clearDataAssetArray")}
		var edges = [Graph.exec("0","D"),Graph.pill_wire("P","SOURCE"),
			Graph.data_wire("CHAR","character","SOURCE","character-character-input"),
			Graph.data_wire("SOURCE","dataAsset-array","ADD","dataAsset-array-2"),
			Graph.data_wire("VALUE","dataAsset","ADD","dataAsset-3"),
			Graph.data_wire("SOURCE","dataAsset-array","DIRECT","dataAsset-array-2")]
		for op in ["ADD2","REMOVE","CLEAR"]:
			edges.append(Graph.data_wire("ADD","dataAsset-array",op,"dataAsset-array-2"))
		var script = Graph.build("isolation.sfe",nodes,edges,imp._parse_variables(rows))
		project.scripts[script.script_path] = script
		var component = Component.new()
		component.dialogue_ui_scene = null
		root.add_child(component)
		component.start_dialogue_with_script(script.script_path)
		var original = _array_source_value(component,manager,kind)
		component._process_node(nodes.ADD)
		check(kind + " immediate add writes target",_array_strings(_array_source_value(component,manager,kind)),["start","extra"])
		check(kind + " original input snapshot detached",_array_strings(original),["start"])
		var result = component._context.get_node_state("ADD").cached_output.get_array()
		for op in ["CLEAR","REMOVE","ADD2"]:
			component._process_node(nodes[op])
			check(kind + " chained " + op + " preserves original",_array_strings(_array_source_value(component,manager,kind)),["start","extra"])
			check(kind + " chained " + op + " preserves source output",_array_strings(result),["start","extra"])
			var expected_output = {"CLEAR":[],"REMOVE":["extra"],"ADD2":["start","extra","third"]}[op]
			check(kind + " chained " + op + " result",_array_strings(component._context.get_node_state(op).cached_output.get_array()),expected_output)
		var live = _array_source_value(component,manager,kind)
		live.append(V.from_string("host"))
		live[0].set_string("host-updated")
		check(kind + " stored target does not alias output",_array_strings(result),["start","extra"])
		component._process_node(nodes.DIRECT)
		check(kind + " direct clear writes target",_array_strings(_array_source_value(component,manager,kind)),[])
		check(kind + " direct clear preserves previous output",_array_strings(result),["start","extra"])
		if kind == "character":
			check("wired character write leaves inline decoy unchanged",_array_strings(manager.get_runtime_character("decoy.sfc").variables.Refs.value.get_array()),["start"])
		component.stop_dialogue()
		component.free()
		manager.free()
