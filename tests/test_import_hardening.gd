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
	_test_unchanged_files_are_not_rewritten()
	_test_project_file_is_published_as_json()
	_test_legacy_project_json_builds_still_publish()
	_test_media_is_written_once_per_sync()
	_test_media_whose_build_path_matches_the_asset_directory()
	_test_media_whose_build_path_differs_only_in_case()
	_test_data_assets_are_imported_and_never_become_a_script()
	_test_data_asset_media_reaches_the_project_pool()
	_test_inline_import_carries_data_assets()
	_test_localization_is_imported_and_never_becomes_a_script()
	_test_localization_degraded_ladder()
	_test_inline_import_carries_localization()
	# Runaway-recursion guard last: without it this scenario never returns.
	_test_nested_output_is_refused()

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
# Copying: unchanged files, duplicate writes, nested directories
# =============================================================================

## Every sync used to rewrite every file, which also re-triggered Godot's import
## of the copied project.storyflow. Files whose content is unchanged must be
## left alone; content that really changed must still be copied, including an
## edit that keeps the file length identical.
func _test_unchanged_files_are_not_rewritten() -> void:
	var build := _temp("unchanged/build")
	var out := _temp("unchanged/out")
	_write_build(build, "assets/pic.png")
	_write_text(build.path_join("notes.txt"), "hello")

	var first := ImporterScript.new()
	_check("first import succeeds", first.import_project(build, out) != null)
	var stamps := {
		"notes.txt": _modified_time(out.path_join("notes.txt")),
		"project.json": _modified_time(out.path_join("project.json")),
		"images/pic.png": _modified_time(out.path_join("images/pic.png")),
	}
	_check("first import produced the files", not stamps.values().has(0))

	# The modification timestamp has one-second resolution, so wait long enough
	# that a rewrite would be visible.
	OS.delay_msec(1200)

	var second := ImporterScript.new()
	_check("second import succeeds", second.import_project(build, out) != null)
	_check("second import reports no errors (got %d)" % second.get_error_count(),
		second.get_error_count() == 0)
	for relative in stamps:
		_check("unchanged %s is not rewritten" % relative,
			_modified_time(out.path_join(relative)) == stamps[relative])

	# A same-length edit must still be copied: length alone cannot decide.
	_write_text(build.path_join("notes.txt"), "world")
	var third := ImporterScript.new()
	_check("third import succeeds", third.import_project(build, out) != null)
	_check("a changed file of identical length is still copied",
		_read_text(out.path_join("notes.txt")) == "world")


## Exported games pack .json files as raw bytes but leave .storyflow files
## unreadable: an unimported one is not packed at all, an imported one is
## replaced by the import plugin's marker resource, and neither is reachable
## through FileAccess. The sync must therefore publish the project file into the
## output directory under the project.json name, and remove the raw
## project.storyflow an older plugin version copied there — otherwise exported
## games silently fail to auto-load the project.
func _test_project_file_is_published_as_json() -> void:
	var build := _temp("project_json/build")
	var out := _temp("project_json/out")
	_write_build(build, "")

	var importer := ImporterScript.new()
	var project := importer.import_project(build, out)
	_check("import from a project.storyflow build succeeds", project != null)
	_check("publishing import reports no errors (got %d)" % importer.get_error_count(),
		importer.get_error_count() == 0)
	_check("the project file is published as project.json",
		_read_text(out.path_join("project.json")) == _read_text(build.path_join("project.storyflow")))
	_check("no raw project.storyflow lands in the output directory",
		not FileAccess.file_exists(out.path_join("project.storyflow")))

	# An older plugin version copied project.storyflow verbatim, and under res://
	# the import plugin left an .import sidecar next to it. An exported game never
	# sees either, so a re-sync must clean them up the same way it removes stale
	# media duplicates.
	_write_text(out.path_join("project.storyflow"), "stale copy from an older sync")
	_write_text(out.path_join("project.storyflow.import"), "[remap]\n")
	var second := ImporterScript.new()
	_check("re-import over a stale project.storyflow succeeds",
		second.import_project(build, out) != null)
	_check("re-import reports no errors (got %d)" % second.get_error_count(),
		second.get_error_count() == 0)
	_check("the stale project.storyflow is removed",
		not FileAccess.file_exists(out.path_join("project.storyflow")))
	_check("its orphaned .import sidecar goes with it",
		not FileAccess.file_exists(out.path_join("project.storyflow.import")))
	_check("the published project.json survives the cleanup",
		_read_text(out.path_join("project.json")) == _read_text(build.path_join("project.storyflow")))

	# The output directory is exactly what an exported game reloads at startup.
	var reloaded := ImporterScript.new().load_project_local(out)
	_check("reloading the output directory succeeds", reloaded != null)
	_check("the reloaded project keeps its scripts",
		reloaded != null and reloaded.scripts.has("Main"))

	# A build dropped straight into the output directory (build == output) must
	# publish project.json as well — that layout is otherwise never blanket-copied
	# — while leaving the user's source project.storyflow in place.
	var dropin := _temp("project_json_dropin")
	_write_build(dropin, "")
	var dropin_project := ImporterScript.new().load_project_local(dropin)
	_check("loading a dropped-in build succeeds", dropin_project != null)
	_check("the dropped-in project file is also published as project.json",
		_read_text(dropin.path_join("project.json")) == _read_text(dropin.path_join("project.storyflow")))
	_check("the dropped-in source project.storyflow is left in place",
		FileAccess.file_exists(dropin.path_join("project.storyflow")))


