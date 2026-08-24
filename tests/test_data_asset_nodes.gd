extends SceneTree
## Headless tests for the three .sfd Data Asset NODE TYPES executing in a real graph —
## getDataAsset (the reference pill), getDataAssetVariable and setDataAssetVariable.
##
## The degraded ladder has its own file (tests/test_data_asset_degraded.gd, fixture-driven) and
## the store/resolver has a third (tests/test_data_asset_store.gd). What is left, and what lives
## here, is everything that only shows up once the nodes are wired into a graph and executed:
##
##   1. WIRE-IS-THE-BINDING — two byte-identical accessors bound to two different pills answer
##      two different values (engine contract 2.2). The accessor carries no assetId, so this is
##      the only thing that decides which asset it reads.
##   2. WRITES — scalar cascade, enum/array/map TYPE TAGS on what actually lands in the overlay,
##      the empty-array stamp, and the no-inline-fallback refusal.
##   3. OPTION GATING through the REAL evaluate_option_visibility, asserting the VISIBLE
##      direction (contract 6.2 — a missing boolean arm fails CLOSED and silently, so only the
##      true direction catches it) plus the PULL-WRITE-PULL cache triple.
##   4. THE STRING-TABLE EXEMPTION — a .sfd string equal to a live strings-table key reads back
##      as the LITERAL, while an ordinary script string with the same value still localizes.
##   5. ARRAY-OP ROUTING with a same-named local decoy, and the not-an-array refusal.
##
## Everything is driven through the component's real _process_node dispatch and the real
## evaluators; nothing calls a handler's internals directly except the deliberate mid-park
## _process_node in the pull-write-pull triple, which exists precisely to write WITHOUT the
## cache clear every ordinary re-render path performs.
##
## The seed is the shared golden fixture (see tests/test_data_asset_store.gd's header for the
## sync rules), parsed through the REAL importer helper.
##
## Run from the repository root (import first to build the class cache):
##   godot --headless --import
##   godot --headless --script res://tests/test_data_asset_nodes.gd
## Or: powershell -File tests/run_tests.ps1 -GodotExe <path-to-godot>

const ComponentScript := preload("res://addons/storyflow/core/storyflow_component.gd")
const Handles := preload("res://addons/storyflow/core/storyflow_handles.gd")
const ImporterScript := preload("res://addons/storyflow/editor/storyflow_importer.gd")
const ManagerScript := preload("res://addons/storyflow/core/storyflow_manager.gd")
const ProjectScript := preload("res://addons/storyflow/core/storyflow_project.gd")
const ScriptScript := preload("res://addons/storyflow/core/storyflow_script.gd")
const StoreScript := preload("res://addons/storyflow/core/storyflow_data_asset_store.gd")
const Types := preload("res://addons/storyflow/core/storyflow_types.gd")
const VariantScript := preload("res://addons/storyflow/core/storyflow_variant.gd")

const FIXTURE_DIR := "res://tests/fixtures/engine-contract"

const BASE := "da_0a1b2c3d4e5f60718293a4b5c6d7e8f9"
const CHILD := "da_1b2c3d4e5f60718293a4b5c6d7e8f90a"
const GRANDCHILD := "da_2c3d4e5f60718293a4b5c6d7e8f90a1b"

const V_ALIVE := "7f3a1c9e4b2d40518a6f0c3e7d1b5a29"
const V_HP := "2e8b6d0a1f4c47d3b95e2a70c6f81d34"
const V_TITLE := "5b1d8a04c6e2493fa72c9d0f31e6b8a7"
const V_RANK := "d0a37c65e91b4f28b4c1a5e7028d63f9"
const V_TAGS := "c58e2f13a0d64c9b871e3f05d2a76b48"
const V_LOOT := "6d0f39a8b21e47c5903af8d61c72e504"
const V_SECRET := "0b6c8f24e17d4a509c3b2e81a4f6d735"

var _checks: int = 0
var _failures: int = 0

var _importer = null
var _manager: Node = null


func _initialize() -> void:
	await process_frame
	_importer = ImporterScript.new()
	_setup_runtime()

	_test_wire_is_the_binding()
	_test_writes()
	_test_option_gating_and_cache()
	_test_string_literal_exemption()
	_test_array_ops()

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
		print("  FAIL: %s" % label)


