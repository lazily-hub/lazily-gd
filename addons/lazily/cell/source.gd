## A single-writer source cell: the graph's only write entry point.
class_name LazilySource
extends LazilyCell

var _value: Variant
var _policy: LazilyMergePolicy


func _init(
	ctx: LazilyContext, value: Variant = null, policy: LazilyMergePolicy = null
) -> void:
	_ctx = ctx
	_value = value
	_policy = policy if policy != null else LazilyMergePolicy.keep_latest()


## The fold this cell's [method merge] writes under.
func policy() -> LazilyMergePolicy:
	return _policy


## Fold `op` into the current value under this cell's policy and write the
## result.
##
## This is the accumulate path — one fold per call, because the CALLER decides
## how many ops exist. Delivery through a dependency edge is flush-granular
## instead (one fold per settled cone), and keeping the two distinct is the
## whole subject of `exact_fold_paths_stay_exact.json`: unifying them lands on
## the wrong count in one direction or the other.
##
## Routed through [method set_value], so the equality guard applies here too: a
## fold landing on the value already held invalidates nothing.
func merge(op: Variant) -> void:
	if not _assert_live("merge"):
		return
	set_value(_policy.merge(_value, op))


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