## A build that still ships the legacy project.json name must keep working, and
## when both names are present the published project.json must hold the content
## of the file the import actually parsed — project.storyflow wins, and the
## stale build-side project.json must not overwrite it.
func _test_legacy_project_json_builds_still_publish() -> void:
	var legacy_build := _temp("project_json_legacy/build")
	var legacy_out := _temp("project_json_legacy/out")
	_write_build(legacy_build, "")
	var storyflow_content := _read_text(legacy_build.path_join("project.storyflow"))
	DirAccess.remove_absolute(legacy_build.path_join("project.storyflow"))
	_write_text(legacy_build.path_join("project.json"), storyflow_content)

	var importer := ImporterScript.new()
	_check("import from a legacy project.json build succeeds",
		importer.import_project(legacy_build, legacy_out) != null)
	_check("legacy import reports no errors (got %d)" % importer.get_error_count(),
		importer.get_error_count() == 0)
	_check("the legacy project file is published as project.json",
		_read_text(legacy_out.path_join("project.json")) == storyflow_content)

	var both_build := _temp("project_json_both/build")
	var both_out := _temp("project_json_both/out")
	_write_build(both_build, "")
	_write_text(both_build.path_join("project.json"), "{\"stale\": true}")

	var both := ImporterScript.new()
	_check("import from a build with both project files succeeds",
		both.import_project(both_build, both_out) != null)
	_check("both-names import reports no errors (got %d)" % both.get_error_count(),
		both.get_error_count() == 0)
	_check("project.storyflow wins over the stale build-side project.json",
		_read_text(both_out.path_join("project.json")) == _read_text(both_build.path_join("project.storyflow")))


## Media used to be written twice per sync: once into images/ by the asset
## import, then again by the blanket copy of the whole build directory at its
## original relative path. Runtime resolution uses the images/ copy, so the
## duplicate is pure disk churn.
func _test_media_is_written_once_per_sync() -> void:
	var build := _temp("media_once/build")
	var out := _temp("media_once/out")
	_write_build(build, "assets/pic.png")

	var importer := ImporterScript.new()
	var project := importer.import_project(build, out)
	_check("import with media succeeds", project != null)
	_check("import with media reports no errors (got %d)" % importer.get_error_count(),
		importer.get_error_count() == 0)
	_check("media landed in the asset directory",
		FileAccess.file_exists(out.path_join("images/pic.png")))
	_check("media was written exactly once (got %d copies)" % _count_files(out, "pic.png"),
		_count_files(out, "pic.png") == 1)

	# A duplicate left by an older import is stale the moment the media changes,
	# and the in-place reload below would copy it over the fresh one.
	DirAccess.make_dir_recursive_absolute(out.path_join("assets"))
	_write_text(out.path_join("assets/pic.png"), "stale copy from an older sync")
	# Under res:// Godot leaves an .import sidecar next to every media file.
	_write_text(out.path_join("assets/pic.png.import"), "[remap]\n")
	var second := ImporterScript.new()
	_check("re-import with a leftover duplicate succeeds", second.import_project(build, out) != null)
	_check("re-import reports no errors (got %d)" % second.get_error_count(),
		second.get_error_count() == 0)
	_check("a duplicate left by an older import is removed",
		_count_files(out, "pic.png") == 1)

	_check("the orphaned .import sidecar goes with it",
		not FileAccess.file_exists(out.path_join("assets/pic.png.import")))
	_check("the emptied duplicate directory is cleaned up",
		not DirAccess.dir_exists_absolute(out.path_join("assets")))

	# Export correctness: the runtime reloads the output directory in place and
	# must still resolve the asset from the single remaining copy.
	var reloaded := ImporterScript.new().load_project_local(out)
	_check("reloading the output directory succeeds", reloaded != null)
	var script = reloaded.scripts.get("Main") if reloaded else null
	_check("the asset still resolves to a resource after the reload",
		script != null and script.resolved_assets.get("pic") is Resource)


