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
## gives O(1) dedup and is safe because Godot instance ids are monotonic — an id
## is never reused, so a dead entry can never be mistaken for a live successor.
var _dependents: Dictionary[int, WeakRef] = {}

var _disposed := false


func is_disposed() -> bool:
	return _disposed


## Reading a disposed cell is an error, not a stale value.
## (`conformance/reactive-graph/read_after_dispose_is_an_error.json`)
func _assert_live(what: String) -> bool:
	if _disposed:
		push_error("lazily: %s on a disposed cell" % what)
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
func _invalidate() -> void:
	for node: LazilyCell in _live_dependents():
		node._on_dependency_invalidated()


## Overridden by cells that cache. The base cell has nothing to invalidate, so it
## only forwards.
func _on_dependency_invalidated() -> void:
	_invalidate()


## Value for a tracked read. Overridden by every concrete cell.
func _read(_compute: LazilyCompute) -> Variant:
	push_error("lazily: _read() not implemented on %s" % get_class())
	return null


func dispose() -> void:
	if _disposed:
		return
	_disposed = true
	_detach()
	_dependents.clear()


## Detach from upstream. Cells with no upstream have nothing to do.
##
## Detachment is BOTH directions — the forward dep list and the back-edge on each
## dependency. (`dispose_detaches_edges_both_directions.json`)
func _detach() -> void:
	pass
