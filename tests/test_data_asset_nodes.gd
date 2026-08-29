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
##   4. THE SCRIPT-TABLE EXEMPTION — a .sfd string equal to a live SCRIPT strings-table key reads
##      back as its own bytes, while an ordinary script string with the same value localizes.
##   5. ARRAY-OP ROUTING with a same-named local decoy, and the not-an-array refusal.
##
## Everything is driven through the component's real _process_node dispatch and the real
## evaluators; nothing calls a handler's internals directly except the deliberate mid-park
## _process_node in the pull-write-pull triple, which exists precisely to write WITHOUT the
## cache clear every ordinary re-render path performs.
##
## Graphs are assembled with tests/data_asset_test_graph.gd, which owns the editor's handle
## formats. The seed is the shared golden fixture (see tests/test_data_asset_store.gd's header
## for the sync rules), parsed through the REAL importer helper.
##
## Run from the repository root (import first to build the class cache):
##   godot --headless --import
##   godot --headless --script res://tests/test_data_asset_nodes.gd
## Or: powershell -File tests/run_tests.ps1 -GodotExe <path-to-godot>

const ComponentScript := preload("res://addons/storyflow/core/storyflow_component.gd")
const ContextScript := preload("res://addons/storyflow/core/storyflow_execution_context.gd")
const EvaluatorScript := preload("res://addons/storyflow/core/storyflow_evaluator.gd")
const Graph := preload("res://tests/data_asset_test_graph.gd")
const Handles := preload("res://addons/storyflow/core/storyflow_handles.gd")
const ImporterScript := preload("res://addons/storyflow/editor/storyflow_importer.gd")
const ManagerScript := preload("res://addons/storyflow/core/storyflow_manager.gd")
const ProjectScript := preload("res://addons/storyflow/core/storyflow_project.gd")
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
	_test_write_inside_a_loop_body()
	_test_array_op_output_survives_a_later_write()
	_test_get_variable_names()

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
	var accessor := {"variableId": V_HP, "variable": "hp", "variableType": "integer"}
	var script := Graph.build("scripts/Wire.sfe", {
		"0": Graph.start(),
		"PB": Graph.pill("PB", BASE),
		"PC": Graph.pill("PC", CHILD),
		"G1": Graph.accessor("G1", accessor),
		"G2": Graph.accessor("G2", accessor),
		"SA": Graph.node("SA", Types.NodeType.SET_INT, "setInt", {"variable": "a", "isGlobal": false}),
		"SB": Graph.node("SB", Types.NodeType.SET_INT, "setInt", {"variable": "b", "isGlobal": false}),
		"D": Graph.dialogue("D"),
	}, [
		Graph.exec("0", "SA"), Graph.exec_flow("SA", "SB"), Graph.exec_flow("SB", "D"),
		Graph.pill_wire("PB", "G1"), Graph.pill_wire("PC", "G2"),
		Graph.data_wire("G1", "integer", "SA", Handles.IN_INTEGER),
		Graph.data_wire("G2", "integer", "SB", Handles.IN_INTEGER),
	], {
		"a": Graph.scalar_var("a", "FromBase", Types.VariableType.INTEGER, VariantScript.from_int(0)),
		"b": Graph.scalar_var("b", "FromChild", Types.VariableType.INTEGER, VariantScript.from_int(0)),
	})

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
	var script := Graph.build("scripts/Writes.sfe", {
		"0": Graph.start(),
		"PB": Graph.pill("PB", BASE),
		"PC": Graph.pill("PC", CHILD),
		"PG": Graph.pill("PG", GRANDCHILD),
		"GS": Graph.node("GS", Types.NodeType.GET_STRING, "getString", {"variable": "v_secret", "isGlobal": false}),
		"GE": Graph.node("GE", Types.NodeType.GET_ENUM, "getEnum", {"variable": "v_rank", "isGlobal": false}),
		"GA": Graph.node("GA", Types.NodeType.GET_STRING_ARRAY, "getStringArray", {"variable": "v_tags", "isGlobal": false}),
		"GZ": Graph.node("GZ", Types.NodeType.GET_STRING_ARRAY, "getStringArray", {"variable": "v_empty", "isGlobal": false}),
		"GM": Graph.node("GM", Types.NodeType.GET_MAP, "getMap", {"variable": "v_loot", "isGlobal": false, "keyType": "string", "valueType": "integer"}),
		# On the BASE, so the write has descendants to cascade to.
		"S1": Graph.setter("S1", {"variableId": V_SECRET, "variable": "secret", "variableType": "string"}),
		"S2": Graph.setter("S2", {"variableId": V_RANK, "variable": "rank", "variableType": "enum"}),
		"S3": Graph.setter("S3", {"variableId": V_TAGS, "variable": "tags", "variableType": "string", "isArray": true}),
		# Healthy binding, NOTHING on the value pin: the refusal that proves there is no
		# inline fallback (contract 5 — never write the type's zero over a declared default).
		"S4": Graph.setter("S4", {"variableId": V_TITLE, "variable": "title", "variableType": "string"}),
		"S5": Graph.setter("S5", {"variableId": V_TAGS, "variable": "tags", "variableType": "string", "isArray": true}),
		"S6": Graph.setter("S6", {"variableId": V_LOOT, "variable": "loot", "variableType": "map", "keyType": "string", "valueType": "integer"}),
		"D": Graph.dialogue("D"),
	}, [
		Graph.exec("0", "S1"), Graph.exec_flow("S1", "S2"), Graph.exec_flow("S2", "S3"),
		Graph.exec_flow("S3", "S4"), Graph.exec_flow("S4", "S5"), Graph.exec_flow("S5", "S6"),
		Graph.exec_flow("S6", "D"),
		Graph.pill_wire("PB", "S1"), Graph.pill_wire("PC", "S2"), Graph.pill_wire("PC", "S3"),
		Graph.pill_wire("PC", "S4"), Graph.pill_wire("PG", "S5"), Graph.pill_wire("PC", "S6"),
		Graph.data_wire("GS", "string", "S1", Handles.in_data_asset_value("string")),
		Graph.data_wire("GE", "enum", "S2", Handles.in_data_asset_value("enum")),
		Graph.data_wire("GA", "string-array", "S3", Handles.in_data_asset_array_value("string")),
		Graph.data_wire("GZ", "string-array", "S5", Handles.in_data_asset_array_value("string")),
		Graph.map_wire("GM", "S6", "string", "integer", Handles.DATA_ASSET_VALUE_OPTION),
	], {
		"v_secret": Graph.scalar_var("v_secret", "s", Types.VariableType.STRING, VariantScript.from_string("written-secret")),
		"v_rank": Graph.scalar_var("v_rank", "r", Types.VariableType.ENUM, VariantScript.from_enum("Boss")),
		"v_tags": Graph.array_var("v_tags", "t", Types.VariableType.STRING, ["a", "b"]),
		"v_empty": Graph.array_var("v_empty", "e", Types.VariableType.STRING, []),
		# STRING-tagged on purpose, under an integer-valued declaration: the map pin's K/V
		# tokens satisfy decl_matches, but the variants INSIDE a source map carry whatever tag
		# their producer gave them, so this is the shape the entry re-mint exists to correct.
		"v_loot": Graph.map_var("v_loot", "l", {"sword": VariantScript.from_string("7")}),
	})

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
	# ENTRY VALUES ARE RE-MINTED against the declared valueType, symmetric with the array
	# branch's element stamp two blocks up. Without it the source's STRING tag would sit in the
	# overlay and a save round trip would hand back an INTEGER-tagged one, because the load types
	# from the declaration - a tag flip visible through get_data_asset_variant and nowhere else.
	# The VALUE becoming the declared default is the same wrong-type rule the array elements
	# follow, not a separate decision.
	_check("a map entry value is re-minted against the declared valueType",
		loot != null and loot.get_map()["sword"].type == Types.VariableType.INTEGER)

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
	var accessor := {"variableId": V_ALIVE, "variable": "alive", "variableType": "boolean"}
	var script := Graph.build("scripts/Gating.sfe", {
		"0": Graph.start(),
		"PB": Graph.pill("PB", BASE),
		"GA": Graph.accessor("GA", accessor),
		# A memoized parent: process_boolean_chain recurses into an andBool's inputs but does
		# not recompute the andBool itself, so its cached output is what a stale read returns.
		"AND": Graph.node("AND", Types.NodeType.AND_BOOL, "andBool", {"value2": VariantScript.from_bool(true)}),
		"GF": Graph.node("GF", Types.NodeType.GET_BOOL, "getBool", {"variable": "v_false", "isGlobal": false}),
		"W": Graph.setter("W", accessor),
		"D": Graph.dialogue("D", [{"id": "o1", "text": "direct"}, {"id": "o2", "text": "behind an and"}]),
	}, [
		Graph.exec("0", "D"),
		Graph.pill_wire("PB", "GA"), Graph.pill_wire("PB", "W"),
		Graph.data_wire("GA", "boolean", "D", "boolean-o1"),
		Graph.data_wire("GA", "boolean", "AND", Handles.IN_BOOLEAN1),
		Graph.data_wire("AND", "boolean", "D", "boolean-o2"),
		Graph.data_wire("GF", "boolean", "W", Handles.in_data_asset_value("boolean")),
	], {
		"v_false": Graph.scalar_var("v_false", "f", Types.VariableType.BOOLEAN, VariantScript.from_bool(false)),
	})

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

