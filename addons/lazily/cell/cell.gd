## Base cell. Owns identity, disposal, and the weak back-edge index.
##
## Not an abstract class: the declared floor is Godot 4.4 and `@abstract` did not
## land until 4.5. The compute hooks below therefore push an error rather than
## being structurally unimplementable. Do not "fix" this by raising the floor
## without revisiting the decision in `plan-lazily-gd.md`.
class_name LazilyCell
extends RefCounted

## Back-edges, `instance_id -> WeakRef(LazilyCell)`.
##
## WEAK, and that is the whole design. `RefCounted` has no cycle collector, so a
## forward `Computed -> deps` strong edge plus a strong `dep -> dependents` edge
## would leak every graph that was ever built. Keying on `get_instance_id()`
## gives O(1) dedup and is safe because an instance id is never reused, so a dead
## entry can never be mistaken for a live successor.
##
## Ids are GENERATIONAL, not monotonic. ObjectDB recycles the slot in the low
## bits on almost every allocation and increments a validator in the high bits
## each time; it is the validator, not an ever-rising counter, that makes the
## composed id unique. `test_instance_ids_are_generational_not_monotonic`
## measures both halves, so the property this index rests on is asserted rather
## than inherited from a docs paraphrase.
##
## The aliasing hazard `recycled_id_inherits_nothing.json` is about — a disposed
## node's edges reappearing under whatever inherits its id — cannot arise here
## for a structural reason that outranks the id scheme: this dictionary lives
## INSIDE the node, so a fresh node has a fresh index. There is no owner-keyed
## side table to alias.
var _dependents: Dictionary[int, WeakRef] = {}

var _disposed := false

## The owning context, so a failed read can be REPORTED rather than only logged.
## `push_error` is invisible to a caller; a graph that fails a read must be able
## to say so.
var _ctx: LazilyContext = null


func is_disposed() -> bool:
	return _disposed


## Reading a disposed cell is an error, not a stale value.
## (`conformance/reactive-graph/read_after_dispose_is_an_error.json`)
func _assert_live(what: String) -> bool:
	if _disposed:
		push_error("lazily: %s on a disposed cell" % what)
		if _ctx != null:
			_ctx._record_read_error("read_after_dispose")
		return false
	return true


## Register `node` as depending on this cell. Idempotent.
func _add_dependent(node: LazilyCell) -> void:
	_dependents[node.get_instance_id()] = weakref(node)


func _remove_dependent(node: LazilyCell) -> void:
	_dependents.erase(node.get_instance_id())


## Live dependents, pruning dead weak refs as it goes.
##
## Pruning happens HERE — before any read of the edge set — rather than in a
## finalizer, because GDScript has no finalizer hook. A caller that counts edges
## without pruning first reads them high, which is why every edge-count
## assertion must route through this method.
func _live_dependents() -> Array[LazilyCell]:
	var live: Array[LazilyCell] = []
	var dead: Array[int] = []
	for id: int in _dependents:
		var node: LazilyCell = _dependents[id].get_ref()
		if node == null:
			dead.append(id)
		else:
			live.append(node)
	for id: int in dead:
		_dependents.erase(id)
	return live


## Edge count, pruned. The only honest way to ask.
func dependent_count() -> int:
	return _live_dependents().size()


## Mark this cell and its whole transitive cone stale.
##
## Transitive by construction, not one level: a one-level mark plus a
## cache-trusting read silently drops writes at depth 2 and deeper. Recursion
## stops at an already-stale cell, which is sound precisely because becoming
## stale is what propagates the mark onward.
## `reactive` separates the two reasons a cone goes stale. A WRITE is a value
## change and must re-run effects. A DISPOSE invalidates cached values so a later
## read cannot serve one derived from a cell that no longer exists — but it is
## not a new value, and it must not make surviving effects fire.
## (`disposal_does_not_run_surviving_effects.json`)
func _invalidate(reactive: bool = true) -> void:
	for node: LazilyCell in _live_dependents():
		node._on_dependency_invalidated(reactive)


## Overridden by cells that cache. The base cell has nothing to invalidate, so it
## only forwards.
func _on_dependency_invalidated(reactive: bool = true) -> void:
	_invalidate(reactive)


## Value for a tracked read. Overridden by every concrete cell.
func _read(_compute: LazilyCompute) -> Variant:
	push_error("lazily: _read() not implemented on %s" % get_class())
	return null


func dispose() -> void:
	if _disposed:
		return
	_disposed = true
	_detach()
	# Dependents must be invalidated BEFORE the edge set is dropped, or they keep
	# serving a cached value derived from a cell that no longer exists — the read
	# then succeeds instead of reporting `read_after_dispose`, and disposal looks
	# like it worked. (`read_after_dispose_is_an_error.json`)
	_invalidate(false)
	_dependents.clear()


## Detach from upstream. Cells with no upstream have nothing to do.
##
## Detachment is BOTH directions — the forward dep list and the back-edge on each
## dependency. (`dispose_detaches_edges_both_directions.json`)
func _detach() -> void:
	pass
