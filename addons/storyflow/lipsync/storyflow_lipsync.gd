class_name StoryFlowLipsync
extends Node

const AnalyzerScript = preload("res://addons/storyflow/lipsync/storyflow_lipsync_analyzer.gd")
const DriverScript = preload("res://addons/storyflow/lipsync/storyflow_lipsync_driver.gd")
const StoryFlowComponent = preload("res://addons/storyflow/core/storyflow_component.gd")
const StoryFlowVisemeMap = preload("res://addons/storyflow/lipsync/storyflow_viseme_map.gd")
const TableScript = preload("res://addons/storyflow/lipsync/storyflow_viseme_table.gd")

@export_group("Who is speaking")
## Dialogue component to listen to. Empty searches the scene and keeps retrying.
@export var source: StoryFlowComponent
## Empty moves this face on every speaker's line.
@export var character_id: String = ""
@export_group("The face")
## Empty uses this node's parent as the face root.
@export_node_path("Node") var face_root: NodePath
## Optional per-rig pose and blendshape mapping. Empty uses the ARKit table.
@export var viseme_map: StoryFlowVisemeMap
@export_group("Feel")
@export_range(0.0, 1.0) var strength := 0.5
@export_range(0.1, 3.0) var sensitivity := 1.0
@export_range(0.0, 2.0) var jaw_bias := 1.12
@export_range(1.0, 40.0) var smoothing := 40.0
## Move the mouth on text-only lines; voiced lines without analysis stay closed.
@export var idle_mouth_without_audio := true
## Tuned component reference (Unity/Unreal default), not a raw FFT physical maximum.
@export_range(0.001, 100.0) var analysis_full_scale := 32.0
## Turning this off releases audio and closes owned blendshapes immediately.
@export var enabled := true:
	set(value):
		if enabled == value:
			return
		enabled = value
		if is_inside_tree():
			if enabled:
				_start()
			else:
				_shutdown()
@export_group("Advanced Audio")
## Empty isolates the player's bus automatically. Set an existing bus when Area2D/3D
## audio_bus_override or custom routing bypasses that route. Analysis then hears
## every sound on the chosen bus, so give dialogue its own bus.
@export var analysis_bus: StringName = &"":
	set(value):
		if analysis_bus == value:
			return
		analysis_bus = value
		_release_analyzer()
		_analysis_failed_player = null

const RECHECK_SECONDS := 1.0
const REST_WEIGHT := 0.0001

var _driver: RefCounted
var _running := false
var _bound_source: Node
var _configured_source: StoryFlowComponent
var _speaking: Node
var _line_stream: AudioStream
var _line_is_mine := false
var _line_has_audio := false
var _manual := false
var _awaiting_player := false
var _audio_search_time := 0.0
var _line_node_id := ""
var _line_entry_serial := -1
var _playback_serial := -1
var _analyzer: RefCounted
var _analysis_failed_player: Node
var _analysis_failed_serial := -1
var _targets: Array[Dictionary] = []
var _at_rest := false
var _face_check_time := 0.0
var _source_check_time := 0.0
var _last_usec := 0
var _warned_no_source := false
var _warned_no_face := false
var _warned_missing_morphs := false
var _warned_unknown_character := false
var _warned_no_audio := false
var _diagnosed_character_id := ""


func _enter_tree() -> void:
	# _ready runs only once; a pooled actor reentering the tree needs to listen again.
	if _driver:
		call_deferred("_restart_after_reentry")


func _ready() -> void:
	process_priority = 1000
	if enabled:
		_start()


func _exit_tree() -> void:
	_shutdown()


func _start() -> void:
	if _running:
		return
	_running = true
	var table: Dictionary = viseme_map.to_table() if viseme_map else TableScript.default_table()
	_driver = DriverScript.new(table, get_instance_id())
	_last_usec = Time.get_ticks_usec()
	_at_rest = false
	_resolve_face()
	_bind_source()
	set_process(true)


func _shutdown() -> void:
	_running = false
	set_process(false)
	_unbind_source()
	stop_lipsync()
	if _driver:
		_driver.advance_silent(10.0)
	_zero_owned_shapes()
	_at_rest = true


func _restart_after_reentry() -> void:
	if is_inside_tree() and enabled:
		_start()


