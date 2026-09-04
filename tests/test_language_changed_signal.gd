extends SceneTree
## Headless tests for the language_changed signal (design doc 2026-09-04).
##
## The signal fires when the language ACTUALLY MOVES and never otherwise. The silent cases are a
## refused code, a no-op re-set, and an install that carries the player's choice forward. The
## loud one is the install that SNAPS - the incoming project cannot carry the current code, so
## the language falls back to that project's source language, which is a real change to what the
## player is reading.
##
## That arm also pins WHERE the emit sits: the whole project is installed before it lands, which
## the roster check below observes.
##
## Run from the repository root (import first to build the class cache):
##   godot --headless --import
##   godot --headless --script res://tests/test_language_changed_signal.gd
## Or: powershell -File tests/run_tests.ps1 -GodotExe <path-to-godot>

const ImporterScript := preload("res://addons/storyflow/editor/storyflow_importer.gd")
const ManagerScript := preload("res://addons/storyflow/core/storyflow_manager.gd")

const FIXTURE_DIR := "res://tests/fixtures/character-contract"

var _checks: int = 0
var _failures: int = 0
var _temp_root: String = ""
var _manager: Node = null

## Every code the signal delivered, what get_language() answered during each delivery, and how
## many rows get_languages() held then - which project was installed at that moment.
var _codes: Array[String] = []
var _observed: Array[String] = []
var _roster_sizes: Array[int] = []


func _initialize() -> void:
	await process_frame
	_temp_root = OS.get_user_data_dir().path_join("sf_language_signal_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(_temp_root)
	_manager = ManagerScript.new()
	_manager.name = "StoryFlowRuntime"
	get_root().add_child(_manager)

	# Connected BEFORE any project is installed, which is the whole point of the install cases:
	# a game connecting in _ready would be racing the install.
	_manager.language_changed.connect(_on_language_changed)

	_test_install_is_silent()
	_test_a_real_change_fires_once()
	_test_a_no_op_is_silent()
	_test_a_refusal_is_silent()
	_test_the_snap_emits()

	_rm_rf(_temp_root)

	if _failures == 0:
		print("ALL %d CHECKS PASSED" % _checks)
	else:
		print("%d OF %d CHECKS FAILED" % [_failures, _checks])
	quit(1 if _failures > 0 else 0)


func _on_language_changed(language_code: String) -> void:
	_codes.append(language_code)
	_observed.append(_manager.get_language())
	_roster_sizes.append(_manager.get_languages().size())


func _check(label: String, ok: bool) -> bool:
	_checks += 1
	if not ok:
		_failures += 1
		printerr("FAIL: %s" % label)
	return ok


## The manager starts on "en" and this project's source language is "en", so nothing moved.
func _test_install_is_silent() -> void:
	var project = _import_build("localized", true)
	if not _check("[setup] the localized package imports", project != null):
		return
	_check("an install that moves nothing emits nothing", _codes.size() == 0)
	_check("and it left the game in the project's source language", _manager.get_language() == "en")


func _test_a_real_change_fires_once() -> void:
	_check("the engine accepts fr", _manager.set_language("fr"))
	if _check("a real change emits once", _codes.size() == 1):
		_check("carrying the new code", _codes[0] == "fr")
		_check("and get_language already answers it during the emit", _observed[0] == "fr")


func _test_a_no_op_is_silent() -> void:
	_check("re-setting the active language still returns true", _manager.set_language("fr"))
	_check("but emits nothing", _codes.size() == 1)


func _test_a_refusal_is_silent() -> void:
	_check("an unknown code is refused", not _manager.set_language("de"))
	_check("an empty code is refused", not _manager.set_language(""))
	_check("and neither emits", _codes.size() == 1)
	_check("the player is still in the language they picked", _manager.get_language() == "fr")


## An unlocalized project cannot carry "fr", so installing one MOVES the language - and that one
## emits, because it is a real change to what the player is reading.
func _test_the_snap_emits() -> void:
	var plain = _import_build("plain", false)
	if not _check("[setup] the unlocalized package imports", plain != null):
		return
	_check("the install really did snap the language, so the case has teeth", _manager.get_language() != "fr")
	if _check("an install that snaps the language emits once", _codes.size() == 2):
		_check("carrying the code it snapped to", _codes[1] == _manager.get_language())
		_check("and get_language already answers it during the emit", _observed[1] == _manager.get_language())
		# The INCOMING project is installed by the time the emit lands: an unlocalized project has
		# an empty roster, the outgoing one had rows.
		_check("and the incoming project is the one installed", _roster_sizes[1] == 0)


## Write one build folder and install it, returning the project. `localized` decides whether the
## sidecar goes in, which is what makes a project able to carry a non-source language at all.
func _import_build(label: String, localized: bool):
	var build := _temp("%s/build" % label)
	DirAccess.make_dir_recursive_absolute(build)
	_write_text(build.path_join("project.storyflow"), JSON.stringify({
		"version": "1.0",
		"metadata": {"title": "LanguageChangedSignal"},
	}, "\t"))
	_write_text(build.path_join("data-assets.json"), _read_text(FIXTURE_DIR.path_join("data-assets.json")))
	if localized:
		_write_text(build.path_join("localization.json"), _read_text(FIXTURE_DIR.path_join("localization.json")))
	var project = ImporterScript.new().import_project(build, _temp("%s/out" % label))
	if project == null:
		return null
	_manager.set_project(project)
	return project


func _temp(relative: String) -> String:
	return _temp_root.path_join(relative)


func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	return "" if file == null else file.get_as_text()


func _write_text(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(text)


func _rm_rf(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var child := path.path_join(entry)
		if dir.current_is_dir():
			_rm_rf(child)
		else:
			DirAccess.remove_absolute(child)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)
