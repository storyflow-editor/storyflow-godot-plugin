extends SceneTree
## Headless tests for the HOST-side .sfd Data Asset accessors on StoryFlowComponent — the
## get_data_asset_* / set_data_asset_* family and the untyped get_data_asset_variant door.
##
## What is specific to this surface, and therefore what this file is about:
##   1. ADDRESSING — an asset by ID or by unique display NAME, with an ambiguous name FAILING
##      rather than picking, and a variable by name with root-most-wins.
##   2. THE STRICT TYPE GATE, on the DECLARATION rather than on the stored value. In particular
##      ENUM IS EXCLUDED from the string surface while image, audio and character are in, and
##      arrays and maps come out only through the untyped door.
##   3. WRITES — the cascade, the nearest-wins block at an overriding child, refusals, and the
##      CACHE CLEAR every .sfd writer owes (a memoized boolean parent above an accessor keeps
##      answering the pre-write value otherwise).
##   4. THE SCRIPT-TABLE EXEMPTION — a .sfd read never consults the running script's strings
##      table, unlike get_string_variable. (What a DECLARED .sfd string does resolve through
##      since spec §2's amendment lives in tests/test_data_asset_localization.gd.)
##
## Reads work OUTSIDE a dialogue: everything goes through the manager's seed and overlay, which
## the execution context only borrows. Most of the file therefore runs with no component script
## at all; only the cache triple and the literal pin need a running graph.
##
## The seed is the shared golden fixture (see tests/test_data_asset_store.gd's header for the
## sync rules), parsed through the REAL importer helper.
##
## Run from the repository root (import first to build the class cache):
##   godot --headless --import
##   godot --headless --script res://tests/test_data_asset_host_api.gd
## Or: powershell -File tests/run_tests.ps1 -GodotExe <path-to-godot>

const ComponentScript := preload("res://addons/storyflow/core/storyflow_component.gd")
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
const V_TITLE := "5b1d8a04c6e2493fa72c9d0f31e6b8a7"
const V_TAGS := "c58e2f13a0d64c9b871e3f05d2a76b48"

var _checks: int = 0
var _failures: int = 0
var _importer = null
var _manager: Node = null
var _host: Node = null


func _initialize() -> void:
	await process_frame
	_importer = ImporterScript.new()
	_setup_runtime()

	_test_addressing()
	_test_reads()
	_test_type_gate()
	_test_untyped_door()
	_test_writes()
	_test_write_refusals()
	_test_write_cache_clear()
	_test_host_write_mid_chain()
	_test_string_literals()
	_test_refusal_warnings_are_latched()
	_test_ambiguous_display_name()

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
# 1. Addressing
# =============================================================================

func _test_addressing() -> void:
	print("-- addressing an asset --")
	_manager.reset_data_assets()

	_check("an asset addressed by ID resolves", _host.get_data_asset_int(BASE, "hp") == 100)
	_check("the same asset addressed by display NAME resolves the same",
		_host.get_data_asset_int("CreatureBase", "hp") == 100)
	_check("a child addressed by name reads its own override",
		_host.get_data_asset_int("Goblin", "hp") == 150)

	_check("an unknown asset returns the caller's default", _host.get_data_asset_int("da_nope", "hp", -7) == -7)
	_check("an unknown display name returns the caller's default", _host.get_data_asset_int("NotAnAsset", "hp", -7) == -7)
	_check("an empty asset string returns the caller's default", _host.get_data_asset_int("", "hp", -7) == -7)
	_check("an unknown VARIABLE name returns the caller's default", _host.get_data_asset_int(BASE, "nope", -7) == -7)

	# A category row never enters the seed's resolvable surface (contract 2.1), so by the time
	# the host asks, the chain simply does not declare it.
	_check("a category-typed row is not addressable", _host.get_data_asset_string(BASE, "lore", "<none>") == "<none>")


# =============================================================================
# 2. Reads
# =============================================================================

