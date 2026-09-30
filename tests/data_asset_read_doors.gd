extends RefCounted
## THE TWO .sfd READ DOORS, driven together — the host accessors on StoryFlowComponent and the
## node lane's bound accessor — over one vendored data-assets.json.
##
## NOT A TEST. It exists because localization spec §2's amendment (2026-08-27) put a RULE on the
## .sfd read path (a declaration localizes; an override and a session write never do), and a rule
## that held at one door and not the other is a bug neither door's own test can see. Two files
## need to ask both doors — the golden package's `unkeyed` arm in tests/test_character_contract.gd
## and the engine-owned pins in tests/test_data_asset_localization.gd — so the driver lives once,
## for the same reason tests/data_asset_test_graph.gd owns the handle formats.
##
## THE ACCESSOR SNAPSHOT COMES FROM THE EXPORTER'S OWN BYTES. Each probe accessor's contract 2.2
## pins (variableType / isArray / keyType / valueType) are read off the declaration in
## data-assets.json rather than converted back out of the imported seed, so the §6.1 declMatches
## gate passes for the right reason and a snapshot this file invented can never be what a read is
## proved against.
##
## DECLARATIONS ARE FOUND BY SCANNING EVERY ASSET, not by walking one chain. That is not a
## shortcut, it is the id rule itself: a .sfd id carries no asset segment BECAUSE a variable is
## declared at exactly one level of exactly one chain, so a scan cannot find two. It is also what
## the callers need, since an override case names the asset carrying the OVERRIDE while the
## declaration — and the snapshot — live on an ancestor.

const Graph := preload("res://tests/data_asset_test_graph.gd")

## The vendored data-assets.json document, as parsed.
var doc: Dictionary = {}

## The component whose dialogue is parked on the probe script. Set by the caller after it runs
## [method probe_script] through its own component lifecycle, which differs per test file.
var component = null

## "<assetId>|<variableId>" -> the probe accessor's node id. Sequential ids, deliberately: a node
## id is interpolated into every handle string, and the ones this repo's graphs use are short and
## punctuation-free.
var _accessor_ids: Dictionary = {}


## One declaration's raw JSON, or {} when no asset declares the id.
func declaration_json(variable_id: String) -> Dictionary:
	var assets = doc.get("dataAssets", {})
	if not assets is Dictionary:
		return {}
	for asset_id in assets:
		var asset = assets[asset_id]
		if not asset is Dictionary:
			continue
		var variables = asset.get("variables", [])
		if not variables is Array:
			continue
		for declaration in variables:
			if declaration is Dictionary and str(declaration.get("id", "")) == variable_id:
				return declaration
	return {}


## The stored bytes of one target as the ARTIFACT carries them: an `overrides` entry when
## [param from] is "override", otherwise the declaration's own `value`. What a harness that only
## byte-compared would have looked at — read here so a drifted literal is caught as a stale case
## rather than silently changing what the doors are compared against.
func stored_bytes(asset_id: String, variable_id: String, from: String) -> String:
	if from == "override":
		var asset = doc.get("dataAssets", {}).get(asset_id, {})
		if asset is Dictionary:
			var overrides = asset.get("overrides", {})
			if overrides is Dictionary:
				return str(overrides.get(variable_id, ""))
		return ""
	return str(declaration_json(variable_id).get("value", ""))


## The probe script: one reference pill per asset named by [param targets], one accessor per
## target, and a dialogue to park the component on so the evaluator stays live. [param targets]
## is `[{ "assetId", "variableId" }]`; a target whose variable no asset declares is SKIPPED, which
## keeps a caller's typo out of the ladder rungs rather than turning it into a degraded read.
func probe_script(path: String, targets: Array) -> StoryFlowScript:
	var nodes := {"0": Graph.start(), "D": Graph.dialogue("D")}
	var connections: Array = [Graph.exec("0", "D")]
	var pills: Dictionary = {}
	_accessor_ids.clear()

	for target in targets:
		var asset_id := str(target.get("assetId", ""))
		var variable_id := str(target.get("variableId", ""))
		var declaration := declaration_json(variable_id)
		if declaration.is_empty():
			continue
		if not pills.has(asset_id):
			var pill_id := "P%d" % pills.size()
			pills[asset_id] = pill_id
			nodes[pill_id] = Graph.pill(pill_id, asset_id)
		var accessor_id := "G%d" % _accessor_ids.size()
		_accessor_ids["%s|%s" % [asset_id, variable_id]] = accessor_id
		nodes[accessor_id] = Graph.accessor(accessor_id, pins_from(declaration, variable_id))
		connections.append(Graph.pill_wire(pills[asset_id], accessor_id))

	return Graph.build(path, nodes, connections)


