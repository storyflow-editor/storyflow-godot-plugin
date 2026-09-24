class_name StoryFlowLipsyncDriver
extends RefCounted

const VisemeTable = preload("res://addons/storyflow/lipsync/storyflow_viseme_table.gd")
const MIN_HZ := 90.0
const MAX_HZ := 4200.0
const CENTROID_SCALE := 2.6
const PEAK_DECAY := 0.9992
const PEAK_FLOOR := 0.04
const PEAK_INITIAL := 0.12
const SPECTRAL_KEEP := 0.55
const GATE_START := 0.10
const GATE_RANGE := 0.22
const CLOSING_BREATH := 0.45

var strength: float = 0.55
var sensitivity: float = 1.0
var jaw_bias: float = 1.0
var smoothing: float = 16.0
# Raw magnitude produced by a full-scale sine in the supplying analyzer (0 dB).
var full_scale: float = 1.0
# Only morphs named by the active table are ever written; identity shapes stay untouched.
var keys: Array[String] = []

var _table: Dictionary
var _slots: Dictionary = {}
var _weights := PackedFloat32Array()
var _target := PackedFloat32Array()
var _smoothed := PackedFloat32Array()
var _current: Dictionary = {}
var _mouth_close_slot: int = -1
var _peak: float = PEAK_INITIAL
var _level: float = 0.0
var _centroid: float = 0.0
var _raw_peak: float = 0.0
var _random := RandomNumberGenerator.new()
var _idle_pool: Array[String] = []
var _idle_has_mm := false
var _idle_pose := "rest"
var _idle_hold := 0.0


func _init(table: Dictionary = {}, random_seed: int = 0) -> void:
	_table = table if not table.is_empty() else VisemeTable.default_table()
	keys = VisemeTable.owned_morphs(_table)
	_weights.resize(keys.size())
	_target.resize(keys.size())
	for index in range(keys.size()):
		_slots[keys[index]] = index
		_current[keys[index]] = 0.0
		if keys[index] == "mouthClose":
			_mouth_close_slot = index
	for pose_name in _table:
		if pose_name != "rest":
			_idle_pool.append(pose_name)
	_idle_pool.sort()
	_idle_has_mm = _table.has("MM")
	if random_seed == 0:
		_random.randomize()
	else:
		_random.seed = random_seed


# Magnitudes are linear FFT values, evenly spaced from 90 to 4200 Hz. Each bin is
# mapped to Web Audio's -100..-30 dB reference window before spectral smoothing.
func advance_from_magnitudes(magnitudes: PackedFloat32Array, dt: float) -> void:
	if magnitudes.size() < 2:
		advance_silent(dt)
		return
	if _smoothed.size() != magnitudes.size():
		_smoothed.resize(magnitudes.size())
		_smoothed.fill(0.0)
	var divisor := maxf(full_scale, 1e-9) if not is_nan(full_scale) else 1e-9
	var keep := pow(SPECTRAL_KEEP, dt * 60.0) if dt > 0.0 else 1.0
	var sum := 0.0
	var weighted := 0.0
	for index in range(magnitudes.size()):
		var magnitude := magnitudes[index]
		if is_nan(magnitude) or is_inf(magnitude) or magnitude < 0.0:
			magnitude = 0.0
		_raw_peak = maxf(_raw_peak, magnitude)
		var decibels := 20.0 * log(maxf(magnitude, 1e-9) / divisor) / log(10.0)
		var referenced := _clamp01((decibels + 100.0) / 70.0)
		var smoothed: float = keep * _smoothed[index] + (1.0 - keep) * referenced
		_smoothed[index] = smoothed
		sum += smoothed
		weighted += smoothed * index
	var energy := sum / magnitudes.size()
	_centroid = _clamp01((weighted / sum) / (magnitudes.size() - 1) * CENTROID_SCALE) if sum > 0.0 else 0.0
	_peak = maxf(energy, _peak * pow(PEAK_DECAY, maxf(0.0, dt) * 60.0))
	var normalized := energy / maxf(PEAK_FLOOR, _peak)
	_level = minf(1.0, normalized)
	var gate := _clamp01((normalized - GATE_START) / GATE_RANGE)
	var amplitude := minf(1.0, normalized * 1.15 * sensitivity) * gate
	_build_axis_pose(_centroid, amplitude, gate)
	_ease(dt)


func advance_idle(dt: float) -> void:
	_level = 0.0
	_centroid = 0.0
	_idle_hold -= dt
	if _idle_hold <= 0.0:
		if _idle_pool.is_empty() or _random.randf() < 0.20:
			_idle_pose = "MM" if _idle_has_mm and _random.randf() < 0.5 else "rest"
			_idle_hold = 0.14 + _random.randf() * 0.22
		else:
			_idle_pose = _idle_pool[_random.randi_range(0, _idle_pool.size() - 1)]
			_idle_hold = 0.12 + _random.randf() * 0.13
	_clear_target()
	if _table.has(_idle_pose):
		var pose: Dictionary = _table[_idle_pose]
		for morph_name in pose:
			var slot: int = _slots.get(morph_name, -1)
			if slot >= 0:
				_target[slot] = pose[morph_name] * strength * (jaw_bias if morph_name == "jawOpen" else 1.0)
	_ease(dt)


func advance_silent(dt: float) -> void:
	_level = 0.0
	_centroid = 0.0
	_clear_target()
	_ease(dt)


func reset_level() -> void:
	_peak = PEAK_INITIAL
	_level = 0.0
	_raw_peak = 0.0
	_smoothed.fill(0.0)


func get_current() -> Dictionary:
	for index in range(keys.size()):
		_current[keys[index]] = _weights[index]
	return _current


func get_weight(index: int) -> float:
	return _weights[index] if index >= 0 and index < _weights.size() else 0.0


func get_level() -> float:
	return _level


func get_centroid() -> float:
	return _centroid


func get_raw_peak() -> float:
	return _raw_peak


func _build_axis_pose(centroid: float, amplitude: float, gate: float) -> void:
	_clear_target()
	var position := centroid * (VisemeTable.AXIS.size() - 1)
	var low := clampi(floori(position), 0, VisemeTable.AXIS.size() - 1)
	var high := mini(VisemeTable.AXIS.size() - 1, low + 1)
	var alpha := position - low
	_accumulate_blend(_table.get(VisemeTable.AXIS[low], {}), 1.0 - alpha, amplitude)
	_accumulate_blend(_table.get(VisemeTable.AXIS[high], {}), alpha, amplitude)
	if gate < 1.0 and _mouth_close_slot >= 0:
		_target[_mouth_close_slot] += (1.0 - gate) * CLOSING_BREATH * strength


func _accumulate_blend(pose: Dictionary, share: float, amplitude: float) -> void:
	if share <= 0.0:
		return
	for morph_name in pose:
		var slot: int = _slots.get(morph_name, -1)
		if slot >= 0:
			_target[slot] += pose[morph_name] * share * amplitude * strength * (jaw_bias if morph_name == "jawOpen" else 1.0)


func _clear_target() -> void:
	_target.fill(0.0)


func _ease(dt: float) -> void:
	var blend := 1.0 - exp(-smoothing * dt) if dt > 0.0 else 0.0
	for index in range(_weights.size()):
		_weights[index] = _clamp01(_weights[index] + (_target[index] - _weights[index]) * blend)


static func _clamp01(value: float) -> float:
	if not value > 0.0:
		return 0.0
	return minf(1.0, value)