## THE SAME ASSERTIONS, for a REASON THAT CHANGED at localization spec §2's amendment of
## 2026-08-27. It used to be that data-assets.json carried no strings table (engine contract 2.1)
## and every .sfd value was a literal. Declared .sfd strings ARE keys now — into data-assets.json's
## OWN table, merged by the importer into the project globals — and the node lane's .sfd door
## withholds the running script (StoryFlowEvaluator._data_asset_locale), so a script table can
## never shadow one. This seed carries no strings table at all, so the read answers its own bytes.
##
## The base declares title = "Grunt"; this script's strings table also has an "en.Grunt" key. The
## .sfd read must answer "Grunt" while an ordinary script string holding the same value still
## localizes, which is what proves the table is live and the exemption is real rather than the
## table simply missing.
func _test_string_literal_exemption() -> void:
	print("-- a script's strings table never reaches a .sfd value --")
	var script := Graph.build("scripts/Literal.sfe", {
		"0": Graph.start(),
		"PB": Graph.pill("PB", BASE),
		"GT": Graph.accessor("GT", {"variableId": V_TITLE, "variable": "title", "variableType": "string"}),
		"GK": Graph.node("GK", Types.NodeType.GET_STRING, "getString", {"variable": "v_key", "isGlobal": false}),
		"S1": Graph.node("S1", Types.NodeType.SET_STRING, "setString", {"variable": "out_da", "isGlobal": false}),
		"S2": Graph.node("S2", Types.NodeType.SET_STRING, "setString", {"variable": "out_var", "isGlobal": false}),
		"D": Graph.dialogue("D"),
	}, [
		Graph.exec("0", "S1"), Graph.exec_flow("S1", "S2"), Graph.exec_flow("S2", "D"),
		Graph.pill_wire("PB", "GT"),
		Graph.data_wire("GT", "string", "S1", Handles.IN_STRING),
		Graph.data_wire("GK", "string", "S2", Handles.IN_STRING),
	], {
		"v_key": Graph.scalar_var("v_key", "k", Types.VariableType.STRING, VariantScript.from_string("Grunt")),
		"out_da": Graph.scalar_var("out_da", "FromDataAsset", Types.VariableType.STRING, VariantScript.from_string("")),
		"out_var": Graph.scalar_var("out_var", "FromScriptVar", Types.VariableType.STRING, VariantScript.from_string("")),
	}, {"en.Grunt": "LOCALIZED-GRUNT"})

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
	var add_script := Graph.build("scripts/ArrayAdd.sfe", {
		"0": Graph.start(),
		"PC": Graph.pill("PC", CHILD),
		"GT": Graph.accessor("GT", {"variableId": V_TAGS, "variable": "tags", "variableType": "string", "isArray": true}),
		"GH": Graph.accessor("GH", {"variableId": V_HP, "variable": "hp", "variableType": "integer"}),
		"ADD": Graph.node("ADD", Types.NodeType.ADD_TO_STRING_ARRAY, "addToStringArray", {"value": VariantScript.from_string("new")}),
		# Reads ADD's own output. The routing clears the evaluation cache after its write, and
		# _handle_array_modify stamps that output BEFORE the routing runs — so this node is
		# what proves the clear was ordered against the stamp instead of wiping it.
		"OUT": Graph.node("OUT", Types.NodeType.SET_STRING_ARRAY, "setStringArray", {"variable": "echo", "isGlobal": false}),
		# Bound to a SCALAR: the array op must refuse it rather than write an array over a
		# value the declaration promises is one integer.
		"BAD": Graph.node("BAD", Types.NodeType.ADD_TO_STRING_ARRAY, "addToStringArray", {"value": VariantScript.from_string("nope")}),
		"D": Graph.dialogue("D"),
	}, [
		Graph.exec("0", "ADD"), Graph.exec_flow("ADD", "OUT"), Graph.exec_flow("OUT", "BAD"), Graph.exec_flow("BAD", "D"),
		Graph.pill_wire("PC", "GT"), Graph.pill_wire("PC", "GH"),
		Graph.data_wire("GT", "string-array", "ADD", Handles.IN_STRING_ARRAY),
		Graph.data_wire("ADD", "string-array", "OUT", Handles.IN_STRING_ARRAY),
		Graph.data_wire("GH", "string-array", "BAD", Handles.IN_STRING_ARRAY),
	], {
		# THE DECOY: same display name as the accessor's snapshot above.
		"tags": Graph.array_var("tags", "tags", Types.VariableType.STRING, ["local-only"]),
		"echo": Graph.array_var("echo", "echo", Types.VariableType.STRING, []),
	})

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
	# its own branch), and the emptied array must keep its element type — on BOTH sides: in the
	# overlay, and on the op's own output pin, which is what the re-stamp is for. An emptied
	# array is exactly the case set_array cannot tag on its own, having no element zero to read.
	#
	# This chain DEAD-ENDS at the op instead of parking on a dialogue: _handle_dialogue clears
	# every cached output on entry, so a dialogue after the op would wipe the very stamp the
	# last two assertions read. A setStringArray consumer could not stand in for them either —
	# _handle_array_set re-infers the tag off element zero, which an empty array does not have.
	var clear_script := Graph.build("scripts/ArrayClear.sfe", {
		"0": Graph.start(),
		"PC": Graph.pill("PC", CHILD),
		"GT": Graph.accessor("GT", {"variableId": V_TAGS, "variable": "tags", "variableType": "string", "isArray": true}),
		"CLR": Graph.node("CLR", Types.NodeType.CLEAR_STRING_ARRAY, "clearStringArray", {}),
	}, [
		Graph.exec("0", "CLR"),
		Graph.pill_wire("PC", "GT"),
		Graph.data_wire("GT", "string-array", "CLR", Handles.IN_STRING_ARRAY),
	])

	_manager.reset_data_assets()
	var clear_component := _run(clear_script)
	var cleared = _overlay_value(_manager.get_data_asset_overlay(), CHILD, V_TAGS)
	_check("clearArray on a .sfd accessor empties it in the overlay",
		cleared != null and cleared.get_array().is_empty())
	_check("and the emptied array keeps its element type", cleared != null and cleared.type == Types.VariableType.STRING)
	var clear_output = clear_component._context.get_node_state("CLR").cached_output
	_check("the op's OUTPUT pin is emptied too", clear_output != null and clear_output.get_array().is_empty())
	_check("and carries the same element type the overlay got, not an untagged array",
		clear_output != null and clear_output.type == Types.VariableType.STRING)
	_teardown(clear_component)