func _test_reads() -> void:
	print("-- typed reads --")
	_manager.reset_data_assets()

	_check("a seed value reads", _host.get_data_asset_bool(BASE, "alive") == true)
	_check("the asset's OWN override beats its declared value",
		is_equal_approx(_host.get_data_asset_float(BASE, "speed"), 2.25))
	_check("an INHERITED value cascades to a descendant that does not shadow it",
		_host.get_data_asset_bool(GRANDCHILD, "alive") == true)
	_check("a child's override wins at the child", _host.get_data_asset_enum(CHILD, "rank") == "Elite")
	_check("and cascades to the grandchild", _host.get_data_asset_enum(GRANDCHILD, "rank") == "Elite")

	# ROOT-MOST DECLARATION WINS: the grandchild re-declares title with a different value, and
	# that re-declaration must not shadow the base's. This is the one place a by-NAME lookup
	# could quietly differ from a by-id one, and it does not.
	_check("a descendant re-declaring a name does not shadow the root-most declaration",
		_host.get_data_asset_string(GRANDCHILD, "title") == "Grunt")

	# The string FAMILY: image, audio and character all store as bare path strings here.
	_check("an image-declared value reads through the string door",
		_host.get_data_asset_string(BASE, "portrait") == "images/creatures/grunt.png")
	_check("an audio-declared value reads through the string door",
		_host.get_data_asset_string(BASE, "roar") == "audio/creatures/roar.ogg")
	_check("a character-declared value reads through the string door",
		_host.get_data_asset_string(BASE, "owner") == "characters/Warden.sfc")

	# A SESSION value, written straight into the store, is what a read must see.
	StoreScript.try_set(_manager.get_data_asset_seed(), _manager.get_data_asset_overlay(),
		BASE, V_ALIVE, VariantScript.from_bool(false))
	_check("a session write is what a read sees", _host.get_data_asset_bool(BASE, "alive") == false)
	_check("and it cascades to descendants too", _host.get_data_asset_bool(GRANDCHILD, "alive") == false)


# =============================================================================
# 3. The strict type gate
# =============================================================================

func _test_type_gate() -> void:
	print("-- the strict type gate --")
	_manager.reset_data_assets()

	_check("an integer read of a boolean returns the default", _host.get_data_asset_int(BASE, "alive", -7) == -7)
	_check("a boolean read of an integer returns the default", _host.get_data_asset_bool(BASE, "hp", true) == true)
	_check("a float read of an integer returns the default", is_equal_approx(_host.get_data_asset_float(BASE, "hp", -1.0), -1.0))

	# THE ENUM CARVE-OUT: an enum and a string are indistinguishable once stored, so the gate is
	# on the declaration. Letting the string door read an enum would make a mistyped variable
	# name that happened to hit one look like it worked.
	_check("the STRING door refuses an ENUM declaration", _host.get_data_asset_string(BASE, "rank", "<none>") == "<none>")
	_check("while the ENUM door reads it", _host.get_data_asset_enum(BASE, "rank") == "Grunt")
	_check("and the ENUM door refuses a plain STRING declaration",
		_host.get_data_asset_enum(BASE, "title", "<none>") == "<none>")

	# Arrays and maps are not scalars, whatever their element type says.
	_check("a scalar door refuses an ARRAY declaration", _host.get_data_asset_string(BASE, "tags", "<none>") == "<none>")
	_check("a scalar door refuses a MAP declaration", _host.get_data_asset_string(BASE, "loot", "<none>") == "<none>")


# =============================================================================
# 4. The untyped door
# =============================================================================