# =============================================================================
# 1. The wire IS the binding
# =============================================================================

## Two accessors with byte-identical node data, wired to pills naming different assets, must
## answer different values — the whole of contract 2.2 in one graph. hp is the discriminator
## because the base declares 100 and the child overrides it to 150.
func _test_wire_is_the_binding() -> void:
	print("-- the wire is the binding --")
	var script := _script("scripts/Wire.sfe")
	script.variables = {
		"a": _var("a", "FromBase", Types.VariableType.INTEGER, VariantScript.from_int(0)),
		"b": _var("b", "FromChild", Types.VariableType.INTEGER, VariantScript.from_int(0)),
	}
	var accessor := {"variableId": V_HP, "variable": "hp", "variableType": "integer"}
	script.nodes = {
		"0": _node("0", Types.NodeType.START, "start", {}),
		"PB": _pill("PB", BASE),
		"PC": _pill("PC", CHILD),
		"G1": _accessor("G1", accessor),
		"G2": _accessor("G2", accessor),
		"SA": _node("SA", Types.NodeType.SET_INT, "setInt", {"variable": "a", "isGlobal": false}),
		"SB": _node("SB", Types.NodeType.SET_INT, "setInt", {"variable": "b", "isGlobal": false}),
		"D": _dialogue("D", []),
	}
	script.connections = [
		_exec("0", "SA"), _exec_flow("SA", "SB"), _exec_flow("SB", "D"),
		_pill_wire("PB", "G1"), _pill_wire("PC", "G2"),
		_data_wire("G1", "integer", "SA", Handles.IN_INTEGER),
		_data_wire("G2", "integer", "SB", Handles.IN_INTEGER),
	]
	script.build_indices()

	var component := _run(script)
	_check("the base-bound accessor reads the base declaration (100)", component.get_int_variable("FromBase") == 100)
	_check("the identical child-bound accessor reads the child override (150)", component.get_int_variable("FromChild") == 150)
	_teardown(component)


# =============================================================================
# 2. Writes
# =============================================================================