# =============================================================================
# 6. A write from inside a forEach body
# =============================================================================

## THE .sfd WRITE'S CACHE CLEAR MUST NOT COST THE LOOP ITS ELEMENT.
##
## An array forEach publishes the current element through the node's cached_output, and
## clear_cached_outputs nulls every cached_output there is - so a setDataAssetVariable in a loop
## body used to blank the loop-element pin for the rest of that iteration, and every read of it
## after the write answered "". Map loops never had the problem: loop_key/loop_value are
## dedicated fields precisely so the per-iteration clear cannot reach them. Array loops got the
## other half of that fix, a restore immediately after the clear.
##
## TWO ELEMENTS, and the assertion is on the SECOND: with one element the write lands before the
## only read and a stale-but-present stamp would still pass. The local variable ends holding
## whatever the last iteration read, so "beta" means the pin survived the write and "" means it
## did not.
func _test_write_inside_a_loop_body() -> void:
	print("-- a .sfd write inside a forEach body --")
	_manager.reset_data_assets()
	var script := Graph.build("scripts/LoopWrite.sfe", {
		"0": Graph.start(),
		"GA": Graph.node("GA", Types.NodeType.GET_STRING_ARRAY, "getStringArray", {"variable": "v_items", "isGlobal": false}),
		"FE": Graph.node("FE", Types.NodeType.FOR_EACH_STRING_LOOP, "forEachStringLoop", {}),
		"PB": Graph.pill("PB", BASE),
		"GS": Graph.node("GS", Types.NodeType.GET_STRING, "getString", {"variable": "v_new", "isGlobal": false}),
		"W": Graph.setter("W", {"variableId": V_SECRET, "variable": "secret", "variableType": "string"}),
		"OUT": Graph.node("OUT", Types.NodeType.SET_STRING, "setString", {"variable": "seen", "isGlobal": false}),
		"D": Graph.dialogue("D"),
	}, [
		Graph.exec("0", "FE"),
		Graph.data_wire("GA", "string-array", "FE", Handles.IN_STRING_ARRAY),
		# Into the body, then back out of it: OUT has no outgoing edge, which is what tells
		# _handle_set_node_end to advance the loop.
		Graph.edge("FE", Handles.source("FE", Handles.OUT_LOOP_BODY), "W", Handles.target("W")),
		Graph.pill_wire("PB", "W"),
		Graph.data_wire("GS", "string", "W", Handles.in_data_asset_value("string")),
		Graph.exec_flow("W", "OUT"),
		# The pin under test: the loop ELEMENT, read after the write in the same iteration.
		Graph.data_wire("FE", "string", "OUT", Handles.IN_STRING),
		Graph.edge("FE", Handles.source("FE", Handles.OUT_LOOP_COMPLETED), "D", Handles.target("D")),
	], {
		"v_items": Graph.array_var("v_items", "Items", Types.VariableType.STRING, ["alpha", "beta"]),
		"v_new": Graph.scalar_var("v_new", "NewSecret", Types.VariableType.STRING, VariantScript.from_string("written")),
		"seen": Graph.scalar_var("seen", "Seen", Types.VariableType.STRING, VariantScript.from_string("")),
	})

	var component := _run(script)
	_check("the loop element pin survives a Set node write in the same iteration (got %s)" % _stored_string(component, "seen"),
		_stored_string(component, "seen") == "beta")
	# The write itself still has to have happened - a restore that quietly skipped the clear
	# would pass the check above and break option gating instead.
	var written = _overlay_value(_manager.get_data_asset_overlay(), BASE, V_SECRET)
	_check("and the write still landed in the overlay", written != null and written.get_string() == "written")
	_teardown(component)

	# THE ARRAY-OP ROUTE IS A SECOND WRITE SITE with its own clear, and its own restore. It needs
	# its own case: deleting the restore from one site leaves the other site's test green, and
	# this is arguably the likelier authoring shape of the two - appending the loop element to a
	# .sfd array is what a forEach over a .sfd array is usually FOR.
	#
	# The element is wired into BOTH pins here: as the value the op appends (read before the
	# write, which no clear can affect) and as the value the following node stores (read AFTER
	# it, which is the pin under test). Only the second one can fail.
	_manager.reset_data_assets()
	var op_script := Graph.build("scripts/LoopArrayOp.sfe", {
		"0": Graph.start(),
		"GA": Graph.node("GA", Types.NodeType.GET_STRING_ARRAY, "getStringArray", {"variable": "v_items", "isGlobal": false}),
		"FE": Graph.node("FE", Types.NodeType.FOR_EACH_STRING_LOOP, "forEachStringLoop", {}),
		"PC": Graph.pill("PC", CHILD),
		"GT": Graph.accessor("GT", {"variableId": V_TAGS, "variable": "tags", "variableType": "string", "isArray": true}),
		"ADD": Graph.node("ADD", Types.NodeType.ADD_TO_STRING_ARRAY, "addToStringArray", {}),
		"OUT": Graph.node("OUT", Types.NodeType.SET_STRING, "setString", {"variable": "seen", "isGlobal": false}),
		"D": Graph.dialogue("D"),
	}, [
		Graph.exec("0", "FE"),
		Graph.data_wire("GA", "string-array", "FE", Handles.IN_STRING_ARRAY),
		Graph.edge("FE", Handles.source("FE", Handles.OUT_LOOP_BODY), "ADD", Handles.target("ADD")),
		Graph.pill_wire("PC", "GT"),
		Graph.data_wire("GT", "string-array", "ADD", Handles.IN_STRING_ARRAY),
		Graph.data_wire("FE", "string", "ADD", Handles.IN_STRING),
		Graph.exec_flow("ADD", "OUT"),
		Graph.data_wire("FE", "string", "OUT", Handles.IN_STRING),
		Graph.edge("FE", Handles.source("FE", Handles.OUT_LOOP_COMPLETED), "D", Handles.target("D")),
	], {
		"v_items": Graph.array_var("v_items", "Items", Types.VariableType.STRING, ["alpha", "beta"]),
		"seen": Graph.scalar_var("seen", "Seen", Types.VariableType.STRING, VariantScript.from_string("")),
	})

	var op_component := _run(op_script)
	_check("the loop element pin survives an ARRAY OP write in the same iteration (got %s)" % _stored_string(op_component, "seen"),
		_stored_string(op_component, "seen") == "beta")
	# Both iterations appended, onto the child's own two-element override, and the accessor
	# re-resolved between them rather than replaying its first read.
	var appended = _overlay_value(_manager.get_data_asset_overlay(), CHILD, V_TAGS)
	_check("and both iterations appended to the overlay array",
		appended != null and appended.get_array().size() == 4)
	_check("in loop order, which is what proves each iteration re-resolved the accessor",
		appended != null and appended.get_array()[2].get_string() == "alpha"
		and appended.get_array()[3].get_string() == "beta")
	_teardown(op_component)