func _test_untyped_door() -> void:
	print("-- the untyped variant door --")
	_manager.reset_data_assets()

	var tags = _host.get_data_asset_variant(BASE, "tags")
	_check("an array comes back through the untyped door", tags != null and tags.get_array().size() == 2)
	_check("array-tagged with its element type", tags != null and tags.type == Types.VariableType.STRING)

	var loot = _host.get_data_asset_variant(BASE, "loot")
	_check("a map comes back through the untyped door", loot != null and loot.type == Types.VariableType.MAP)
	_check("in authored entry order", loot != null and loot.get_map().keys() == ["gold", "gems"])

	var rank = _host.get_data_asset_variant(BASE, "rank")
	_check("an enum keeps its ENUM tag, which is how a caller tells it from a string",
		rank != null and rank.type == Types.VariableType.ENUM)

	_check("an unknown variable answers null", _host.get_data_asset_variant(BASE, "nope") == null)
	_check("an unknown asset answers null", _host.get_data_asset_variant("da_nope", "hp") == null)

	# COPY-ON-READ: the door hands out a detached copy, so a host mutating what it got cannot
	# reach into the store.
	tags.get_array().append(VariantScript.from_string("injected"))
	tags.get_array()[0].set_string("injected")
	var again = _host.get_data_asset_variant(BASE, "tags")
	_check("mutating what the door handed out does not reach the store",
		again.get_array().size() == 2 and again.get_array()[0].get_string() == "mob")


# =============================================================================
# 5. Writes
# =============================================================================

func _test_writes() -> void:
	print("-- host writes --")
	_manager.reset_data_assets()

	# SET ON BASE cascades to every descendant that does not shadow the id.
	_check("the seed value is true before the write", _host.get_data_asset_bool(BASE, "alive") == true)
	_check("a boolean write reports success", _host.set_data_asset_bool(BASE, "alive", false))
	# The default is deliberately the OPPOSITE of the expected value, so a read that silently
	# missed and fell back could not pass.
	_check("and reads back false", _host.get_data_asset_bool(BASE, "alive", true) == false)
	_check("and cascades to the grandchild", _host.get_data_asset_bool(GRANDCHILD, "alive", true) == false)

	# ... but is BLOCKED at a child that carries its own file override — nearest wins.
	_check("an integer write on the base reports success", _host.set_data_asset_int(BASE, "hp", 42))
	_check("the base reads the written value", _host.get_data_asset_int(BASE, "hp") == 42)
	_check("while the overriding child still reads its own override", _host.get_data_asset_int(CHILD, "hp") == 150)

	# A write at the CHILD beats that child's own override and cascades onward.
	_check("a write at the child reports success", _host.set_data_asset_int("Goblin", "hp", 7))
	_check("the child reads the session value", _host.get_data_asset_int(CHILD, "hp") == 7)
	_check("the grandchild inherits it", _host.get_data_asset_int(GRANDCHILD, "hp") == 7)
	_check("and the base is untouched", _host.get_data_asset_int(BASE, "hp") == 42)

	_check("a float write lands", _host.set_data_asset_float(BASE, "speed", 9.5) and is_equal_approx(_host.get_data_asset_float(BASE, "speed"), 9.5))
	_check("a string write lands", _host.set_data_asset_string(BASE, "title", "Boss") and _host.get_data_asset_string(BASE, "title") == "Boss")
	_check("an enum write lands", _host.set_data_asset_enum(BASE, "rank", "Elite") and _host.get_data_asset_enum(BASE, "rank") == "Elite")

	# The stored TAG comes from the DECLARATION, not from the caller's Godot type: an image
	# written through the string door must land STRING-tagged (this engine's storage type for
	# the whole string family) and an enum must land ENUM-tagged, or the next save writes the
	# wrong shape.
	_check("an image write lands through the string door", _host.set_data_asset_string(BASE, "portrait", "images/boss.png"))
	var portrait = _overlay_value(BASE, "3f9e0b7218ac4d6591f2c47a0e5b83d6")
	_check("and is stored STRING-tagged", portrait != null and portrait.type == Types.VariableType.STRING)
	var rank = _overlay_value(BASE, "d0a37c65e91b4f28b4c1a5e7028d63f9")
	_check("while the enum write is stored ENUM-tagged", rank != null and rank.type == Types.VariableType.ENUM)


# =============================================================================
# 6. Write refusals
# =============================================================================

