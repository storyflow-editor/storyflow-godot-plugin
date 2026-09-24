extends SceneTree

const BASE := "res://addons/storyflow/lipsync/"
var SPEECH := PackedFloat32Array([
	0.012, 0.022, 0.020, 0.016, 0.011, 0.0072, 0.0046, 0.0029,
	0.0018, 0.0011, 0.0007, 0.00043, 0.00027, 0.00017, 0.00010, 0.000064,
	0.000040, 0.000025, 0.000015, 0.0000096, 0.000006, 0.0000037, 0.0000023, 0.0000014,
])

var _checks := 0
var _failures := 0


func _initialize() -> void:
	for script_name in ["storyflow_viseme_table.gd", "storyflow_lipsync_driver.gd", "storyflow_viseme_map.gd", "storyflow_viseme_pose.gd", "storyflow_viseme_morph.gd"]:
		_check("port provides %s" % script_name, FileAccess.file_exists(BASE + script_name))
	if _failures == 0:
		_run_tests()
	print("Lipsync driver: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures else 0)


func _run_tests() -> void:
	var table_script: GDScript = load(BASE + "storyflow_viseme_table.gd")
	var driver_script: GDScript = load(BASE + "storyflow_lipsync_driver.gd")
	var map_script: GDScript = load(BASE + "storyflow_viseme_map.gd")
	var pose_script: GDScript = load(BASE + "storyflow_viseme_pose.gd")
	var morph_script: GDScript = load(BASE + "storyflow_viseme_morph.gd")
	var table: Dictionary = table_script.default_table()
	var owned: Array[String] = table_script.owned_morphs(table)
	_check("ten tuned poses", table.size() == 10)
	_check("empty rest pose", table["rest"].is_empty())
	_check("AA jaw is tuned", is_equal_approx(table["AA"]["jawOpen"], 0.85))
	_check("EE stretch is tuned", is_equal_approx(table["EE"]["mouthStretchLeft"], 0.78))
	_check("TH tongue extension is tuned", is_equal_approx(table["TH"]["tongueUp"], 0.28))
	_check("owned set has 18 mouth morphs", owned.size() == 18)
	_check("identity morph excluded", not owned.has("defaultBuff"))

	var driver = driver_script.new()
	for frame in range(60):
		driver.advance_from_magnitudes(SPEECH, 1.0 / 60.0)
	var jaw: float = driver.get_current().get("jawOpen", 0.0)
	_check("real speech opens jaw", jaw > 0.3)
	_check("level reports speech", driver.get_level() > 0.0)
	_check("raw peak is pre-transform", absf(driver.get_raw_peak() - 0.022) < 0.0001)
	_check("keys match indexed weights", absf(driver.get_weight(driver.keys.find("jawOpen")) - jaw) < 0.00001)

	var mixer = driver_script.new()
	mixer.full_scale = 5.66
	var scaled := PackedFloat32Array()
	for magnitude in SPEECH:
		scaled.append(magnitude * 5.66)
	for frame in range(60):
		mixer.advance_from_magnitudes(scaled, 1.0 / 60.0)
	_check("full scale cancels FFT scaling", absf(mixer.get_current()["jawOpen"] - jaw) < 0.01)
	_check("raw peak keeps FFT scaling", absf(mixer.get_raw_peak() - 0.022 * 5.66) < 0.0001)

	var low = driver_script.new()
	var high = driver_script.new()
	var low_bands := _bands_at(1)
	var high_bands := _bands_at(22)
	for frame in range(120):
		low.advance_from_magnitudes(low_bands, 1.0 / 60.0)
		high.advance_from_magnitudes(high_bands, 1.0 / 60.0)
	_check("low band puckers more", low.get_current()["mouthPucker"] > high.get_current()["mouthPucker"])
	_check("high band stretches more", high.get_current()["mouthStretchLeft"] > low.get_current()["mouthStretchLeft"])
	_check("centroid follows band", low.get_centroid() < high.get_centroid())
	var low_jaw: float = low.get_current()["jawOpen"]
	var poisoned := low_bands.duplicate()
	poisoned[3] = NAN
	low.advance_from_magnitudes(poisoned, 1.0 / 60.0)
	for frame in range(30):
		low.advance_from_magnitudes(low_bands, 1.0 / 60.0)
	_check("NaN sample cannot poison later mouth frames", not is_nan(low.get_current()["jawOpen"]) and absf(low.get_current()["jawOpen"] - low_jaw) < 0.02)
	var quiet := PackedFloat32Array()
	for magnitude in SPEECH:
		quiet.append(magnitude * 0.1)
	var slow = driver_script.new()
	var fast = driver_script.new()
	for frame in range(15):
		slow.advance_from_magnitudes(SPEECH, 1.0 / 30.0)
	for frame in range(45):
		slow.advance_from_magnitudes(quiet, 1.0 / 30.0)
	for frame in range(60):
		fast.advance_from_magnitudes(SPEECH, 1.0 / 120.0)
	for frame in range(180):
		fast.advance_from_magnitudes(quiet, 1.0 / 120.0)
	_check("peak follower does not saturate quiet test", slow.get_level() > 0.1 and slow.get_level() < 0.87)
	_check("smoothing and peak follower agree across frame rates", absf(slow.get_current()["jawOpen"] - fast.get_current()["jawOpen"]) < 0.02)
	var zero_bands := PackedFloat32Array()
	zero_bands.resize(24)
	var closing = driver_script.new()
	for frame in range(60):
		closing.advance_from_magnitudes(zero_bands, 1.0 / 60.0)
	_check("shut gate drives owned mouthClose", closing.get_current()["mouthClose"] > 0.2)

	var held: Dictionary = driver.get_current().duplicate()
	driver.advance_from_magnitudes(high_bands, 0.0)
	driver.advance_idle(0.0)
	driver.advance_silent(0.0)
	_check("zero delta holds the mouth", absf(driver.get_current()["jawOpen"] - held["jawOpen"]) < 0.000001)
	for frame in range(240):
		driver.advance_silent(1.0 / 60.0)
	_check("silence closes jaw", driver.get_current()["jawOpen"] < 0.01)
	_check("silence clears level", driver.get_level() == 0.0)
	driver.reset_level()
	_check("reset clears raw peak", driver.get_raw_peak() == 0.0)

	var custom := {"rest": {}, "OO": {"customShape": 1.0}, "OH": {"customShape": 1.0}, "AA": {"customShape": 1.0}, "EE": {"customShape": 1.0}}
	var custom_driver = driver_script.new(custom, 7)
	for frame in range(60):
		custom_driver.advance_from_magnitudes(SPEECH, 1.0 / 60.0)
	_check("custom map drives its own morph", custom_driver.get_current()["customShape"] > 0.05)
	_check("custom map owns only its morph", custom_driver.keys == ["customShape"])
	var posed_frames := 0
	for frame in range(600):
		custom_driver.advance_idle(1.0 / 60.0)
		if custom_driver.get_current()["customShape"] > 0.05:
			posed_frames += 1
	_check("idle uses active custom pose pool", posed_frames > 360)
	_check("idle clears audio meter", custom_driver.get_level() == 0.0)

	var viseme_map = map_script.new()
	_check("empty mapping falls back to tuned table", viseme_map.to_table()["AA"]["jawOpen"] == 0.85)
	var pose = pose_script.new()
	pose.pose = "OO"
	var morph = morph_script.new()
	morph.name = "myPucker"
	morph.weight = 0.6
	pose.morphs.append(morph)
	viseme_map.poses.append(pose)
	for axis_name in ["OH", "AA", "EE"]:
		var empty_axis = pose_script.new()
		empty_axis.pose = axis_name
		viseme_map.poses.append(empty_axis)
	var mapped: Dictionary = viseme_map.to_table()
	_check("custom mapping owns its authored shape", mapped["OO"]["myPucker"] == 0.6)
	_check("custom mapping adds rest", mapped.has("rest"))
	_check("custom mapping excludes built-in weights", not mapped["AA"].has("jawOpen"))
	viseme_map.name_style = map_script.NameStyle.MESH_BLENDS_PREFIX
	var resource_path := "user://lipsync_map_%d.tres" % Time.get_ticks_usec()
	var save_error := ResourceSaver.save(viseme_map, resource_path)
	_check("authored map saves as a resource", save_error == OK)
	if save_error == OK:
		var restored = ResourceLoader.load(resource_path, "", ResourceLoader.CACHE_MODE_IGNORE)
		_check("authored map reloads from disk", restored != null)
		if restored != null:
			_check("authored weight survives resource reload", is_equal_approx(restored.to_table()["OO"]["myPucker"], 0.6))
			_check("name style survives resource reload", restored.name_style == map_script.NameStyle.MESH_BLENDS_PREFIX)
			restored.reset_to_builtin = true
			_check("Inspector reset fills editable default poses", restored.poses.size() == 10)
			_check("Inspector reset returns toggle to false", not restored.reset_to_builtin)
			_check("Inspector reset restores tuned weights", is_equal_approx(restored.to_table()["AA"]["jawOpen"], 0.85))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(resource_path))
	viseme_map.reset_to_default()
	_check("reset fills ten editable poses", viseme_map.poses.size() == 10)
	_check("reset preserves tuned weights", viseme_map.to_table()["AA"]["jawOpen"] == 0.85)

	var rest_only_map = map_script.new()
	var rest_pose = pose_script.new()
	rest_pose.pose = "rest"
	rest_only_map.poses.append(rest_pose)
	var rest_only_table: Dictionary = rest_only_map.to_table()
	_check("authored rest-only map does not fall back", rest_only_table.size() == 1 and rest_only_table.has("rest"))
	var rest_only_driver = driver_script.new(rest_only_table)
	rest_only_driver.advance_from_magnitudes(SPEECH, 1.0 / 60.0)
	_check("rest-only map owns no built-in morphs", rest_only_driver.keys.is_empty() and rest_only_driver.get_current().is_empty())


func _bands_at(index: int) -> PackedFloat32Array:
	var bands := PackedFloat32Array()
	bands.resize(24)
	for neighbor in range(maxi(0, index - 1), mini(23, index + 1) + 1):
		bands[neighbor] = 0.02
	return bands


func _check(label: String, condition: bool) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr("FAIL: %s" % label)
