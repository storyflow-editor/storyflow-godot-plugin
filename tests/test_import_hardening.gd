extends SceneTree
## Headless tests for the sync/import write path (StoryFlowImporter).
##
## Pins the hardening of everything the importer WRITES, using real files in a
## temporary directory outside the Godot project:
##   1. Import metadata is written atomically — a write that cannot complete
##      leaves the previous storyflow_import_meta.json intact instead of a
##      truncated file that breaks project auto-discovery on the next launch.
##   2. Write failures (media copies, bulk copies, metadata) are counted and
##      reported instead of being swallowed, and the count reaches the editor
##      dock through the importer and the WebSocket sync.
##
## Run from the repository root (import first to build the class cache):
##   godot --headless --import
##   godot --headless --script res://tests/test_import_hardening.gd
## Or: powershell -File tests/run_tests.ps1 -GodotExe <path-to-godot>

const ImporterScript := preload("res://addons/storyflow/editor/storyflow_importer.gd")
const WsSyncScript := preload("res://addons/storyflow/editor/storyflow_websocket_sync.gd")

const META_NAME := "storyflow_import_meta.json"

var _checks: int = 0
var _failures: int = 0
var _temp_root: String = ""


func _initialize() -> void:
	await process_frame
	_temp_root = OS.get_user_data_dir().path_join("sf_import_hardening_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(_temp_root)

	_test_meta_written_on_import()
	_test_failed_meta_write_preserves_previous()
	_test_meta_helper_round_trip()
	_test_meta_helper_reports_failure()
	_test_clean_import_reports_no_errors()
	_test_media_copy_failure_is_counted()
	_test_bulk_copy_failure_is_counted()
	_test_meta_failure_is_counted()
	_test_sync_reports_error_count()

	_rm_rf(_temp_root)

	if _failures == 0:
		print("ALL %d CHECKS PASSED" % _checks)
	else:
		print("%d OF %d CHECKS FAILED" % [_failures, _checks])
	quit(1 if _failures > 0 else 0)


# =============================================================================
# Metadata writes
# =============================================================================

## Baseline: a clean import writes the metadata the manager auto-discovers.
func _test_meta_written_on_import() -> void:
	var build := _temp("meta_ok/build")
	var out := _temp("meta_ok/out")
	_write_build(build, "assets/pic.png")

	var importer := ImporterScript.new()
	var project := importer.import_project(build, out)
	_check("clean import returns a project", project != null)

	var meta = JSON.parse_string(_read_text(out.path_join(META_NAME)))
	_check("import writes storyflow_import_meta.json", meta is Dictionary)
	if meta is Dictionary:
		_check("meta records the output dir", meta.get("output_dir", "") == out)
		_check("meta lists the imported scripts", meta.get("script_paths", []) == ["Main"])
		_check("meta records the import time", not str(meta.get("imported_at", "")).is_empty())


## A metadata write that cannot complete must leave the previous file intact.
## The staging path is occupied by a directory, so the new content can never be
## staged; the already-published metadata must survive untouched.
func _test_failed_meta_write_preserves_previous() -> void:
	var build := _temp("meta_atomic/build")
	var out := _temp("meta_atomic/out")
	_write_build(build, "")

	var importer := ImporterScript.new()
	importer.import_project(build, out)
	var published := _read_text(out.path_join(META_NAME))
	_check("baseline metadata published", published.contains("\"Main\""))

	# Block the staging path and change the project so a successful write would
	# be observable (script_paths would grow to two entries).
	DirAccess.make_dir_recursive_absolute(out.path_join(META_NAME + ".tmp"))
	_write_text(build.path_join("Second.json"), JSON.stringify({"nodes": {"0": {"type": "start"}}}))

	var importer2 := ImporterScript.new()
	var project2 := importer2.import_project(build, out)
	_check("import still succeeds when metadata cannot be written", project2 != null)
	_check("second script was actually imported (sabotage is metadata-only)",
		project2 != null and project2.scripts.size() == 2)
	_check("previous metadata survives a failed write byte for byte",
		_read_text(out.path_join(META_NAME)) == published)


## Both metadata call sites (import and sync) share one helper, so the helper
## itself is pinned directly: it publishes exactly the payload it was given and
## leaves no staging file behind.
func _test_meta_helper_round_trip() -> void:
	var out := _temp("meta_helper")
	var payload := {"output_dir": out, "script_paths": ["A", "B"], "synced_at": "now"}

	var err := ImporterScript.write_import_meta(out, payload)
	_check("write_import_meta reports success", err == OK)

	var written = JSON.parse_string(_read_text(out.path_join(META_NAME)))
	_check("payload is published verbatim", written == payload)
	_check("no staging file is left behind", _list_files(out) == PackedStringArray([META_NAME]))


func _test_meta_helper_reports_failure() -> void:
	var out := _temp("meta_helper_fail")
	DirAccess.make_dir_recursive_absolute(out.path_join(META_NAME + ImporterScript.IMPORT_META_TEMP_SUFFIX))

	var err := ImporterScript.write_import_meta(out, {"script_paths": []})
	_check("blocked write_import_meta reports an error", err != OK)
	_check("nothing was published", not FileAccess.file_exists(out.path_join(META_NAME)))


# =============================================================================
# Failure accounting reaching the dock
# =============================================================================

## A clean import must not report phantom failures.
func _test_clean_import_reports_no_errors() -> void:
	var build := _temp("clean/build")
	var out := _temp("clean/out")
	_write_build(build, "assets/pic.png")

	var importer := ImporterScript.new()
	var project := importer.import_project(build, out)
	_check("clean import succeeds", project != null)
	_check("clean import reports 0 errors (got %d)" % importer.get_error_count(),
		importer.get_error_count() == 0)


## A media file that cannot be copied is counted, not swallowed.
func _test_media_copy_failure_is_counted() -> void:
	var build := _temp("media_fail/build")
	var out := _temp("media_fail/out")
	_write_build(build, "assets/pic.png")
	# Occupy the media destination with a directory so the copy cannot succeed.
	DirAccess.make_dir_recursive_absolute(out.path_join("images/pic.png"))

	var importer := ImporterScript.new()
	var project := importer.import_project(build, out)
	_check("import survives a failed media copy", project != null)
	_check("failed media copy is counted (got %d)" % importer.get_error_count(),
		importer.get_error_count() == 1)


## The blanket build-directory copy counts its failures too.
func _test_bulk_copy_failure_is_counted() -> void:
	var build := _temp("bulk_fail/build")
	var out := _temp("bulk_fail/out")
	_write_build(build, "")
	_write_text(build.path_join("notes.txt"), "hello")
	# Occupy the destination with a directory so the copy cannot succeed.
	DirAccess.make_dir_recursive_absolute(out.path_join("notes.txt"))

	var importer := ImporterScript.new()
	var project := importer.import_project(build, out)
	_check("import survives a failed bulk copy", project != null)
	_check("failed bulk copy is counted (got %d)" % importer.get_error_count(),
		importer.get_error_count() == 1)


## The metadata write is part of the same accounting.
func _test_meta_failure_is_counted() -> void:
	var build := _temp("meta_count/build")
	var out := _temp("meta_count/out")
	_write_build(build, "")
	DirAccess.make_dir_recursive_absolute(out.path_join(META_NAME + ImporterScript.IMPORT_META_TEMP_SUFFIX))

	var importer := ImporterScript.new()
	var project := importer.import_project(build, out)
	_check("import survives a failed metadata write", project != null)
	_check("failed metadata write is counted (got %d)" % importer.get_error_count(),
		importer.get_error_count() == 1)

## The dock reports sync results from StoryFlowWebSocketSync.sync_complete.
## A sync whose writes partially failed must not be reported as a clean success,
## so the signal carries the failure count alongside the project.
func _test_sync_reports_error_count() -> void:
	var root := _temp("ws_sync")
	var build := root.path_join("build")
	var out := _temp("ws_sync_out")
	_write_build(build, "")

	# Make the metadata write fail so the sync has something to report.
	DirAccess.make_dir_recursive_absolute(out.path_join(META_NAME))

	var ws := WsSyncScript.new()
	ws.set_output_dir(out)
	var seen := {"project": null, "errors": -1}
	ws.sync_complete.connect(func(project, error_count):
		seen["project"] = project
		seen["errors"] = error_count)
	ws._handle_project_updated({"payload": {"projectPath": root}})

	_check("sync_complete delivered the project", seen["project"] != null)
	_check("sync_complete reports the failed metadata write (got %s)" % seen["errors"],
		seen["errors"] is int and seen["errors"] > 0)


# =============================================================================
# Helpers
# =============================================================================

func _check(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  PASS: %s" % label)
	else:
		_failures += 1
		printerr("  FAIL: %s" % label)


func _temp(relative: String) -> String:
	var path := _temp_root.path_join(relative)
	DirAccess.make_dir_recursive_absolute(path)
	return path


## Write a minimal exported build: project.storyflow with one inline script,
## optionally referencing an image asset that really exists on disk.
func _write_build(build_dir: String, asset_relative: String) -> void:
	DirAccess.make_dir_recursive_absolute(build_dir)

	var script_data := {
		"nodes": {"0": {"type": "start"}},
		"connections": [],
	}
	if not asset_relative.is_empty():
		script_data["assets"] = {"pic": {"type": "image", "path": asset_relative}}
		var image_path := build_dir.path_join(asset_relative)
		DirAccess.make_dir_recursive_absolute(image_path.get_base_dir())
		var image := Image.create_empty(2, 2, false, Image.FORMAT_RGB8)
		image.fill(Color.RED)
		image.save_png(image_path)

	_write_text(build_dir.path_join("project.storyflow"), JSON.stringify({
		"version": "1.0",
		"metadata": {"title": "HardeningTest"},
		"startupScript": "Main",
		"scripts": {"Main": script_data},
	}, "\t"))


func _write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr("  SETUP FAILURE: cannot write %s" % path)
		return
	file.store_string(text)
	file.close()


func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text


## Sorted names of the plain files directly inside [param dir].
static func _list_files(dir_path: String) -> PackedStringArray:
	var results := PackedStringArray()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return results
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir():
			results.append(name)
		name = dir.get_next()
	dir.list_dir_end()
	results.sort()
	return results


static func _rm_rf(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name != "." and name != "..":
			var child := path.path_join(name)
			if dir.current_is_dir():
				_rm_rf(child)
			else:
				DirAccess.remove_absolute(child)
		name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)