## The asset import publishes media into images/, audio/ or media/. When the
## build-relative path already lives in a directory of that name, the blanket
## copy's destination IS the file the asset import just published: it must never
## be mistaken for a redundant duplicate and deleted.
func _test_media_whose_build_path_matches_the_asset_directory() -> void:
	var build := _temp("media_same_dir/build")
	var out := _temp("media_same_dir/out")
	_write_build(build, "images/pic.png")

	var importer := ImporterScript.new()
	var project := importer.import_project(build, out)
	_check("import of media under images/ succeeds", project != null)
	_check("import of media under images/ reports no errors (got %d)" % importer.get_error_count(),
		importer.get_error_count() == 0)
	_check("the published media file survives the sync",
		FileAccess.file_exists(out.path_join("images/pic.png")))
	_check("media is still written exactly once (got %d copies)" % _count_files(out, "pic.png"),
		_count_files(out, "pic.png") == 1)

	var reloaded := ImporterScript.new().load_project_local(out)
	_check("reloading after an images/ layout sync succeeds", reloaded != null)
	var script = reloaded.scripts.get("Main") if reloaded else null
	_check("the images/ layout asset still resolves after the reload",
		script != null and script.resolved_assets.get("pic") is Resource)


## Same collision as above, but the build-relative directory differs from the
## asset directory only in case. On a case-insensitive filesystem the blanket
## destination is still the published file, reached under a different spelling.
func _test_media_whose_build_path_differs_only_in_case() -> void:
	var build := _temp("media_mixed_case/build")
	var out := _temp("media_mixed_case/out")
	_write_build(build, "Images/pic.png")

	var importer := ImporterScript.new()
	var project := importer.import_project(build, out)
	_check("import of media under Images/ succeeds", project != null)
	_check("import of media under Images/ reports no errors (got %d)" % importer.get_error_count(),
		importer.get_error_count() == 0)
	_check("the published media file survives a case-differing build path",
		FileAccess.file_exists(out.path_join("images/pic.png")))

	# Where case does not distinguish paths, the duplicate never existed and the
	# published file is the only copy. Where it does, the blanket copy legitimately
	# wrote a second, distinct file: declining to delete it is the safe direction.
	var case_insensitive := FileAccess.file_exists(out.path_join("IMAGES/pic.png"))
	var copies := _count_files(out, "pic.png")
	if case_insensitive:
		_check("media is written exactly once on this filesystem (got %d)" % copies, copies == 1)
	else:
		_check("the distinct-by-case copy is kept rather than deleted (got %d)" % copies, copies == 2)

	var reloaded := ImporterScript.new().load_project_local(out)
	_check("reloading after a case-differing sync succeeds", reloaded != null)
	var script = reloaded.scripts.get("Main") if reloaded else null
	_check("the case-differing layout asset still resolves after the reload",
		script != null and script.resolved_assets.get("pic") is Resource)


