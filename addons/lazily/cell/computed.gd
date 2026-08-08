## A derived cell. Always single-writer — its one writer is the derivation graph.
##
## Lazy by default: invalidation marks the cone stale and a read recomputes.
## `eager()` opts into recomputing at flush instead. The two strategies are not
## mixed within one cell: a one-level mark combined with a cache-trusting read is
## precisely how a graph loses writes at depth 2.
class_name LazilyComputed
extends LazilyCell

var _ctx: LazilyContext
var _fn: Callable
var _value: Variant = null
var _stale := true
var _eager := false
## Forward edges, STRONG — this is the direction that keeps dependencies alive.
var _deps: Array[LazilyCell] = []


func _init(ctx: LazilyContext, fn: Callable) -> void:
	_ctx = ctx
	_fn = fn


## Recompute at flush rather than on read. Returns self so it reads as
## `ctx.computed(fn).eager()`.
func eager() -> LazilyComputed:
	_eager = true
	_ctx._schedule(self)
	# Scheduling alone leaves the cell stale until something else happens to
	# flush. Eager means eager: outside a batch this settles now, and inside one
	# it settles with the batch.
	_ctx._flush_if_not_batching()
	return self


func is_eager() -> bool:
	return _eager


func _read(_compute: LazilyCompute) -> Variant:
	if _stale:
		_recompute()
	return _value


## Untracked read, for callers outside a compute.
func peek() -> Variant:
	if not _assert_live("peek"):
		return null
	if _stale:
		_recompute()
	return _value


func _on_dependency_invalidated() -> void:
	if _stale:
		# Already stale, so the cone below was marked when it became stale.
		# Stopping here is what keeps invalidation linear instead of exponential.
		return
	_stale = true
	_invalidate()
	if _eager:
		_ctx._schedule(self)


func _recompute() -> void:
	if _disposed:
		return
	# Edges are rebuilt from scratch every recompute, because a conditional body
	# reads different cells on different runs. Keeping the old edges would leave
	# this cell subscribed to a dependency it no longer reads.
	_detach()
	var compute := LazilyCompute.new(self, _ctx)
	var next: Variant = _fn.call(compute)
	_deps = compute._deps
	# A failed compute must not be cached — the next read has to try again rather
	# than serve a value the body never produced.
	# (`failed_compute_is_never_cached.json`)
	_value = next
	_stale = false


func _detach() -> void:
	for dep: LazilyCell in _deps:
		dep._remove_dependent(self)
	_deps.clear()


func dispose() -> void:
	if _disposed:
		return
	# Reverts to lazy: a disposed computed holds no cached value and no edges.
	# (`dispose_signal_reverts_to_lazy.json`)
	_stale = true
	_value = null
	super()