## The contract 2.2 node payload for one declaration, in the exporter's own wire tokens. PUBLIC
## because a caller building a graph this file does not build - a container read wired downstream
## of an accessor - still needs its accessor's snapshot to come from the exporter's bytes.
func pins_from(declaration: Dictionary, variable_id: String) -> Dictionary:
	var data := {
		"variableId": variable_id,
		"variable": str(declaration.get("name", "")),
		"variableType": str(declaration.get("type", "")),
	}
	if bool(declaration.get("isArray", false)):
		data["isArray"] = true
	if declaration.has("keyType"):
		data["keyType"] = str(declaration["keyType"])
	if declaration.has("valueType"):
		data["valueType"] = str(declaration["valueType"])
	return data


## THE NODE LANE'S READ DOOR: the one function every typed accessor arm funnels through, asked
## through a REAL pill -> accessor graph so the binding and the §6.1 gate are exercised, not
## bypassed. Null when no probe accessor was built for this target or the read degraded.
func node_read(asset_id: String, variable_id: String):
	if component == null:
		return null
	var accessor_id := str(_accessor_ids.get("%s|%s" % [asset_id, variable_id], ""))
	if accessor_id.is_empty():
		return null
	var node: Dictionary = component._context.current_script.get_node(accessor_id)
	if node.is_empty():
		return null
	return component._evaluator._evaluate_data_asset_variable(node.get("data", {}), accessor_id)


## THE HOST DOOR, driven the way game code drives it: by the display NAME an author typed. The
## name is taken from the seed's own declaration, so the id -> name -> id round trip at that
## boundary is exercised too.
##
## The UNTYPED door, because it is the one that answers every shape (a scalar, an array and a map
## through one call). The typed family shares its gate but not its code path, which is why the
## seed-versus-written pin drives that one.
func host_read(asset_id: String, variable_id: String):
	if component == null:
		return null
	var variable_name := str(declaration_json(variable_id).get("name", ""))
	if variable_name.is_empty():
		return null
	return component.get_data_asset_variant(asset_id, variable_name)


## BOTH doors at once, with whether they AGREE — the answer every caller asserts on, because a
## rule obeyed at one surface only is the failure this driver exists to catch. Answers
## `{ "host", "node", "agree", "text" }`; "text" is the host answer's scalar string, which is what
## a scalar case compares.
func read(asset_id: String, variable_id: String) -> Dictionary:
	var host = host_read(asset_id, variable_id)
	var node = node_read(asset_id, variable_id)
	return {
		"host": host,
		"node": node,
		"agree": variants_equal(host, node),
		"text": host.get_string("") if host != null else "",
	}


## Structural equality over the shapes a .sfd read hands back (scalar, array, map). Both null
## counts as equal: two doors that both degraded still agree.
static func variants_equal(a, b) -> bool:
	if a == null or b == null:
		return a == null and b == null
	if a.type != b.type:
		return false
	var a_map: Dictionary = a.get_map()
	var b_map: Dictionary = b.get_map()
	if a_map.size() != b_map.size():
		return false
	for key in a_map:
		if not b_map.has(key):
			return false
		if not variants_equal(a_map[key], b_map[key]):
			return false
	var a_array: Array = a.get_array()
	var b_array: Array = b.get_array()
	if a_array.size() != b_array.size():
		return false
	for index in a_array.size():
		if not variants_equal(a_array[index], b_array[index]):
			return false
	return a.get_string("") == b.get_string("") and a.get_bool() == b.get_bool() \
		and a.get_int() == b.get_int() and is_equal_approx(a.get_float(), b.get_float())
