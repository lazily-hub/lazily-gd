## A sink. Runs its body when a dependency changes.
##
## **There are no observers in lazily — only Effects.** Do not add a subscribe /
## listener / callback-registry API to any reactive type here. An observer
## registry is a second, untracked edge set that survives invalidation, which is
## exactly what the edge index is supposed to make impossible.
##
## An Effect is created through a `LazilyScope` and nowhere else. Its only strong
## owner is that scope: back-edges are weak, so an Effect the caller drops would
## otherwise be collected mid-graph and silently stop running.
##
## The body MAY return a cleanup `Callable`; returning nothing (`null`) means no
## cleanup. Each run decides afresh: the cleanup the most recent run returned is
## called once before the next run and once on dispose, and a run that returns
## none leaves nothing outstanding. (`effect_cleanup_is_optional.json`)
class_name LazilyEffect
extends LazilyCell

var _fn: Callable
var _deps: Array[LazilyCell] = []
## The cleanup the most recent run returned, or an empty `Callable` for none.
var _cleanup := Callable()


func _init(ctx: LazilyContext, fn: Callable) -> void:
	_ctx = ctx
	_fn = fn


## Effects have no value. Reading one is a caller error, not a null.
func _read(_compute: LazilyCompute) -> Variant:
	push_error("lazily: an Effect is a sink and has no value to read")
	return null


func _on_dependency_invalidated(reactive: bool = true) -> void:
	# A disposed dependency is not a new value. A surviving effect has nothing
	# new to observe, so it must not fire.
	if not reactive:
		return
	_ctx._schedule(self)


## Run the body, rebuilding dependency edges from what it actually reads.
func run() -> void:
	if _disposed:
		return
	_detach()
	_run_cleanup()
	var compute := LazilyCompute.new(self, _ctx)
	var returned: Variant = _fn.call(compute)
	_deps = compute._deps
	if returned is Callable and (returned as Callable).is_valid():
		_cleanup = returned


func dispose() -> void:
	if _disposed:
		return
	super()
	_run_cleanup()


## Call the outstanding cleanup at most once: the slot is cleared BEFORE the
## call, so a run that returns none cannot leave a stale cleanup to re-invoke.
func _run_cleanup() -> void:
	var c := _cleanup
	_cleanup = Callable()
	if c.is_valid():
		c.call()


func _detach() -> void:
	for dep: LazilyCell in _deps:
		dep._remove_dependent(self)
	_deps.clear()