func _test_write_refusals() -> void:
	print("-- host write refusals --")
	_manager.reset_data_assets()
	var overlay: Dictionary = _manager.get_data_asset_overlay()

	_check("a write to an unknown asset is refused", not _host.set_data_asset_int("da_nope", "hp", 1))
	_check("a write to an unknown variable is refused", not _host.set_data_asset_int(BASE, "nope", 1))
	_check("a type-mismatched write is refused", not _host.set_data_asset_bool(BASE, "hp", true))
	_check("the STRING setter refuses an ENUM declaration", not _host.set_data_asset_string(BASE, "rank", "Elite"))
	_check("the ENUM setter refuses a STRING declaration", not _host.set_data_asset_enum(BASE, "title", "Boss"))
	_check("a scalar setter refuses an ARRAY declaration", not _host.set_data_asset_string(BASE, "tags", "x"))
	_check("a scalar setter refuses a MAP declaration", not _host.set_data_asset_string(BASE, "loot", "x"))
	_check("and not one of them minted an overlay table", overlay.is_empty())


# =============================================================================
# 7. The cache-clear obligation
# =============================================================================

## PULL-WRITE-PULL through a HOST setter, in a parked dialogue. The accessor's own read is carved
## out of the boolean memo, so a directly gated option would see the write regardless; the option
## behind the andBool is the one that only flips because the setter clears the cache.
func _test_write_cache_clear() -> void:
	print("-- the host setter's cache clear --")
	_manager.reset_data_assets()
	var accessor := {"variableId": V_ALIVE, "variable": "alive", "variableType": "boolean"}
	var script := Graph.build("scripts/HostGating.sfe", {
		"0": Graph.start(),
		"PB": Graph.pill("PB", BASE),
		"GA": Graph.accessor("GA", accessor),
		"AND": Graph.node("AND", Types.NodeType.AND_BOOL, "andBool", {"value2": VariantScript.from_bool(true)}),
		"D": Graph.dialogue("D", [{"id": "o1", "text": "direct"}, {"id": "o2", "text": "behind an and"}]),
	}, [
		Graph.exec("0", "D"),
		Graph.pill_wire("PB", "GA"),
		Graph.data_wire("GA", "boolean", "D", "boolean-o1"),
		Graph.data_wire("GA", "boolean", "AND", Handles.IN_BOOLEAN1),
		Graph.data_wire("AND", "boolean", "D", "boolean-o2"),
	])

	var component := _run(script)
	var evaluator = component._evaluator
	_check("a true .sfd boolean makes a directly gated option VISIBLE",
		evaluator.evaluate_option_visibility({"id": "o1"}, "D") == true)
	_check("and one gated through a memoized andBool VISIBLE too",
		evaluator.evaluate_option_visibility({"id": "o2"}, "D") == true)

	# The HOST write, mid-park, with nothing else clearing anything around it.
	_check("the host setter reports success", component.set_data_asset_bool(BASE, "alive", false))
	_check("the directly gated option sees it (the accessor's own memo carve-out)",
		evaluator.evaluate_option_visibility({"id": "o1"}, "D") == false)
	_check("and so does the one behind the memoized andBool (the setter's own invalidation)",
		evaluator.evaluate_option_visibility({"id": "o2"}, "D") == false)

	_teardown(component)


# =============================================================================
# 7b. A host write that lands MID-CHAIN
# =============================================================================