func _process(_delta: float) -> void:
	if not enabled or not _driver:
		return
	var now := Time.get_ticks_usec()
	var dt := clampf(float(now - _last_usec) / 1000000.0, 0.0, 0.25)
	_last_usec = now
	_driver.strength = strength
	_driver.sensitivity = sensitivity
	_driver.jaw_bias = jaw_bias
	_driver.smoothing = smoothing
	_driver.full_scale = maxf(analysis_full_scale, 0.001)
	if source != _configured_source or (_bound_source != null and (not is_instance_valid(_bound_source) or not _bound_source.is_inside_tree())):
		_bind_source()
	elif not _bound_source:
		_source_check_time += dt
		if _source_check_time >= RECHECK_SECONDS:
			_source_check_time = 0.0
			_bind_source()
			if not _bound_source and not _warned_no_source:
				_warned_no_source = true
				push_warning("StoryFlow Editor lipsync on '%s' found no dialogue component; it will keep looking." % name)
	_refresh_face(dt)
	_retry_player(dt)
	var silent := false
	if _is_playing_line_audio():
		if _ensure_analyzer():
			_driver.advance_from_magnitudes(_analyzer.read_magnitudes(), dt)
		else:
			_driver.advance_silent(dt)
			silent = true
	elif _line_is_mine and not _line_has_audio and idle_mouth_without_audio:
		_release_analyzer()
		_driver.advance_idle(dt)
	else:
		# A paused player keeps its analyser lease, but closes the mouth.
		if _speaking and (not is_instance_valid(_speaking) or not _speaking.stream_paused):
			_release_analyzer()
		_driver.advance_silent(dt)
		silent = true
		if _speaking and not _line_is_mine and not _manual:
			_release_player()
	# AnimationPlayer and AnimationTree may also write the face during process.
	# Defer the morph write until their process callbacks have finished this frame.
	call_deferred("_apply", silent)


func start_lipsync_for(player: Node) -> void:
	_release_player()
	_manual = _is_audio_player(player)
	_line_is_mine = false
	_line_has_audio = false
	_awaiting_player = false
	_line_node_id = ""
	_speaking = player if _manual else null
	if _driver:
		_driver.reset_level()


func stop_lipsync() -> void:
	_manual = false
	_line_is_mine = false
	_line_has_audio = false
	_awaiting_player = false
	_line_node_id = ""
	_release_player()


func is_lipsync_active() -> bool:
	return _manual or _line_is_mine or _is_playing_line_audio()


func get_level() -> float:
	return _driver.get_level() if _driver else 0.0


func get_centroid() -> float:
	return _driver.get_centroid() if _driver else 0.0


func get_raw_peak() -> float:
	return _driver.get_raw_peak() if _driver else 0.0


func _bind_source() -> void:
	_configured_source = source
	var next: Node = source if is_instance_valid(source) and source.is_inside_tree() else null
	if next == null and source == null:
		for candidate in get_tree().get_nodes_in_group("storyflow_components"):
			if is_instance_valid(candidate):
				next = candidate
				break
	if next == _bound_source:
		return
	_unbind_source()
	if not _manual:
		stop_lipsync()
	_bound_source = next
	if not _bound_source:
		return
	_warned_no_source = false
	_bound_source.dialogue_updated.connect(_on_dialogue_updated)
	_bound_source.dialogue_restored.connect(_on_dialogue_restored)
	_bound_source.dialogue_ended.connect(_on_dialogue_ended)
	if _bound_source.is_dialogue_active():
		var state = _bound_source.get_current_dialogue()
		if state:
			_on_dialogue_updated(state)


func _unbind_source() -> void:
	if is_instance_valid(_bound_source):
		if _bound_source.dialogue_updated.is_connected(_on_dialogue_updated):
			_bound_source.dialogue_updated.disconnect(_on_dialogue_updated)
		if _bound_source.dialogue_restored.is_connected(_on_dialogue_restored):
			_bound_source.dialogue_restored.disconnect(_on_dialogue_restored)
		if _bound_source.dialogue_ended.is_connected(_on_dialogue_ended):
			_bound_source.dialogue_ended.disconnect(_on_dialogue_ended)
	_bound_source = null


