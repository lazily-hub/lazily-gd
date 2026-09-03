## Reactive shell over [LazilyLatestDurableProjectionCore].
##
## Godot has no supported lock-backed or async reactive contexts in this binding,
## so this is the only execution flavor. Sink I/O belongs after `claim`; this
## shell contains no timer, transport, callback registry, or implicit retry loop.
class_name LazilyLatestDurableProjection
extends RefCounted

var _core: LazilyLatestDurableProjectionCore
var _state_reader: LazilySource
var _state_version := 0


func _init(ctx: LazilyContext, generation: int) -> void:
	_core = LazilyLatestDurableProjectionCore.new(generation)
	_state_reader = ctx.source(0)


func _publish(change: Dictionary) -> void:
	if not bool(change.get("state", false)):
		return
	_state_version += 1
	_state_reader.set_value(_state_version)


func _finish(transition: Dictionary) -> Dictionary:
	_publish(transition["change"])
	return transition["outcome"]


func upsert_desired(key: Variant, epoch: int, value: Variant) -> Dictionary:
	return _finish(_core.upsert_desired(key, epoch, value))


func claim(key: Variant, generation: int) -> Dictionary:
	return _finish(_core.claim(key, generation))


func ack_applied(key: Variant, generation: int, epoch: int) -> Dictionary:
	return _finish(_core.ack_applied(key, generation, epoch))


func fail_retryable(key: Variant, generation: int, epoch: int) -> Dictionary:
	return _finish(_core.fail_retryable(key, generation, epoch))


func reconnect(generation: int) -> Dictionary:
	return _finish(_core.reconnect(generation))


func generation() -> int:
	return _core.generation()


func count() -> int:
	return _core.count()


func state(key: Variant) -> Variant:
	return _core.state(key)


func snapshot() -> Dictionary:
	return _core.snapshot()


## Aggregate graph dependency, advanced exactly once per true state transition.
func state_reader() -> LazilySource:
	return _state_reader