## THE HOST SETTER'S CLEAR MUST BE AS NARROW AS THE GRAPH'S, and this is the shape that can tell.
##
## At a PARKED dialogue nothing distinguishes them: _handle_dialogue runs a blunt
## clear_cached_outputs of its own on the way in, so every node output is already gone before any
## host call can reach one. The difference only shows while a chain is still running - and game
## code reaches exactly there through variable_changed, which the component emits from inside
## chain processing. A host reacting to a variable by writing a Data Asset is an ordinary
## pattern, and it lands between two nodes of a live chain.
##
## Here the write fires from the handler for setBool, one exec step after an array op and one
## before the node that copies that op's output pin. A blunt clear in the host setter wipes the
## pin in between and the copy lands empty, exactly as it did on the graph path.
func _test_host_write_mid_chain() -> void:
	print("-- a host write landing mid-chain --")
	_manager.reset_data_assets()
	var script := Graph.build("scripts/HostMidChain.sfe", {
		"0": Graph.start(),
		"PB": Graph.pill("PB", BASE),
		"GT": Graph.accessor("GT", {"variableId": V_TAGS, "variable": "tags", "variableType": "string", "isArray": true}),
		"ADD": Graph.node("ADD", Types.NodeType.ADD_TO_STRING_ARRAY, "addToStringArray", {"value": VariantScript.from_string("new")}),
		# Emits variable_changed from inside the chain, which is where the host write comes from.
		"SB": Graph.node("SB", Types.NodeType.SET_BOOL, "setBool", {"variable": "trigger", "isGlobal": false, "value": VariantScript.from_bool(true)}),
		"OUT": Graph.node("OUT", Types.NodeType.SET_STRING_ARRAY, "setStringArray", {"variable": "echo", "isGlobal": false}),
		"D": Graph.dialogue("D"),
	}, [
		Graph.exec("0", "ADD"), Graph.exec_flow("ADD", "SB"), Graph.exec_flow("SB", "OUT"), Graph.exec_flow("OUT", "D"),
		Graph.pill_wire("PB", "GT"),
		Graph.data_wire("GT", "string-array", "ADD", Handles.IN_STRING_ARRAY),
		Graph.data_wire("ADD", "string-array", "OUT", Handles.IN_STRING_ARRAY),
	], {
		"trigger": Graph.scalar_var("trigger", "trigger", Types.VariableType.BOOLEAN, VariantScript.from_bool(false)),
		"echo": Graph.array_var("echo", "echo", Types.VariableType.STRING, []),
	})

	_manager.get_project().scripts[script.script_path] = script
	var component := ComponentScript.new()
	component.dialogue_ui_scene = null
	root.add_child(component)
	_mid_chain_target = component
	component.variable_changed.connect(_on_variable_changed_write_data_asset)
	component.start_dialogue_with_script(script.script_path)
	component.variable_changed.disconnect(_on_variable_changed_write_data_asset)
	_mid_chain_target = null

	_check("the host write did fire from inside the chain", _mid_chain_writes == 1)
	_check("and it landed in the overlay",
		_overlay_value(BASE, V_ALIVE) != null and _overlay_value(BASE, V_ALIVE).get_bool() == false)
	var echoed := component.get_array_variable("echo")
	_check("the array op OUTPUT PIN survived the mid-chain host write (got %d elements)" % echoed.size(),
		echoed.size() == 3)
	_check("carrying the appended element rather than a blank",
		echoed.size() == 3 and echoed[2].get_string() == "new")
	_teardown(component)


var _mid_chain_target: Node = null
var _mid_chain_writes: int = 0


## Writes a Data Asset from inside the chain, once. Guarded because the setter it calls can
## itself emit variable_changed on some paths, and an unguarded handler would recurse.
func _on_variable_changed_write_data_asset(_info) -> void:
	if _mid_chain_writes > 0 or _mid_chain_target == null:
		return
	_mid_chain_writes += 1
	_mid_chain_target.set_data_asset_bool(BASE, "alive", false)


# =============================================================================
# 8. A SCRIPT's strings table never reaches a .sfd value
# =============================================================================

## THE SAME ASSERTIONS THIS TEST ALWAYS MADE, for a REASON THAT CHANGED at localization spec §2's
## amendment of 2026-08-27. It used to be that data-assets.json carried no strings table at all
## (engine contract 2.1) and every .sfd string was a literal. Declared .sfd strings ARE keys now —
## but into data-assets.json's own table, which the importer merges into the PROJECT globals, and
## the .sfd read door withholds the running script (StoryFlowComponent._data_asset_locale). So
## this seed, which carries no strings table, still answers its own bytes while the script's
## "en.Grunt" row is right there and live.
##
## That live row is the whole point: an ordinary accessor localizing through it, on the same
## component in the same call, is what proves the .sfd door refused a table it could see rather
## than missing one that was not there.
func _test_string_literals() -> void:
	print("-- a script's strings table never reaches a .sfd value --")
	_manager.reset_data_assets()
	var script := Graph.build("scripts/HostLiteral.sfe", {
		"0": Graph.start(),
		"D": Graph.dialogue("D"),
	}, [Graph.exec("0", "D")], {
		"v_key": Graph.scalar_var("v_key", "OrdinaryString", Types.VariableType.STRING, VariantScript.from_string("Grunt")),
	}, {"en.Grunt": "LOCALIZED-GRUNT"})

	var component := _run(script)
	_check("an ordinary script string resolves through the strings table",
		component.get_string_variable("OrdinaryString") == "LOCALIZED-GRUNT")
	_check("while a .sfd string with the same value reads back as its own bytes",
		component.get_data_asset_string(BASE, "title") == "Grunt")
	_teardown(component)