## An output directory nested inside the build directory used to make the
## recursive copy descend into its own output forever, filling the disk. It must
## refuse the nested step, report it, and still copy everything else.
func _test_nested_output_is_refused() -> void:
	var build := _temp("nested/build")
	var out := build.path_join("out")
	DirAccess.make_dir_recursive_absolute(out)
	_write_build(build, "")
	print("  (nested-output scenario starting)")

	var importer := ImporterScript.new()
	var project := importer.import_project(build, out)
	_check("import with a nested output directory returns", project != null)
	_check("files outside the nested directory are still copied",
		FileAccess.file_exists(out.path_join("project.json")))
	_check("the output directory was not copied into itself",
		not DirAccess.dir_exists_absolute(out.path_join("out")))
	_check("the refused copy is counted (got %d)" % importer.get_error_count(),
		importer.get_error_count() == 1)


# =============================================================================
# Data Assets
# =============================================================================

## data-assets.json must land in project.data_assets AND must never be swept up as a script.
##
## THE KILLER REGRESSION: the standalone-script sweep walks every .json file in the build
## directory, and load_project_local re-runs it on EVERY launch. A sidecar missing from the
## exclusion list becomes a phantom script named after its filename, silently, in shipped
## games — so the phantom check matters more than the parse check.
func _test_data_assets_are_imported_and_never_become_a_script() -> void:
	var build := _temp("data_assets/build")
	var out := _temp("data_assets/out")
	_write_build(build, "")
	_write_text(build.path_join("data-assets.json"), JSON.stringify(_data_assets_payload(), "\t"))

	var importer := ImporterScript.new()
	var project := importer.import_project(build, out)
	_check("import with data-assets.json returns a project", project != null)
	if project == null:
		return

	_check("data-assets.json does not become a phantom script",
		not project.scripts.has("data-assets"))
	_check("only the real script is imported (got %s)" % [project.scripts.keys()],
		project.scripts.size() == 1 and project.scripts.has("Main"))
	_check("data assets land on the project (got %d)" % project.data_assets.size(),
		project.data_assets.size() == 2)
	_check("the category row is dropped and the rest keep declaration order",
		project.data_assets.get("base", {}).get("variables", []).size() == 2)
	_check("overrides stay RAW for the store's second pass",
		project.data_assets.get("child", {}).get("raw_overrides", {}).has("hp"))

	# The re-sweep an exported game performs on every launch must stay clean too.
	var reloaded := importer.load_project_local(out)
	_check("reloading the output directory still produces no phantom script",
		reloaded != null and not reloaded.scripts.has("data-assets"))
	_check("reloading the output directory still carries the data assets",
		reloaded != null and reloaded.data_assets.size() == 2)


## import_project_from_json is public API and must carry data assets too — the parallel inline
## importer silently dropping them would leave a synced project with no .sfd state.
func _test_inline_import_carries_data_assets() -> void:
	var importer := ImporterScript.new()

	var flat := importer.import_project_from_json({
		"version": "1.0",
		"scripts": {"Main": {"nodes": {"0": {"type": "start"}}, "connections": []}},
		"dataAssets": _data_assets_payload()["dataAssets"],
	})
	_check("inline import returns a project", flat != null)
	_check("inline import carries the data assets",
		flat != null and flat.data_assets.size() == 2)
	_check("inline import parses declarations the same way",
		flat != null and flat.data_assets.get("base", {}).get("variables", []).size() == 2)

	# The data-assets.json wrapper shape is accepted too, matching how the characters block
	# accepts either nesting.
	var wrapped := importer.import_project_from_json({
		"version": "1.0",
		"dataAssets": _data_assets_payload(),
	})
	_check("inline import accepts the data-assets.json wrapper shape",
		wrapped != null and wrapped.data_assets.size() == 2)


# =============================================================================
# Localization (localization.json, spec §9)
# =============================================================================