## Every write shape the Set node supports, asserted on WHAT LANDS IN THE OVERLAY rather than
## on a read-back: the type TAG is the thing at risk (an enum written as a plain string, an
## emptied array losing its element type) and a read-back would hide it behind get_string().
func _test_writes() -> void:
	print("-- Set writes --")
	var script := _script("scripts/Writes.sfe")
	script.variables = {
		"v_secret": _var("v_secret", "s", Types.VariableType.STRING, VariantScript.from_string("written-secret")),
		"v_rank": _var("v_rank", "r", Types.VariableType.ENUM, VariantScript.from_enum("Boss")),
		"v_tags": _array_var("v_tags", "t", Types.VariableType.STRING, ["a", "b"]),
		"v_empty": _array_var("v_empty", "e", Types.VariableType.STRING, []),
		"v_loot": _map_var("v_loot", "l", {"sword": VariantScript.from_int(7)}),
	}
	script.nodes = {
		"0": _node("0", Types.NodeType.START, "start", {}),
		"PB": _pill("PB", BASE),
		"PC": _pill("PC", CHILD),
		"PG": _pill("PG", GRANDCHILD),
		"GS": _node("GS", Types.NodeType.GET_STRING, "getString", {"variable": "v_secret", "isGlobal": false}),
		"GE": _node("GE", Types.NodeType.GET_ENUM, "getEnum", {"variable": "v_rank", "isGlobal": false}),
		"GA": _node("GA", Types.NodeType.GET_STRING_ARRAY, "getStringArray", {"variable": "v_tags", "isGlobal": false}),
		"GZ": _node("GZ", Types.NodeType.GET_STRING_ARRAY, "getStringArray", {"variable": "v_empty", "isGlobal": false}),
		"GM": _node("GM", Types.NodeType.GET_MAP, "getMap", {"variable": "v_loot", "isGlobal": false, "keyType": "string", "valueType": "integer"}),
		# On the BASE, so the write has descendants to cascade to.
		"S1": _setter("S1", {"variableId": V_SECRET, "variable": "secret", "variableType": "string"}),
		"S2": _setter("S2", {"variableId": V_RANK, "variable": "rank", "variableType": "enum"}),
		"S3": _setter("S3", {"variableId": V_TAGS, "variable": "tags", "variableType": "string", "isArray": true}),
		# Healthy binding, NOTHING on the value pin: the refusal that proves there is no
		# inline fallback (contract 5 — never write the type's zero over a declared default).
		"S4": _setter("S4", {"variableId": V_TITLE, "variable": "title", "variableType": "string"}),
		"S5": _setter("S5", {"variableId": V_TAGS, "variable": "tags", "variableType": "string", "isArray": true}),
		"S6": _setter("S6", {"variableId": V_LOOT, "variable": "loot", "variableType": "map", "keyType": "string", "valueType": "integer"}),
		"D": _dialogue("D", []),
	}
	script.connections = [
		_exec("0", "S1"), _exec_flow("S1", "S2"), _exec_flow("S2", "S3"), _exec_flow("S3", "S4"),
		_exec_flow("S4", "S5"), _exec_flow("S5", "S6"), _exec_flow("S6", "D"),
		_pill_wire("PB", "S1"), _pill_wire("PC", "S2"), _pill_wire("PC", "S3"),
		_pill_wire("PC", "S4"), _pill_wire("PG", "S5"), _pill_wire("PC", "S6"),
		_data_wire("GS", "string", "S1", "string-2"),
		_data_wire("GE", "enum", "S2", "enum-2"),
		_data_wire("GA", "string-array", "S3", "string-array-2"),
		_data_wire("GZ", "string-array", "S5", "string-array-2"),
		_map_wire("GM", "S6", "string", "integer"),
	]
	script.build_indices()

	_manager.reset_data_assets()
	var component := _run(script)
	var seed: Dictionary = _manager.get_data_asset_seed()
	var overlay: Dictionary = _manager.get_data_asset_overlay()

	# Scalar write on the BASE cascades to every descendant that does not shadow it.
	_check("a scalar write lands on the asset the pill names", _overlay_value(overlay, BASE, V_SECRET) != null)
	var cascaded = StoreScript.try_resolve(seed, overlay, GRANDCHILD, V_SECRET)
	_check("and cascades to a grandchild that does not override it",
		cascaded != null and cascaded.get_string() == "written-secret")

	# Type TAGS. An enum written as a plain STRING would read back identically through
	# get_string() and only diverge at save time — assert the tag itself.
	var rank = _overlay_value(overlay, CHILD, V_RANK)
	_check("an enum write stores an ENUM-tagged value", rank != null and rank.type == Types.VariableType.ENUM)
	_check("carrying the written value", rank != null and rank.get_string() == "Boss")

	var tags = _overlay_value(overlay, CHILD, V_TAGS)
	_check("an array write stores its elements", tags != null and tags.get_array().size() == 2)
	_check("stamped with the declared element type", tags != null and tags.type == Types.VariableType.STRING)
	_check("and its elements are element-typed too",
		tags != null and tags.get_array()[0] is VariantScript and tags.get_array()[0].type == Types.VariableType.STRING)

	var empty = _overlay_value(overlay, GRANDCHILD, V_TAGS)
	_check("an EMPTY array write is still stored", empty != null and empty.get_array().is_empty())
	_check("and keeps its element type, which set_array alone would leave unset",
		empty != null and empty.type == Types.VariableType.STRING)

	var loot = _overlay_value(overlay, CHILD, V_LOOT)
	_check("a map write stores a map", loot != null and loot.is_map())
	_check("replacing the whole value with the wired entries",
		loot != null and loot.get_map().size() == 1 and loot.get_map().has("sword"))

	# The refusal: nothing written, and the declared default still resolves.
	_check("an unwired value pin writes NOTHING", _overlay_value(overlay, CHILD, V_TITLE) == null)
	var untouched = StoreScript.try_resolve(seed, overlay, CHILD, V_TITLE)
	_check("leaving the declared default intact", untouched != null and untouched.get_string() == "Grunt")

	_teardown(component)


# =============================================================================
# 3. Option gating + the pull-write-pull cache triple
# =============================================================================