# =============================================================================
# 9. An ambiguous display name
# =============================================================================

## Two assets sharing a display name. RUNS LAST of the golden-seed tests on purpose: it swaps the
## project for a hand-built one and does not swap back, so anything needing the seed fixture has
## to come before it.
##
## Two assets sharing a display name. The name lookup FAILS rather than picking one: which asset
## a game reads must not depend on dictionary order, and a lookup with two right answers has no
## better one. The IDs still work, which is the documented way out.
func _test_ambiguous_display_name() -> void:
	print("-- an ambiguous display name --")
	var project = ProjectScript.new()
	project.data_assets = _importer._parse_data_assets({
		"da_left": {"id": "da_left", "name": "Twin", "parent": null,
			"variables": [{"id": "n", "name": "n", "type": "integer", "value": 1}], "overrides": {}},
		"da_right": {"id": "da_right", "name": "Twin", "parent": null,
			"variables": [{"id": "n", "name": "n", "type": "integer", "value": 2}], "overrides": {}},
		"da_solo": {"id": "da_solo", "name": "Solo", "parent": null,
			"variables": [{"id": "n", "name": "n", "type": "integer", "value": 3}], "overrides": {}},
	})
	_manager.set_project(project)

	_check("an ambiguous display name READS as the caller's default", _host.get_data_asset_int("Twin", "n", -7) == -7)
	_check("an ambiguous display name WRITE is refused", not _host.set_data_asset_int("Twin", "n", 99))
	_check("and nothing reached the overlay", _manager.get_data_asset_overlay().is_empty())
	_check("while each ID still resolves", _host.get_data_asset_int("da_left", "n") == 1 and _host.get_data_asset_int("da_right", "n") == 2)
	_check("and an unambiguous name still resolves", _host.get_data_asset_int("Solo", "n") == 3)


# =============================================================================
# 10. Refusal warnings are latched
# =============================================================================