## localization.json must land on the project AND must never be swept up as a script — the same
## killer regression the data-assets test above guards, reached through the newest sidecar.
##
## THE FILE-PRESENCE MARKER is asserted in both directions here, because that is the whole branch
## this contract has: a build WITH the file is a localized project, a build WITHOUT it is a
## pre-localization export and behaves exactly as this plugin did before localization existed.
func _test_localization_is_imported_and_never_becomes_a_script() -> void:
	var build := _temp("localization/build")
	var out := _temp("localization/out")
	_write_build(build, "")
	_write_text(build.path_join("localization.json"), JSON.stringify(_localization_payload(), "\t"))

	var importer := ImporterScript.new()
	var project := importer.import_project(build, out)
	_check("import with localization.json returns a project", project != null)
	if project == null:
		return

	_check("localization.json does not become a phantom script",
		not project.scripts.has("localization"))
	_check("only the real script is imported (got %s)" % [project.scripts.keys()],
		project.scripts.size() == 1 and project.scripts.has("Main"))
	_check("the presence marker is set", project.has_localization)
	_check("the source language is read (got '%s')" % project.source_language,
		project.source_language == "en")
	_check("the registry keeps the author's order (got %s)" % [project.languages],
		project.languages.size() == 2
			and project.languages[0].get("code") == "fr" and project.languages[0].get("name") == "French"
			and project.languages[1].get("code") == "es")
	_check("a language with no label falls back to its own code",
		project.languages[1].get("name") == "es")
	_check("both tables land (got %s)" % [project.language_strings.keys()],
		project.language_strings.size() == 2)
	_check("rows are stored verbatim",
		project.language_strings.get("fr", {}).get("1.text", "") == "Bien le bonjour.")
	_check("a non-string row is skipped, trusted-seed posture",
		not project.language_strings.get("fr", {}).has("bad.row"))

	# The re-sweep an exported game performs on every launch must stay clean too.
	var reloaded := importer.load_project_local(out)
	_check("reloading the output directory still produces no phantom script",
		reloaded != null and not reloaded.scripts.has("localization"))
	_check("reloading the output directory still carries the tables",
		reloaded != null and reloaded.has_localization and reloaded.language_strings.size() == 2)

	# THE ABSENT SIDECAR: a genuinely pre-localization build, source-only and untouched.
	var plain_build := _temp("localization_absent/build")
	var plain_out := _temp("localization_absent/out")
	_write_build(plain_build, "")
	var plain := ImporterScript.new().import_project(plain_build, plain_out)
	_check("a build with no localization.json is not a localized project",
		plain != null and not plain.has_localization)
	_check("and registers no tables", plain != null and plain.language_strings.is_empty())


## The degraded ladder: every refusing rung leaves the project SOURCE-ONLY (has_localization
## false, no tables), so strings keep resolving to their source text instead of the import failing.
##
## The MISSING and UNSUPPORTED schemaVersion rungs are separate cases because they are separate
## warnings: a sidecar that declares no version and one that declares a version this plugin cannot
## read are different authoring situations, and a single `.get("schemaVersion", "")` would answer
## the same thing for both and collapse them.
func _test_localization_degraded_ladder() -> void:
	var no_version := _localization_payload()
	no_version.erase("schemaVersion")
	_assert_localization_refused("a MISSING schemaVersion", no_version)

	var bad_version := _localization_payload()
	bad_version["schemaVersion"] = "2"
	_assert_localization_refused("an UNSUPPORTED schemaVersion", bad_version)

	var empty_version := _localization_payload()
	empty_version["schemaVersion"] = ""
	_assert_localization_refused("a present-but-EMPTY schemaVersion", empty_version)

	var no_strings := _localization_payload()
	no_strings.erase("strings")
	_assert_localization_refused("no strings object", no_strings)

	# AN UNQUOTED 1 IS REFUSED, AND THIS IS A VERSION-INDEPENDENCE PIN, not a formatting one.
	# Godot's JSON parses every number as a float, and the PRINTED form of a whole-valued float
	# differs across engine builds (4.3 renders 1.0 as "1", 4.6 as "1.0"). A gate that compared
	# str(value) would therefore accept this document on one Godot and refuse it on another - the
	# degraded ladder answering differently depending on which engine a game shipped on. The
	# reader requires a genuine String instead, so this case must fail identically everywhere.
	# The exporter always writes the quoted "1", so an unquoted one only ever reaches a
	# hand-edited sidecar, and refusing it degrades to source text rather than mis-reading a
	# version.
	var numeric_version := _localization_payload()
	numeric_version["schemaVersion"] = 1
	_assert_localization_refused("an UNQUOTED numeric schemaVersion", numeric_version)

	# The same rule one step further out: a schemaVersion that is not a scalar at all.
	var array_version := _localization_payload()
	array_version["schemaVersion"] = ["1"]
	_assert_localization_refused("a NON-SCALAR schemaVersion", array_version)

	# And the type rule on the fields the reader keeps: a non-string code is dropped from the
	# registry, a non-string label falls back to its code, and a non-string sourceLanguage leaves
	# the default in place - none of them coerced through str(), for the version reason above.
	var typed := _localization_payload()
	typed["sourceLanguage"] = 7
	typed["languages"] = [{"code": 1, "name": "Numeric"}, {"code": "fr", "name": 2}]
	var mistyped := _import_with_localization("loc_mistyped", typed)
	_check("a non-string sourceLanguage leaves the default in place",
		mistyped != null and mistyped.source_language == "en")
	_check("a non-string language code is dropped from the registry",
		mistyped != null and mistyped.languages.size() == 1
			and mistyped.languages[0].get("code") == "fr")
	_check("a non-string label falls back to its own code",
		mistyped != null and mistyped.languages[0].get("name") == "fr")

	# THE ABSENT-VS-EMPTY CONVERGENCE, and why the marker is a bool: a sidecar carrying NO tables
	# at all is still a LOCALIZED project. An author who registered nothing yet has not shipped a
	# pre-localization export, and a key count cannot tell the two apart.
	var empty_tables := _localization_payload()
	empty_tables["languages"] = []
	empty_tables["strings"] = {}
	var empty := _import_with_localization("loc_empty", empty_tables)
	_check("a present-but-EMPTY sidecar is still a localized project",
		empty != null and empty.has_localization)
	_check("and it registers no tables, exactly like the absent one",
		empty != null and empty.language_strings.is_empty())


