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
class_name LazilyEffect
extends LazilyCell

var _ctx: LazilyContext
var _fn: Callable
var _deps: Array[LazilyCell] = []


func _init(ctx: LazilyContext, fn: Callable) -> void:
	_ctx = ctx
	_fn = fn


## Effects have no value. Reading one is a caller error, not a null.
func _read(_compute: LazilyCompute) -> Variant:
	push_error("lazily: an Effect is a sink and has no value to read")
	return null


func _on_dependency_invalidated() -> void:
	_ctx._schedule(self)


## Run the body, rebuilding dependency edges from what it actually reads.
func run() -> void:
	if _disposed:
		return
	_detach()
	var compute := LazilyCompute.new(self, _ctx)
	_fn.call(compute)
	_deps = compute._deps


func _detach() -> void:
	for dep: LazilyCell in _deps:
		dep._remove_dependent(self)
	_deps.clear()