## A REFUSED ACCESSOR IS USUALLY A STALE NAME, and stale names are read from _process. Warning on
## every call turns one authoring mistake into a continuous flood in the editor output and in
## player logs, where the first line already named the fix.
##
## push_warning cannot be captured from a SceneTree test, so the assertions are on the manager's
## latch dictionary and its emitted counter - the same inspectable seam the node ladder uses, and
## the only one available. The COUNTER is what separates a working latch from its absence: the
## dictionary alone looks identical either way.
##
## The refusal itself is never latched, which is asserted alongside: every call still answers the
## caller's default, warned or silent.
func _test_refusal_warnings_are_latched() -> void:
	print("-- host refusal warnings are latched --")
	_manager.reset_all_state()
	_check("the latch starts empty", _manager.warned_data_asset_access.is_empty())
	_check("and the counter starts at zero", _manager.data_asset_access_warnings_emitted == 0)

	# TWO IDENTICAL refused calls: one warning.
	_check("the first refused read returns the default", _host.get_data_asset_int(BASE, "ghost", -7) == -7)
	var after_first: int = _manager.data_asset_access_warnings_emitted
	_check("and warns exactly once", after_first == 1)
	_check("the second identical call STILL returns the default", _host.get_data_asset_int(BASE, "ghost", -7) == -7)
	_check("but emits no second warning", _manager.data_asset_access_warnings_emitted == 1)

	# A DIFFERENT variable on the same asset is its own problem and gets its own line.
	_check("a different variable name still refuses", _host.get_data_asset_int(BASE, "phantom", -7) == -7)
	_check("and warns on its own", _manager.data_asset_access_warnings_emitted == 2)

	# A different KIND on the SAME variable is a different problem too: hp exists but is not a
	# boolean, and later asking for it as an array is a third distinct complaint.
	_check("a wrong-type read refuses", _host.get_data_asset_bool(BASE, "hp", true) == true)
	_check("and warns as its own kind", _manager.data_asset_access_warnings_emitted == 3)
	_check("repeating it stays silent", _host.get_data_asset_bool(BASE, "hp", true) == true
		and _manager.data_asset_access_warnings_emitted == 3)

	# An unknown ASSET latches on the asset alone, with no variable to key on.
	_check("an unknown asset refuses", _host.get_data_asset_int("da_nope", "hp", -7) == -7)
	_check("and warns once", _manager.data_asset_access_warnings_emitted == 4)
	_check("and not twice", _host.get_data_asset_int("da_nope", "other", -7) == -7
		and _manager.data_asset_access_warnings_emitted == 4)

	# A WRITE shares the latch with a READ that hit the SAME gate for the same reason, which is
	# the key being (asset, variable, kind) rather than (asset, variable, kind, direction): the
	# boolean read of hp above already said hp is not a boolean, and the write has nothing to add.
	_check("a wrong-type write refuses", not _host.set_data_asset_bool(BASE, "hp", true))
	_check("and stays silent, since the read already reported that exact problem",
		_manager.data_asset_access_warnings_emitted == 4)

	# A wrong-type write on a variable no read has complained about still gets its own line.
	_check("a write refusal on an unreported variable refuses", not _host.set_data_asset_bool(BASE, "speed", true))
	_check("and warns", _manager.data_asset_access_warnings_emitted == 5)
	_check("repeating that write stays silent", not _host.set_data_asset_bool(BASE, "speed", true)
		and _manager.data_asset_access_warnings_emitted == 5)

	# RE-ARM: a re-import is where a name that was wrong may have become right, so a DIFFERENT
	# problem appearing afterwards must be allowed to say so.
	_manager.set_project(_manager.get_project())
	_check("set_project re-arms the latch", _manager.warned_data_asset_access.is_empty())
	_check("and resets the counter", _manager.data_asset_access_warnings_emitted == 0)
	_check("so the same refusal warns again", _host.get_data_asset_int(BASE, "ghost", -7) == -7
		and _manager.data_asset_access_warnings_emitted == 1)

	_manager.reset_all_state()
	_check("reset_all_state re-arms it too", _manager.warned_data_asset_access.is_empty())


# =============================================================================
# Runtime setup
# =============================================================================

func _setup_runtime() -> void:
	var project = ProjectScript.new()
	project.data_assets = _importer._parse_data_assets(_load_fixture("data-assets-seed.json").get("dataAssets", {}))
	_manager = ManagerScript.new()
	_manager.name = "StoryFlowRuntime"
	root.add_child(_manager)
	_manager.set_project(project)

	# The host surface works with NO dialogue running — everything routes through the manager —
	# so most of this file drives this one idle component.
	_host = ComponentScript.new()
	_host.dialogue_ui_scene = null
	root.add_child(_host)


func _run(script) -> Node:
	_manager.get_project().scripts[script.script_path] = script
	var component := ComponentScript.new()
	component.dialogue_ui_scene = null
	root.add_child(component)
	component.start_dialogue_with_script(script.script_path)
	return component


func _teardown(component: Node) -> void:
	component.stop_dialogue()
	root.remove_child(component)
	component.queue_free()


func _overlay_value(asset_id: String, variable_id: String):
	var table = _manager.get_data_asset_overlay().get(asset_id, null)
	if not table is Dictionary:
		return null
	return table.get(variable_id, null)


func _load_fixture(file_name: String) -> Dictionary:
	var file := FileAccess.open(FIXTURE_DIR.path_join(file_name), FileAccess.READ)
	if file == null:
		printerr("  SETUP FAILURE: cannot read %s" % file_name)
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}