func _on_dialogue_updated(state) -> void:
	if not enabled or not state:
		return
	if state.is_restored:
		_on_dialogue_restored(state)
		return
	if not _speaker_is_mine():
		if not _manual:
			stop_lipsync()
		return
	var entry_serial: int = _bound_source.get_dialogue_entry_serial()
	if _line_is_mine and state.node_id == _line_node_id and entry_serial == _line_entry_serial:
		return
	_line_node_id = state.node_id
	_line_entry_serial = entry_serial
	_line_is_mine = true
	_manual = false
	_line_has_audio = state.audio != null
	_awaiting_player = false
	if _line_has_audio:
		_release_player()
		_line_stream = state.audio
		_try_acquire_player()
		_awaiting_player = _speaking == null
		_audio_search_time = 0.0
		if _driver:
			_driver.reset_level()
	elif not _is_playing_line_audio():
		_release_player()


func _on_dialogue_restored(state) -> void:
	# Back fully reveals the entry. Catch-up and redraw must leave it at rest too.
	if not enabled or _manual:
		return
	# An earlier listener can replace the session before this signal reaches us.
	if not is_instance_valid(_bound_source) or not state or not state.is_restored or _bound_source.get_current_dialogue() != state:
		return
	stop_lipsync()
	if _driver:
		_driver.advance_silent(10.0)
	_zero_owned_shapes()
	_at_rest = true


func _on_dialogue_ended() -> void:
	if _manual:
		return
	if not _is_playing_line_audio():
		stop_lipsync()
		return
	_line_is_mine = false
	_line_has_audio = false
	_awaiting_player = false
	_line_node_id = ""


func _speaker_is_mine() -> bool:
	if character_id.is_empty():
		return true
	if not is_instance_valid(_bound_source):
		return false
	if character_id != _diagnosed_character_id:
		_diagnosed_character_id = character_id
		_warned_unknown_character = false
	var mine: String = _bound_source.get_character_path_by_id(character_id)
	if mine.is_empty() and not _warned_unknown_character:
		_warned_unknown_character = true
		push_warning("StoryFlow Editor lipsync on '%s' has no character id '%s'." % [name, character_id])
	var current: String = _bound_source.get_current_speaker_path()
	return not mine.is_empty() and not current.is_empty() and _normalize_path(mine) == _normalize_path(current)


func _normalize_path(path: String) -> String:
	return path.replace("\\", "/").to_lower().trim_prefix("res://")


func _try_acquire_player() -> void:
	if not is_instance_valid(_bound_source):
		return
	var player: Node = _bound_source.get_current_dialogue_audio_player()
	if not _is_audio_player(player) or player.stream != _line_stream:
		return
	if not player.playing and not player.stream_paused:
		return
	_speaking = player
	_playback_serial = _bound_source.get_dialogue_audio_playback_serial()


func _retry_player(dt: float) -> void:
	if not _awaiting_player:
		return
	_audio_search_time += dt
	if _audio_search_time >= RECHECK_SECONDS:
		_awaiting_player = false
		if not _warned_no_audio:
			_warned_no_audio = true
			push_warning("StoryFlow Editor lipsync on '%s' could not find audio playing this line; use start_lipsync_for for custom playback." % name)
		return
	_try_acquire_player()
	if _speaking:
		_awaiting_player = false
		_warned_no_audio = false
		if _driver:
			_driver.reset_level()


func _is_audio_player(player: Node) -> bool:
	return player is AudioStreamPlayer or player is AudioStreamPlayer2D or player is AudioStreamPlayer3D


func _is_playing_line_audio() -> bool:
	if not is_instance_valid(_speaking) or not _is_audio_player(_speaking):
		return false
	if not _speaking.playing or _speaking.stream_paused:
		return false
	if _manual:
		return true
	if _speaking.stream != _line_stream:
		return false
	if not is_instance_valid(_bound_source):
		return false
	return _bound_source.get_dialogue_audio_playback_serial() == _playback_serial


func _ensure_analyzer() -> bool:
	if _analyzer:
		return _analyzer.is_available()
	if _analysis_failed_player == _speaking and _analysis_failed_serial == _playback_serial:
		return false
	_analyzer = AnalyzerScript.acquire(_speaking, analysis_bus)
	if _analyzer == null or not _analyzer.is_available():
		_release_analyzer()
		_analysis_failed_player = _speaking
		_analysis_failed_serial = _playback_serial
		return false
	return true