## Option visibility through the REAL evaluate_option_visibility, in both directions and over
## both chain shapes: an accessor wired straight into the option pin, and one behind a memoized
## andBool parent.
##
## The VISIBLE direction is the one that matters (contract 6.2): the boolean evaluator's match
## answers false in its terminal arm, so an unregistered node type hides every option it gates
## with no error anywhere — a hidden-when-false assertion would pass against a runtime that has
## no .sfd arm at all.
##
## Then the PULL-WRITE-PULL triple: pull the visibility, execute a Set node mid-park — the only
## way to write without also going through a path that clears the cache on its own — then pull
## again. The two halves fail for different reasons and both are asserted:
##   o1 (direct) needs only the accessor's own carve-out from the boolean memo.
##   o2 (behind andBool) needs the Set handler's explicit clear_cache. It FAILED before that
##      line existed: process_boolean_chain recurses into an andBool's inputs but never
##      recomputes the andBool itself, so the option stayed VISIBLE across a write to false.
## That failure is what settled the cache-invalidation question for this task.
func _test_option_gating_and_cache() -> void:
	print("-- option gating + pull-write-pull --")
	var script := _script("scripts/Gating.sfe")
	script.variables = {
		"v_false": _var("v_false", "f", Types.VariableType.BOOLEAN, VariantScript.from_bool(false)),
	}
	var accessor := {"variableId": V_ALIVE, "variable": "alive", "variableType": "boolean"}
	script.nodes = {
		"0": _node("0", Types.NodeType.START, "start", {}),
		"PB": _pill("PB", BASE),
		"GA": _accessor("GA", accessor),
		# A memoized parent: process_boolean_chain recurses into an andBool's inputs but does
		# not recompute the andBool itself, so its cached output is what a stale read returns.
		"AND": _node("AND", Types.NodeType.AND_BOOL, "andBool", {"value2": VariantScript.from_bool(true)}),
		"GF": _node("GF", Types.NodeType.GET_BOOL, "getBool", {"variable": "v_false", "isGlobal": false}),
		"W": _setter("W", accessor),
		"D": _dialogue("D", [{"id": "o1", "text": "direct"}, {"id": "o2", "text": "behind an and"}]),
	}
	script.connections = [
		_exec("0", "D"),
		_pill_wire("PB", "GA"), _pill_wire("PB", "W"),
		_data_wire("GA", "boolean", "D", "boolean-o1"),
		_data_wire("GA", "boolean", "AND", Handles.IN_BOOLEAN1),
		_data_wire("AND", "boolean", "D", "boolean-o2"),
		_data_wire("GF", "boolean", "W", "boolean-2"),
	]
	script.build_indices()

	_manager.reset_data_assets()
	var component := _run(script)
	var evaluator = component._evaluator

	_check("a true .sfd boolean makes a directly gated option VISIBLE",
		evaluator.evaluate_option_visibility({"id": "o1"}, "D") == true)
	_check("and one gated through a boolean chain VISIBLE too",
		evaluator.evaluate_option_visibility({"id": "o2"}, "D") == true)

	# WRITE, mid-park, with no clear of any kind around it.
	component._process_node(script.nodes["W"])
	var written = _overlay_value(_manager.get_data_asset_overlay(), BASE, V_ALIVE)
	_check("the mid-park Set wrote false into the overlay", written != null and written.get_bool() == false)

	_check("the directly gated option sees the write (the accessor's memo carve-out)",
		evaluator.evaluate_option_visibility({"id": "o1"}, "D") == false)
	_check("and so does the one behind the memoized andBool (the Set's own invalidation)",
		evaluator.evaluate_option_visibility({"id": "o2"}, "D") == false)

	# The accessor's OWN carve-out from the boolean memo (is_data_asset_read), pinned through a
	# bare evaluate_boolean_from_node rather than through option visibility. Two reasons it has
	# to be this shape:
	#   - evaluate_option_visibility runs process_boolean_chain first, whose .sfd arm clears the
	#     accessor's cache anyway, so it cannot tell a carve-out from its absence.
	#   - a bare evaluate_boolean_from_node is what a branch condition or an andBool input does,
	#     and nothing clears anything for those.
	# The write here goes STRAIGHT INTO THE STORE, which is not a detour: it is the shape a host
	# accessor and a save load take (both Task G3), and neither touches the evaluator's cache.
	_check("a bare boolean read sees the current overlay value",
		evaluator.evaluate_boolean_from_node("GA", "") == false)
	StoreScript.try_set(_manager.get_data_asset_seed(), _manager.get_data_asset_overlay(),
		BASE, V_ALIVE, VariantScript.from_bool(true))
	_check("and a store-level write is visible on the very next one, unmemoized",
		evaluator.evaluate_boolean_from_node("GA", "") == true)

	_teardown(component)


