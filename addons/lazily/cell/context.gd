## The owning context. Every cell is created through one, explicitly.
##
## There is no ambient / current context and no global registry: the ctx is
## threaded through call sites by hand. That is deliberate and matches all nine
## sibling bindings, where ambient context has been removed.
class_name LazilyContext
extends RefCounted

var _batch_depth := 0
## Effects and eager computeds awaiting a flush, in scheduling order.
var _pending: Array[LazilyCell] = []
var _pending_ids: Dictionary[int, bool] = {}


func source(value: Variant = null) -> LazilySource:
	return LazilySource.new(self, value)


func computed(fn: Callable) -> LazilyComputed:
	return LazilyComputed.new(self, fn)


func scope() -> LazilyScope:
	return LazilyScope.new(self)


## Effects are created on a scope, never on the context.
##
## This is not a stylistic preference. Back-edges in this binding are weak, so an
## Effect whose only inbound reference is a back-edge is collectable the moment
## the caller drops it — it would not error, it would just quietly stop running.
## The scope is what makes ownership explicit, so there is no unowned form.
func effect(_fn: Callable) -> LazilyEffect:
	push_error(
		"lazily: an Effect must be created on a scope — use `ctx.scope().effect(fn)`. "
		+ "Back-edges are weak here, so an unowned Effect would be collected rather than run."
	)
	return null


## Untracked read of any cell, for callers outside a compute.
func peek(cell: LazilyCell) -> Variant:
	if cell == null:
		push_error("lazily: peek of a null cell")
		return null
	if not cell._assert_live("peek"):
		return null
	var compute := LazilyCompute.new(cell, self)
	return cell._read(compute)


## Run `fn`, deferring every effect and eager recompute until it returns.
##
## Nested batches collapse into the outermost one: the flush happens once, when
## the last batch exits.
func batch(fn: Callable) -> Variant:
	_batch_depth += 1
	var result: Variant = null
	# The depth must come back down even if the body errors out, or one bad batch
	# wedges every later write into never flushing.
	result = fn.call()
	_batch_depth -= 1
	if _batch_depth == 0:
		_flush()
	return result


func is_batching() -> bool:
	return _batch_depth > 0


func _schedule(node: LazilyCell) -> void:
	if node.is_disposed():
		return
	var id := node.get_instance_id()
	if _pending_ids.has(id):
		return
	_pending_ids[id] = true
	_pending.append(node)


func _flush_if_not_batching() -> void:
	if _batch_depth == 0:
		_flush()


## Drain the pending queue.
##
## Draining re-entrantly rather than iterating a snapshot: an effect body may
## write, which schedules more work, and that work belongs to this same flush.
func _flush() -> void:
	var guard := 0
	while not _pending.is_empty():
		guard += 1
		if guard > 100000:
			push_error("lazily: flush did not settle — a cycle is writing to its own dependency")
			_pending.clear()
			_pending_ids.clear()
			return
		var node: LazilyCell = _pending.pop_front()
		_pending_ids.erase(node.get_instance_id())
		if node.is_disposed():
			continue
		if node is LazilyEffect:
			(node as LazilyEffect).run()
		elif node is LazilyComputed:
			(node as LazilyComputed)._recompute()
