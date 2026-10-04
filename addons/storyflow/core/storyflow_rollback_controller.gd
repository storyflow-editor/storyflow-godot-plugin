extends RefCounted

const Snapshot = preload("res://addons/storyflow/core/storyflow_execution_snapshot.gd")
var component: WeakRef
var manager: WeakRef
var revision: int
var history_limit: int
var history: Array = []
var retained_bytes: int = 0
var rng_state: int = 1
var busy: bool = false
var active: bool = true
var terminal: bool = false
var reason: String = "empty"
var skip_serial: int = -1
var last_serial: int = -1
var generation: int = 0
var _published: Dictionary = {}
var diagnostics := {"captureUsec": 0, "restoreUsec": 0, "entries": 0, "bytes": 0, "failure": ""}

func initialize(owner: Node, scope: Node, limit: int) -> void:
	component = weakref(owner)
	manager = weakref(scope)
	revision = scope._rollback_content_revision
	history_limit = limit
	rng_state = maxi(1, (Time.get_ticks_usec() ^ owner.get_instance_id()) & 0xffffffff)

func next_uint() -> int:
	var x := rng_state if rng_state != 0 else 1
	x = (x ^ ((x << 13) & 0xffffffff)) & 0xffffffff
	x = (x ^ (x >> 17)) & 0xffffffff
	x = (x ^ ((x << 5) & 0xffffffff)) & 0xffffffff
	rng_state = x
	return x

func random_int(minimum: int, maximum: int) -> int:
	return minimum + next_uint() % (maximum - minimum + 1)

func random_float(minimum: float, maximum: float) -> float:
	return minimum + (float(next_uint()) / 4294967296.0) * (maximum - minimum)

func availability() -> Dictionary:
	var owner = component.get_ref()
	var scope = manager.get_ref()
	var why := reason
	if busy or (owner and owner._rollback_depth > 0):
		why = "busy"
	elif not active:
		why = "empty"
	elif not terminal and scope and scope._active_dialogue_count > 1:
		why = "multipleSessions"
	var steps := maxi(0, history.size() - 1)
	var can := active and why in ["", "empty"] and steps > 0
	return {"canGoBack": can, "steps": steps if can else 0, "reason": null if can else (why if why != "" else "empty")}

func publish() -> void:
	var current := availability()
	if current == _published:
		return
	_published = current.duplicate()
	var owner = component.get_ref()
	if owner and owner._rollback == self:
		owner._publish_rollback_availability()

func invalidate(why: String, permanent: bool = false, notify: bool = true) -> void:
	generation += 1
	history.clear()
	retained_bytes = 0
	if not terminal or permanent:
		reason = why
	terminal = terminal or permanent
	var owner = component.get_ref()
	if owner:
		skip_serial = owner.get_dialogue_entry_serial()
	diagnostics.entries = 0
	diagnostics.bytes = 0
	if notify:
		publish()

func capture() -> void:
	var owner = component.get_ref()
	var scope = manager.get_ref()
	if not active or terminal or busy or not owner or not scope or scope._rollback_mutation_depth > 0 or scope._active_dialogue_count != 1:
		return
	if owner._rollback_depth > 0 or owner._is_processing_chain or not owner._context.is_executing or not owner._context.is_waiting_for_input:
		return
	var serial: int = owner.get_dialogue_entry_serial()
	if serial == last_serial or serial == skip_serial:
		return
	var started := Time.get_ticks_usec()
	var cloner := Snapshot.new()
	var data = cloner.copy(owner._rollback_capture_state())
	diagnostics.captureUsec = Time.get_ticks_usec() - started
	if not cloner.failure.is_empty():
		diagnostics.failure = cloner.failure
		invalidate(cloner.failure)
		return
	history.append({"state": data, "bytes": cloner.bytes})
	retained_bytes += cloner.bytes
	while history.size() > history_limit + 1 or retained_bytes > Snapshot.MAX_BYTES:
		retained_bytes -= history.pop_front().bytes
	last_serial = serial
	reason = ""
	diagnostics.entries = history.size()
	diagnostics.bytes = retained_bytes
	publish()

func go_back() -> Dictionary:
	var available := availability()
	if not available.canGoBack:
		return {"ok": false, "reason": available.reason}
	var owner = component.get_ref()
	var scope = manager.get_ref()
	if not owner or not scope or revision != scope._rollback_content_revision:
		invalidate("contentChanged", true)
		return {"ok": false, "reason": "contentChanged"}
	busy = true
	var epoch := generation
	var started := Time.get_ticks_usec()
	# Preparation runs without publication, mutations or evaluator calls. Both copies are
	# ready before touching live state; recovery is the immediate pre-Back state.
	var target_clone := Snapshot.new()
	var target = target_clone.copy(history[history.size() - 2].state)
	var recovery_clone := Snapshot.new()
	var recovery = recovery_clone.copy(owner._rollback_capture_state())
	var prepared: Dictionary = {}
	var prepared_recovery: Dictionary = {}
	if target_clone.failure.is_empty() and recovery_clone.failure.is_empty():
		prepared = owner._rollback_prepare_state(target, false)
		prepared_recovery = owner._rollback_prepare_state(recovery, true)
	if prepared.is_empty() or prepared_recovery.is_empty():
		busy = false
		diagnostics.failure = "restoreFailed"
		invalidate("restoreFailed")
		return {"ok": false, "reason": "restoreFailed"}
	var committed: bool = owner._rollback_commit_state(prepared, false)
	if not committed:
		var recovered: bool = owner._rollback_commit_state(prepared_recovery, true)
		busy = false
		invalidate("restoreFailed")
		if not recovered and active and owner._rollback == self:
			owner.stop_dialogue()
		return {"ok": false, "reason": "restoreFailed"}
	if not active or generation != epoch or owner._rollback != self:
		busy = false
		return {"ok": false, "reason": "restoreFailed"}
	retained_bytes -= history.pop_back().bytes
	owner._dialogue_entry_serial += 1
	owner._restored_dialogue_serial = owner._dialogue_entry_serial
	last_serial = owner._dialogue_entry_serial
	diagnostics.restoreUsec = Time.get_ticks_usec() - started
	diagnostics.entries = history.size()
	diagnostics.bytes = retained_bytes
	# Keep the busy gate during callbacks. A listener may replace this entire session.
	owner.dialogue_restored.emit(owner._context.current_dialogue_state)
	busy = false
	if active and owner._rollback == self:
		publish()
	return {"ok": true}
