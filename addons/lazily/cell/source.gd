## A single-writer source cell: the graph's only write entry point.
class_name LazilySource
extends LazilyCell

var _value: Variant
var _ctx: LazilyContext


func _init(ctx: LazilyContext, value: Variant = null) -> void:
	_ctx = ctx
	_value = value


func _read(_compute: LazilyCompute) -> Variant:
	return _value


## Untracked read, for callers outside a compute.
func peek() -> Variant:
	if not _assert_live("peek"):
		return null
	return _value


func set_value(value: Variant) -> void:
	if not _assert_live("set"):
		return
	# Writing the value it already holds is not a write. Without this, churn that
	# returns to its baseline still fans an invalidation across the whole cone
	# and re-runs every effect for no observable change.
	# (`churn_returns_to_baseline.json`)
	if _value == value:
		return
	_value = value
	_invalidate()
	_ctx._flush_if_not_batching()