func _release_analyzer() -> void:
	if _analyzer:
		_analyzer.release()
		_analyzer = null


func _release_player() -> void:
	_release_analyzer()
	_speaking = null
	_line_stream = null
	_playback_serial = -1
	_analysis_failed_player = null
	_analysis_failed_serial = -1


func _face_root_node() -> Node:
	if not face_root.is_empty():
		return get_node_or_null(face_root)
	return get_parent()


func _refresh_face(dt: float) -> void:
	var stale := false
	for target in _targets:
		if not _target_is_live(target):
			stale = true
			break
	_face_check_time += dt
	if stale or _face_check_time >= RECHECK_SECONDS:
		_face_check_time = 0.0
		_resolve_face(true)


func _resolve_face(warn_if_missing: bool = false) -> void:
	var next: Array[Dictionary] = []
	var root_node := _face_root_node()
	if root_node and _driver:
		_collect_face_targets(root_node, next)
	if not _at_rest:
		for old in _targets:
			var retained := false
			for current in next:
				if current.node == old.node and current.mesh == old.mesh:
					retained = true
					break
			if not retained:
				_zero_target(old)
	_targets = next
	if _targets.is_empty():
		if warn_if_missing and not _warned_no_face:
			_warned_no_face = true
			push_warning("StoryFlow Editor lipsync on '%s' found no blendshapes under its face root; it will keep looking." % name)
	else:
		_warned_no_face = false
		var missing: Dictionary = {}
		for key in _driver.get_current():
			missing[key] = true
		for target in _targets:
			for key in target.indices:
				missing.erase(key)
		if missing.is_empty():
			_warned_missing_morphs = false
		elif not _warned_missing_morphs:
			_warned_missing_morphs = true
			push_warning("StoryFlow Editor lipsync on '%s' found no blendshape for %s; available pose parts still play." % [name, ", ".join(missing.keys())])


func _collect_face_targets(node: Node, out: Array[Dictionary]) -> void:
	if node is MeshInstance3D and node.mesh and node.mesh.get_blend_shape_count() > 0:
		var indices := {}
		var weights: Dictionary = _driver.get_current()
		var prefer_prefix: bool = viseme_map == null or viseme_map.name_style == 1
		for key in weights:
			var index := _resolve_morph(node.mesh, str(key), prefer_prefix)
			if index >= 0:
				indices[key] = index
		if not indices.is_empty():
			out.append({"node": node, "mesh": node.mesh, "indices": indices})
	for child in node.get_children():
		_collect_face_targets(child, out)


func _resolve_morph(mesh: Mesh, morph: String, prefer_prefix: bool) -> int:
	for i in mesh.get_blend_shape_count():
		if mesh.get_blend_shape_name(i) == morph:
			return i
	if prefer_prefix:
		for i in mesh.get_blend_shape_count():
			if mesh.get_blend_shape_name(i) == "MESHBlends." + morph:
				return i
	for i in mesh.get_blend_shape_count():
		var name := String(mesh.get_blend_shape_name(i))
		if name.get_slice(".", name.count(".")) == morph:
			return i
	return -1


func _target_is_live(target: Dictionary) -> bool:
	return is_instance_valid(target.node) and target.node.is_inside_tree() and target.node.mesh == target.mesh


func _apply(silent: bool) -> void:
	if not enabled or not _driver:
		return
	var weights: Dictionary = _driver.get_current()
	if silent and _mouth_is_shut(weights):
		if _at_rest:
			return
		_at_rest = true
		_zero_owned_shapes()
		return
	_at_rest = false
	for target in _targets:
		if not _target_is_live(target):
			continue
		for key in target.indices:
			target.node.set_blend_shape_value(target.indices[key], weights[key])


func _mouth_is_shut(weights: Dictionary) -> bool:
	for value in weights.values():
		if value >= REST_WEIGHT:
			return false
	return true


func _zero_owned_shapes() -> void:
	for target in _targets:
		_zero_target(target)


func _zero_target(target: Dictionary) -> void:
	if not _target_is_live(target):
		return
	for index in target.indices.values():
		target.node.set_blend_shape_value(index, 0.0)