# =============================================================================
# 7. An array op's OUTPUT PIN read after a later .sfd write
# =============================================================================

## THE SECOND CASUALTY CLASS OF A BLUNT CACHE CLEAR, and the one loop elements were the first of.
##
## An array op publishes its result on its own output pin, which is node cached_output like
## everything else - so a setDataAssetVariable ANYWHERE LATER IN THE SAME EXEC CHAIN used to wipe
## it, and a node reading that pin afterwards got an empty array with no warning and an identical
## trace. The reference runtime cannot have this bug: its clearNotBoolCache touches the boolean
## and comparison caches only, and node outputs live somewhere else entirely.
##
## The write here is to a DIFFERENT asset variable than the array the op touched, so nothing
## about the .sfd store explains the loss - only the clear does. The control leg proves the graph
## itself is sound: the identical chain with a plain setBool in place of the .sfd write copies
## both elements.
func _test_array_op_output_survives_a_later_write() -> void:
	print("-- an array op output pin survives a later .sfd write --")
	_manager.reset_data_assets()
	var script := Graph.build("scripts/OutputPin.sfe", {
		"0": Graph.start(),
		"PC": Graph.pill("PC", CHILD),
		"GT": Graph.accessor("GT", {"variableId": V_TAGS, "variable": "tags", "variableType": "string", "isArray": true}),
		"ADD": Graph.node("ADD", Types.NodeType.ADD_TO_STRING_ARRAY, "addToStringArray", {"value": VariantScript.from_string("new")}),
		# The .sfd write that sits BETWEEN the op and the read of its output.
		"GS": Graph.node("GS", Types.NodeType.GET_STRING, "getString", {"variable": "v_new", "isGlobal": false}),
		"W": Graph.setter("W", {"variableId": V_SECRET, "variable": "secret", "variableType": "string"}),
		# Reads ADD's output pin, two exec steps later.
		"OUT": Graph.node("OUT", Types.NodeType.SET_STRING_ARRAY, "setStringArray", {"variable": "echo", "isGlobal": false}),
		"D": Graph.dialogue("D"),
	}, [
		Graph.exec("0", "ADD"), Graph.exec_flow("ADD", "W"), Graph.exec_flow("W", "OUT"), Graph.exec_flow("OUT", "D"),
		Graph.pill_wire("PC", "GT"), Graph.pill_wire("PC", "W"),
		Graph.data_wire("GT", "string-array", "ADD", Handles.IN_STRING_ARRAY),
		Graph.data_wire("GS", "string", "W", Handles.in_data_asset_value("string")),
		Graph.data_wire("ADD", "string-array", "OUT", Handles.IN_STRING_ARRAY),
	], {
		"v_new": Graph.scalar_var("v_new", "NewSecret", Types.VariableType.STRING, VariantScript.from_string("written")),
		"echo": Graph.array_var("echo", "echo", Types.VariableType.STRING, []),
	})

	var component := _run(script)
	var echoed := component.get_array_variable("echo")
	_check("an array op OUTPUT PIN survives a .sfd Set later in the same chain (got %d elements)" % echoed.size(),
		echoed.size() == 3)
	_check("and carries the appended element, not a blank of the right length",
		echoed.size() == 3 and echoed[2].get_string() == "new")
	_check("while the .sfd write in between still landed",
		_overlay_value(_manager.get_data_asset_overlay(), CHILD, V_SECRET) != null)
	_teardown(component)

	# THE CONTROL: the same chain with an ordinary setBool where the .sfd write was. If this leg
	# ever fails, the graph is wrong and the leg above is passing or failing for its own reasons.
	_manager.reset_data_assets()
	var control := Graph.build("scripts/OutputPinControl.sfe", {
		"0": Graph.start(),
		"PC": Graph.pill("PC", CHILD),
		"GT": Graph.accessor("GT", {"variableId": V_TAGS, "variable": "tags", "variableType": "string", "isArray": true}),
		"ADD": Graph.node("ADD", Types.NodeType.ADD_TO_STRING_ARRAY, "addToStringArray", {"value": VariantScript.from_string("new")}),
		"W": Graph.node("W", Types.NodeType.SET_BOOL, "setBool", {"variable": "flag", "isGlobal": false, "value": VariantScript.from_bool(true)}),
		"OUT": Graph.node("OUT", Types.NodeType.SET_STRING_ARRAY, "setStringArray", {"variable": "echo", "isGlobal": false}),
		"D": Graph.dialogue("D"),
	}, [
		Graph.exec("0", "ADD"), Graph.exec_flow("ADD", "W"), Graph.exec_flow("W", "OUT"), Graph.exec_flow("OUT", "D"),
		Graph.pill_wire("PC", "GT"),
		Graph.data_wire("GT", "string-array", "ADD", Handles.IN_STRING_ARRAY),
		Graph.data_wire("ADD", "string-array", "OUT", Handles.IN_STRING_ARRAY),
	], {
		"flag": Graph.scalar_var("flag", "flag", Types.VariableType.BOOLEAN, VariantScript.from_bool(false)),
		"echo": Graph.array_var("echo", "echo", Types.VariableType.STRING, []),
	})

	var control_component := _run(control)
	_check("CONTROL: the same chain with a plain setBool copies both elements",
		control_component.get_array_variable("echo").size() == 3)
	_teardown(control_component)