# =============================================================================
# 4. The string-table exemption
# =============================================================================

## data-assets.json carries no strings table (contract 2.1) — .sfd string values are LITERALS.
## The base declares title = "Grunt"; this script's strings table also has an "en.Grunt" key.
## The .sfd read must answer "Grunt" while an ordinary script string holding the same value
## still localizes, which is what proves the table is live and the exemption is real rather
## than the table simply missing.
func _test_string_literal_exemption() -> void:
	print("-- .sfd strings are literals --")
	var script := _script("scripts/Literal.sfe")
	script.strings = {"en.Grunt": "LOCALIZED-GRUNT"}
	script.variables = {
		"v_key": _var("v_key", "k", Types.VariableType.STRING, VariantScript.from_string("Grunt")),
		"out_da": _var("out_da", "FromDataAsset", Types.VariableType.STRING, VariantScript.from_string("")),
		"out_var": _var("out_var", "FromScriptVar", Types.VariableType.STRING, VariantScript.from_string("")),
	}
	script.nodes = {
		"0": _node("0", Types.NodeType.START, "start", {}),
		"PB": _pill("PB", BASE),
		"GT": _accessor("GT", {"variableId": V_TITLE, "variable": "title", "variableType": "string"}),
		"GK": _node("GK", Types.NodeType.GET_STRING, "getString", {"variable": "v_key", "isGlobal": false}),
		"S1": _node("S1", Types.NodeType.SET_STRING, "setString", {"variable": "out_da", "isGlobal": false}),
		"S2": _node("S2", Types.NodeType.SET_STRING, "setString", {"variable": "out_var", "isGlobal": false}),
		"D": _dialogue("D", []),
	}
	script.connections = [
		_exec("0", "S1"), _exec_flow("S1", "S2"), _exec_flow("S2", "D"),
		_pill_wire("PB", "GT"),
		_data_wire("GT", "string", "S1", Handles.IN_STRING),
		_data_wire("GK", "string", "S2", Handles.IN_STRING),
	]
	script.build_indices()

	var component := _run(script)
	# Read the STORED variant, not get_string_variable, which resolves through the table again
	# on the way out and would hide the difference this test exists to show.
	_check("a .sfd string equal to a strings-table key reads back as the LITERAL",
		_stored_string(component, "out_da") == "Grunt")
	_check("while an ordinary script string with the same value still localizes",
		_stored_string(component, "out_var") == "LOCALIZED-GRUNT")
	_teardown(component)


# =============================================================================
# 5. Array-op routing
# =============================================================================

