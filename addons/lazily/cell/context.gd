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

## How many drain steps one flush may take before it is declared non-settling.
## An effect that writes into its own dependency cone never settles, and the
## contract is that the drain REPORTS exhaustion rather than spinning forever.
var drain_bound := 10000
## Observable, because "it did not settle" is a result a caller must be able to
## read — not merely an error in a log.
## (`feedback_drain_bound_reports_exhaustion.json`)
var _drain_exhausted := false


## Last read failure, or "" if the last read succeeded.
##
## Reads report failure through the context rather than only through
## `push_error`, because a caller cannot observe a log line. A `Computed` whose
## dependency was disposed fails here too, not just the disposed cell itself.
var _read_error := ""
## Re-entrancy guard for the drain. An effect body that writes would otherwise
## start a nested flush, and the nested drain would consume the queue the outer
## loop is counting — so a non-settling graph would spin forever instead of
## reporting exhaustion.
var _flushing := false


func drain_exhausted() -> bool:
	return _drain_exhausted


func _record_read_error(kind: String) -> void:
	_read_error = kind


## Read and clear the pending read error.
func take_read_error() -> String:
	var e := _read_error
	_read_error = ""
	return e


func has_read_error() -> bool:
	return _read_error != ""


func clear_drain_exhausted() -> void:
	_drain_exhausted = false


func source(value: Variant = null) -> LazilySource:
	return LazilySource.new(self, value)


## A source cell whose [method LazilySource.merge] folds under `policy`.
##
## With a policy other than KeepLatest this is what the corpus calls a merge
## cell. It is the SAME class: a merge cell is an ordinary source node, so
## degree, read and dispose all behave unchanged, and the only thing that makes
## it an accumulator is the fold. `merge_cell_acquires_no_dependency_edge.json`
## asserts exactly that — the cell acquires no edge even when fed from a
## reactive, because the edge belongs to the effect doing the feeding.
func source_with(value: Variant, policy: LazilyMergePolicy) -> LazilySource:
	return LazilySource.new(self, value, policy)


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
	if _flushing:
		# A nested flush would drain the queue the outer loop is bounding, so a
		# feedback effect would spin instead of reporting exhaustion. The outer
		# loop picks up whatever this body scheduled.
		return
	_flushing = true
	var guard := 0
	while not _pending.is_empty():
		guard += 1
		if guard > drain_bound:
			# Exhaustion is REPORTED, not thrown away and not spun on. The graph
			# is left settled-as-far-as-it-got and the caller can read the flag.
			_drain_exhausted = true
			_pending.clear()
			_pending_ids.clear()
			_flushing = false
			return
		var node: LazilyCell = _pending.pop_front()
		_pending_ids.erase(node.get_instance_id())
		if node.is_disposed():
			continue
		if node is LazilyEffect:
			(node as LazilyEffect).run()
		elif node is LazilyComputed:
			(node as LazilyComputed)._recompute()
	_flushing = false