# =============================================================================
# 8. Get Variable Names
# =============================================================================

## The getDataAssetVariableNames arm (engine contract 11.1): a pure node with NO fields of its
## own whose dataAsset wire is its whole binding, answering the chain's declared NAMES as a
## string array. The two bound reads run through the real exec chain (setStringArray
## consumers); the degraded reads are pulled straight off the evaluator, and every one must
## answer an EMPTY array with NO warning latched — the ladder's warn tokens belong to the
## bound accessors, and this node adds none (11.1's no-new-tokens rule).
##
## The store-level list rules (root-first order, dedupe by id and by NAME, the orphan-override
## pin, categories) live in tests/test_data_asset_store.gd's _test_variable_names; what this
## file adds is the GRAPH: the wire hop, the array-evaluator arm, and the silence.
func _test_get_variable_names() -> void:
	print("-- get variable names --")
	var script := Graph.build("scripts/Names.sfe", {
		"0": Graph.start(),
		"PG": Graph.pill("PG", GRANDCHILD),
		"PB": Graph.pill("PB", BASE),
		"PD": Graph.pill("PD", "da_nope"),
		"PE": Graph.pill("PE", ""),
		"NG": Graph.names_node("NG"),
		"NB": Graph.names_node("NB"),
		"NU": Graph.names_node("NU"),
		"ND": Graph.names_node("ND"),
		"NE": Graph.names_node("NE"),
		"SG": Graph.node("SG", Types.NodeType.SET_STRING_ARRAY, "setStringArray", {"variable": "from_grandchild", "isGlobal": false}),
		"SB": Graph.node("SB", Types.NodeType.SET_STRING_ARRAY, "setStringArray", {"variable": "from_base", "isGlobal": false}),
		# Off the exec chain on purpose: the degraded pulls go through the evaluator directly,
		# because a setStringArray of an empty array is indistinguishable from one that never ran.
		"CU": Graph.node("CU", Types.NodeType.SET_STRING_ARRAY, "setStringArray", {"variable": "unused", "isGlobal": false}),
		"CD": Graph.node("CD", Types.NodeType.SET_STRING_ARRAY, "setStringArray", {"variable": "unused", "isGlobal": false}),
		"CE": Graph.node("CE", Types.NodeType.SET_STRING_ARRAY, "setStringArray", {"variable": "unused", "isGlobal": false}),
		"D": Graph.dialogue("D"),
	}, [
		Graph.exec("0", "SG"), Graph.exec_flow("SG", "SB"), Graph.exec_flow("SB", "D"),
		Graph.pill_wire("PG", "NG"), Graph.pill_wire("PB", "NB"),
		# NU gets NO pill wire at all; ND's pill names an asset the seed does not carry; NE's
		# pill is unbound.
		Graph.pill_wire("PD", "ND"), Graph.pill_wire("PE", "NE"),
		Graph.data_wire("NG", "string-array", "SG", Handles.IN_STRING_ARRAY),
		Graph.data_wire("NB", "string-array", "SB", Handles.IN_STRING_ARRAY),
		Graph.data_wire("NU", "string-array", "CU", Handles.IN_STRING_ARRAY),
		Graph.data_wire("ND", "string-array", "CD", Handles.IN_STRING_ARRAY),
		Graph.data_wire("NE", "string-array", "CE", Handles.IN_STRING_ARRAY),
	], {
		"from_grandchild": Graph.array_var("from_grandchild", "from_grandchild", Types.VariableType.STRING, []),
		"from_base": Graph.array_var("from_base", "from_base", Types.VariableType.STRING, []),
	})

	_manager.reset_data_assets()
	var component := _run(script)

	# The base's 11 declarations in FILE ORDER — the category row ("lore") is not among them,
	# and neither the base's own root-level override nor any descendant override adds a name.
	var expected_base: Array = ["alive", "hp", "speed", "title", "rank", "portrait", "owner", "roar", "tags", "loot", "secret"]
	var expected_grandchild := expected_base.duplicate()
	expected_grandchild.append("armor")

	var from_base := _string_values(component.get_array_variable("from_base"))
	_check("a base-bound node lists the base's 11 names in file order (got %s)" % str(from_base),
		from_base == expected_base)
	var from_grandchild := _string_values(component.get_array_variable("from_grandchild"))
	_check("a grandchild-bound node lists the ROOT's names first, the child's addition after",
		from_grandchild == expected_grandchild)
	_check("and its own same-id title re-declaration added nothing (root-most wins)",
		from_grandchild.count("title") == 1)
	_check("the category row is listed by neither", not from_base.has("lore") and not from_grandchild.has("lore"))

	# The degraded family: every rung answers an EMPTY array, and NONE of them latches a
	# warning — reading each twice would prove a latch, but there is nothing to latch.
	var evaluator = component._evaluator
	_check("an unwired dataAsset pin answers an empty array",
		evaluator.evaluate_string_array_input("CU", Handles.IN_STRING_ARRAY).is_empty())
	_check("a dead reference answers an empty array",
		evaluator.evaluate_string_array_input("CD", Handles.IN_STRING_ARRAY).is_empty())
	_check("an unbound pill answers an empty array",
		evaluator.evaluate_string_array_input("CE", Handles.IN_STRING_ARRAY).is_empty())
	_check("and no degraded read latched any warning (11.1: no new tokens)",
		component._context.data_asset_warnings_emitted == 0
		and component._context.warned_data_asset_nodes.is_empty())
	_teardown(component)

	# ABSENT STORE: a context never handed a seed carries {}, and the arm must answer an empty
	# array off it rather than reaching for a store that is not there.
	var bare_script := Graph.build("scripts/NamesBare.sfe", {
		"0": Graph.start(),
		"PB": Graph.pill("PB", BASE),
		"N": Graph.names_node("N"),
		"C": Graph.node("C", Types.NodeType.SET_STRING_ARRAY, "setStringArray", {"variable": "unused", "isGlobal": false}),
	}, [
		Graph.pill_wire("PB", "N"),
		Graph.data_wire("N", "string-array", "C", Handles.IN_STRING_ARRAY),
	])
	var bare_context := ContextScript.new()
	bare_context.current_script = bare_script
	bare_context.data_asset_seed = {}
	bare_context.data_asset_overlay = {}
	var bare_evaluator := EvaluatorScript.new()
	bare_evaluator.initialize(bare_context, {}, {}, "en", {})
	_check("an absent store answers an empty array",
		bare_evaluator.evaluate_string_array_input("C", Handles.IN_STRING_ARRAY).is_empty())
	_check("silently", bare_context.data_asset_warnings_emitted == 0)


## The get_string of every element, order preserved, for comparing against a plain string list.
func _string_values(elements: Array) -> Array:
	var out: Array = []
	for element in elements:
		out.append(element.get_string() if element is VariantScript else "")
	return out


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