## An array op whose array input comes from a .sfd accessor writes through the binding ladder
## into the overlay, NOT into a script variable — even when a local variable shares the
## accessor's display name, which is the decoy this test exists for: the accessor carries no
## isGlobal and its "variable" field is a display-NAME snapshot, so a routing that falls
## through to the name lookup silently clobbers the local instead.
func _test_array_ops() -> void:
	print("-- array ops route into the overlay --")
	var add_script := _script("scripts/ArrayAdd.sfe")
	add_script.variables = {
		# THE DECOY: same display name as the accessor's snapshot below.
		"tags": _array_var("tags", "tags", Types.VariableType.STRING, ["local-only"]),
		"echo": _array_var("echo", "echo", Types.VariableType.STRING, []),
	}
	add_script.nodes = {
		"0": _node("0", Types.NodeType.START, "start", {}),
		"PC": _pill("PC", CHILD),
		"GT": _accessor("GT", {"variableId": V_TAGS, "variable": "tags", "variableType": "string", "isArray": true}),
		"GH": _accessor("GH", {"variableId": V_HP, "variable": "hp", "variableType": "integer"}),
		"ADD": _node("ADD", Types.NodeType.ADD_TO_STRING_ARRAY, "addToStringArray", {"value": VariantScript.from_string("new")}),
		# Reads ADD's own output. The routing clears the evaluation cache after its write, and
		# _handle_array_modify stamps that output BEFORE the routing runs — so this node is
		# what proves the clear was ordered against the stamp instead of wiping it.
		"OUT": _node("OUT", Types.NodeType.SET_STRING_ARRAY, "setStringArray", {"variable": "echo", "isGlobal": false}),
		# Bound to a SCALAR: the array op must refuse it rather than write an array over a
		# value the declaration promises is one integer.
		"BAD": _node("BAD", Types.NodeType.ADD_TO_STRING_ARRAY, "addToStringArray", {"value": VariantScript.from_string("nope")}),
		"D": _dialogue("D", []),
	}
	add_script.connections = [
		_exec("0", "ADD"), _exec_flow("ADD", "OUT"), _exec_flow("OUT", "BAD"), _exec_flow("BAD", "D"),
		_pill_wire("PC", "GT"), _pill_wire("PC", "GH"),
		_data_wire("GT", "string-array", "ADD", Handles.IN_STRING_ARRAY),
		_data_wire("ADD", "string-array", "OUT", Handles.IN_STRING_ARRAY),
		_data_wire("GH", "string-array", "BAD", Handles.IN_STRING_ARRAY),
	]
	add_script.build_indices()

	_manager.reset_data_assets()
	var component := _run(add_script)
	var overlay: Dictionary = _manager.get_data_asset_overlay()
	var written = _overlay_value(overlay, CHILD, V_TAGS)
	_check("addToArray on a .sfd accessor writes into the overlay",
		written != null and written.get_array().size() == 3)
	_check("appending to the value the accessor's own binding resolves",
		written != null and written.get_array()[2].get_string() == "new")
	var decoy := component.get_array_variable("tags")
	_check("the same-named LOCAL array is untouched",
		decoy.size() == 1 and decoy[0].get_string() == "local-only")
	var echoed := component.get_array_variable("echo")
	_check("the op's own output survives the post-write cache clear (invalidate-then-restamp)",
		echoed.size() == 3)
	_check("a scalar-bound accessor refuses the array op and writes nothing",
		_overlay_value(overlay, CHILD, V_HP) == null)
	_check("and latches an arrayop warning for it",
		component._context.warned_data_asset_nodes.has("GH|arrayop"))
	_teardown(component)

	# clearArray routes through the same single site (unlike the HTML runtime, which gives it
	# its own branch), and the emptied array must keep its element type.
	var clear_script := _script("scripts/ArrayClear.sfe")
	clear_script.nodes = {
		"0": _node("0", Types.NodeType.START, "start", {}),
		"PC": _pill("PC", CHILD),
		"GT": _accessor("GT", {"variableId": V_TAGS, "variable": "tags", "variableType": "string", "isArray": true}),
		"CLR": _node("CLR", Types.NodeType.CLEAR_STRING_ARRAY, "clearStringArray", {}),
		"D": _dialogue("D", []),
	}
	clear_script.connections = [
		_exec("0", "CLR"), _exec_flow("CLR", "D"),
		_pill_wire("PC", "GT"),
		_data_wire("GT", "string-array", "CLR", Handles.IN_STRING_ARRAY),
	]
	clear_script.build_indices()

	_manager.reset_data_assets()
	var clear_component := _run(clear_script)
	var cleared = _overlay_value(_manager.get_data_asset_overlay(), CHILD, V_TAGS)
	_check("clearArray on a .sfd accessor empties it in the overlay",
		cleared != null and cleared.get_array().is_empty())
	_check("and the emptied array keeps its element type", cleared != null and cleared.type == Types.VariableType.STRING)
	_teardown(clear_component)


# =============================================================================
# Runtime setup
# =============================================================================

func _setup_runtime() -> void:
	var project := ProjectScript.new()
	project.data_assets = _importer._parse_data_assets(_load_fixture("data-assets-seed.json").get("dataAssets", {}))
	_manager = ManagerScript.new()
	_manager.name = "StoryFlowRuntime"
	root.add_child(_manager)
	_manager.set_project(project)


## Register the script on the shared project and run it. One manager for the whole file (a
## second node named StoryFlowRuntime would shadow it), with reset_data_assets between the
## scenarios that write.
func _run(script: StoryFlowScript) -> StoryFlowComponent:
	_manager.get_project().scripts[script.script_path] = script
	var component := ComponentScript.new()
	component.dialogue_ui_scene = null
	root.add_child(component)
	component.start_dialogue_with_script(script.script_path)
	return component


func _teardown(component: StoryFlowComponent) -> void:
	component.stop_dialogue()
	root.remove_child(component)
	component.queue_free()


