## The tracked read view handed to one recompute of one node.
##
## The node is threaded into the VALUE, not held in an ambient "currently
## computing" global. That is the fortification the family settled on: a closure's
## dependencies are attributed to the correct node by construction, so a read
## cannot silently miss tracking and an untracked read cannot silently gain it.
## Ambient context is gone in all nine bindings; do not reintroduce it here.
##
## The tracked read is `read()`, not `get()`. `Object.get(property)` is a Godot
## builtin, and shadowing it would break every `obj.get("prop")` call a consumer
## makes on a lazily handle. `read()` is already the name the reference binding
## uses for the tracked read, so this costs nothing in cross-binding legibility.
class_name LazilyCompute
extends RefCounted

var _owner: LazilyCell
var _ctx: LazilyContext

## Dependencies observed during THIS recompute, in encounter order.
var _deps: Array[LazilyCell] = []
## Membership test for the above, so repeated reads of one cell stay O(1).
var _seen: Dictionary[int, bool] = {}


func _init(owner: LazilyCell, ctx: LazilyContext) -> void:
	_owner = owner
	_ctx = ctx


## Tracked read: forms a dependency edge from the owning node to `cell`.
func read(cell: LazilyCell) -> Variant:
	if cell == null:
		push_error("lazily: tracked read of a null cell")
		return null
	if not cell._assert_live("read"):
		return null
	var id := cell.get_instance_id()
	if not _seen.has(id):
		_seen[id] = true
		_deps.append(cell)
		cell._add_dependent(_owner)
	return cell._read(self)


## Untracked read: forms NO edge. The explicit escape hatch, so that "no edge"
## is something a reader can see at the call site rather than infer.
func peek(cell: LazilyCell) -> Variant:
	if cell == null:
		push_error("lazily: untracked read of a null cell")
		return null
	if not cell._assert_live("peek"):
		return null
	return cell._read(self)


## The owning context, for a body that needs to build cells mid-compute.
func ctx() -> LazilyContext:
	return _ctx