## One refused rung: the document imports, the project stays source-only.
func _assert_localization_refused(label: String, payload: Dictionary) -> void:
	var project := _import_with_localization("loc_%d" % _checks, payload)
	_check("%s leaves the project source-only" % label,
		project != null and not project.has_localization)
	_check("%s registers no tables" % label,
		project != null and project.language_strings.is_empty())


func _import_with_localization(label: String, payload: Dictionary) -> StoryFlowProject:
	var build := _temp("%s/build" % label)
	var out := _temp("%s/out" % label)
	_write_build(build, "")
	_write_text(build.path_join("localization.json"), JSON.stringify(payload, "\t"))
	return ImporterScript.new().import_project(build, out)


## import_project_from_json is public API and must carry the sidecar too — the parallel inline
## importer silently dropping it would leave a synced project reading only source text, with no
## sign anything was missed.
func _test_inline_import_carries_localization() -> void:
	var importer := ImporterScript.new()

	var flat := importer.import_project_from_json({
		"version": "1.0",
		"scripts": {"Main": {"nodes": {"0": {"type": "start"}}, "connections": []}},
		"localization": _localization_payload(),
	})
	_check("inline import returns a project", flat != null)
	_check("inline import carries the presence marker", flat != null and flat.has_localization)
	_check("inline import carries both tables",
		flat != null and flat.language_strings.size() == 2)

	# The wrapper nesting is accepted too, matching how the characters and dataAssets blocks
	# accept either shape.
	var wrapped := importer.import_project_from_json({
		"version": "1.0",
		"localization": {"localization": _localization_payload()},
	})
	_check("inline import accepts the wrapper shape",
		wrapped != null and wrapped.has_localization and wrapped.language_strings.size() == 2)

	# No key at all is a pre-localization payload — the inline arm's form of the file-presence
	# marker.
	var none := importer.import_project_from_json({"version": "1.0"})
	_check("an inline payload with no localization key is a source-only project",
		none != null and not none.has_localization)

	# A refused rung degrades the same way here as on the disk arm (one shared parse).
	var refused := importer.import_project_from_json({
		"version": "1.0",
		"localization": {"sourceLanguage": "en", "strings": {"fr": {}}},
	})
	_check("the inline arm runs the same degraded ladder",
		refused != null and not refused.has_localization)