# =============================================================================
# Graph construction helpers
# =============================================================================

func _script(path: String) -> StoryFlowScript:
	var script := ScriptScript.new()
	script.script_path = path
	return script


func _node(id: String, node_type: Types.NodeType, type_string: String, data: Dictionary) -> Dictionary:
	return {"id": id, "type": node_type, "type_string": type_string, "data": data}


func _pill(id: String, asset_id: String) -> Dictionary:
	return _node(id, Types.NodeType.GET_DATA_ASSET, "getDataAsset", {"assetId": asset_id})


func _accessor(id: String, data: Dictionary) -> Dictionary:
	return _node(id, Types.NodeType.GET_DATA_ASSET_VARIABLE, "getDataAssetVariable", data.duplicate())


func _setter(id: String, data: Dictionary) -> Dictionary:
	return _node(id, Types.NodeType.SET_DATA_ASSET_VARIABLE, "setDataAssetVariable", data.duplicate())


func _dialogue(id: String, options: Array) -> Dictionary:
	return _node(id, Types.NodeType.DIALOGUE, "dialogue", {"title": "", "text": id, "options": options})


func _var(id: String, name: String, type: Types.VariableType, value) -> Dictionary:
	return {"id": id, "name": name, "type": type, "value": value}


func _array_var(id: String, name: String, type: Types.VariableType, values: Array) -> Dictionary:
	var elements: Array = []
	for value in values:
		elements.append(VariantScript.from_string(str(value)))
	var variant := VariantScript.new()
	variant.set_array(elements)
	variant.type = type
	return {"id": id, "name": name, "type": type, "value": variant, "is_array": true}


func _map_var(id: String, name: String, entries: Dictionary) -> Dictionary:
	return {"id": id, "name": name, "type": Types.VariableType.MAP, "value": VariantScript.from_map(entries)}


func _edge(source: String, source_handle: String, target: String, target_handle: String) -> Dictionary:
	return {
		"id": "%s->%s:%s" % [source, target, target_handle],
		"source": source, "target": target,
		"source_handle": source_handle, "target_handle": target_handle,
	}


## The exec edge out of a node with no OUT_FLOW suffix (start, dialogue).
func _exec(source: String, target: String) -> Dictionary:
	return _edge(source, Handles.source(source), target, Handles.target(target))


## The exec edge out of a Set node, which flows from its OUT_FLOW pin.
func _exec_flow(source: String, target: String) -> Dictionary:
	return _edge(source, Handles.source(source, Handles.OUT_FLOW), target, Handles.target(target))


## The .sfd reference wire: pill -> accessor, the ONLY thing that binds an accessor.
func _pill_wire(pill: String, target: String) -> Dictionary:
	return _edge(pill, "source-%s-dataAsset-" % pill, target, Handles.target(target, Handles.IN_DATA_ASSET))


func _data_wire(source: String, source_type: String, target: String, target_suffix: String) -> Dictionary:
	return _edge(source, "source-%s-%s-" % [source, source_type], target, Handles.target(target, target_suffix))


func _map_wire(source: String, target: String, key_type: String, value_type: String) -> Dictionary:
	return _edge(source, "source-%s-map-%s-%s" % [source, key_type, value_type],
		target, Handles.target(target, Handles.in_map(key_type, value_type, Handles.DATA_ASSET_VALUE_OPTION)))


# =============================================================================
# Assertion helpers
# =============================================================================

## The raw overlay entry, or null. Deliberately not a resolve: these assertions are about what
## the WRITE stored, tag and all, not about what a read would make of it.
func _overlay_value(overlay: Dictionary, asset_id: String, variable_id: String):
	var table = overlay.get(asset_id, null)
	if not table is Dictionary:
		return null
	return table.get(variable_id, null)


## A local variable's STORED string, bypassing get_string_variable's own strings-table
## resolution on the way out.
func _stored_string(component: StoryFlowComponent, variable_id: String) -> String:
	var variable = component._context.local_variables.get(variable_id, {})
	var value = variable.get("value", null)
	return value.get_string() if value is VariantScript else ""


func _load_fixture(file_name: String) -> Dictionary:
	var path := FIXTURE_DIR.path_join(file_name)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		printerr("  SETUP FAILURE: cannot read %s" % path)
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}