## A two-language sidecar in the shipped shape: full, PRE-RESOLVED tables (no status, no hash),
## one row deliberately non-string to exercise the trusted-seed skip, and one registry entry with
## no label. Small on purpose — the resolution goldens live in the character-contract package.
func _localization_payload() -> Dictionary:
	return {
		"schemaVersion": "1",
		"sourceLanguage": "en",
		"languages": [
			{"code": "fr", "name": "French"},
			{"code": "es"},
		],
		"strings": {
			"fr": {
				"1.text": "Bien le bonjour.",
				"bad.row": 7,
			},
			"es": {
				"1.text": "Otra vez tu.",
			},
		},
	}


## A two-level .sfd family: a base with scalars and a category row, and a child overriding an
## inherited id. Small on purpose — the resolver's own goldens live in test_data_asset_store.gd.
## A .sfd image value resolves to a real imported resource (contract 2.1's 2026-09-04 amendment).
##
## The value ships as an asset KEY and data-assets.json carries its own "assets" registry; this
## pins the engine half of that bargain - the registry is imported into the PROJECT pool, which is
## the shared final fallback both image and audio resolution end at. Before it, a .sfd image value
## was a path to a file the import had never copied.
func _test_data_asset_media_reaches_the_project_pool() -> void:
	print("-- .sfd media into the project pool --")
	var build := _temp("da_media/build")
	var out := _temp("da_media/out")
	# _write_build plants a real 2x2 png at this path and wires it as a SCRIPT asset; the .sfd
	# registry below names the same file, which is what an export does when a script and a Data
	# Asset both point at one image.
	_write_build(build, "images/pic.png")

	var payload := _data_assets_payload()
	payload["dataAssets"]["base"]["variables"].append(
		{"id": "icon", "name": "icon", "type": "image", "value": "asset_image_900"})
	payload["assets"] = {"asset_image_900": {"id": "asset_image_900", "type": "image", "path": "images/pic.png"}}
	_write_text(build.path_join("data-assets.json"), JSON.stringify(payload, "	"))

	var project := ImporterScript.new().import_project(build, out)
	_check("import with .sfd media returns a project", project != null)
	if project == null:
		return

	# The value stays the KEY - the .sfd surface learns nothing about assets.
	var icon_decl: Dictionary = {}
	for decl in project.data_assets.get("base", {}).get("variables", []):
		if str(decl.get("id", "")) == "icon":
			icon_decl = decl
	# The declaration's value is TYPED at import (StoryFlowDataAssetStore.type_value), so it is read
	# through the variant rather than compared as a bare string.
	var icon_value = icon_decl.get("value", null)
	var icon_text: String = icon_value.get_string("") if icon_value != null and icon_value.has_method("get_string") else str(icon_value)
	_check("the image value is the asset key, not a path (got '%s')" % icon_text,
		icon_text == "asset_image_900")

	# THE HALF THAT WAS BROKEN: the key has to resolve to something the build contains.
	_check("the .sfd registry landed in the project pool",
		project.resolved_assets.get("asset_image_900") is Resource)

	# And it survives the re-sweep an exported game performs on every launch.
	var reloaded := ImporterScript.new().load_project_local(out)
	_check("and still resolves after the launch-time reload",
		reloaded != null and reloaded.resolved_assets.get("asset_image_900") is Resource)


func _data_assets_payload() -> Dictionary:
	return {
		"dataAssets": {
			"base": {
				"id": "base",
				"name": "CreatureBase",
				"parent": null,
				"variables": [
					{"id": "hp", "name": "hp", "type": "integer", "value": 100},
					{"id": "alive", "name": "alive", "type": "boolean", "value": true},
					{"id": "lore", "name": "lore", "type": "category"},
				],
				"overrides": {},
			},
			"child": {
				"id": "child",
				"name": "Goblin",
				"parent": "base",
				"variables": [],
				"overrides": {"hp": 150},
			},
		},
	}


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


## Unix timestamp of a file, or 0 when it does not exist.
static func _modified_time(path: String) -> int:
	if not FileAccess.file_exists(path):
		return 0
	return FileAccess.get_modified_time(path)


## Number of files named [param file_name] anywhere below [param dir_path].
static func _count_files(dir_path: String, file_name: String) -> int:
	var count := 0
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return 0
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if dir.current_is_dir():
			if name != "." and name != "..":
				count += _count_files(dir_path.path_join(name), file_name)
		elif name == file_name:
			count += 1
		name = dir.get_next()
	dir.list_dir_end()
	return count


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
