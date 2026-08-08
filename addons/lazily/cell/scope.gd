## Ownership boundary and teardown unit.
##
## The scope is the SOLE strong owner of the effects it creates. Every other
## inbound reference to a cell in this family is a weak back-edge, so the member
## list below is not a convenience — it is the ownership record, and its order is
## the teardown order.
class_name LazilyScope
extends RefCounted

var _ctx: LazilyContext
## Strong, in creation order. Teardown walks it backwards.
var _members: Array[LazilyCell] = []
var _disposed := false
var _armed := true


func _init(ctx: LazilyContext) -> void:
	_ctx = ctx


## Create an Effect owned by this scope, and run it once to establish edges.
func effect(fn: Callable) -> LazilyEffect:
	if _disposed:
		push_error("lazily: cannot create an Effect on a disposed scope")
		return null
	var e := LazilyEffect.new(_ctx, fn)
	_members.append(e)
	e.run()
	return e


## Put an already-built cell under this scope's ownership.
func own(cell: LazilyCell) -> LazilyCell:
	if _disposed:
		push_error("lazily: cannot add a member to a disposed scope")
		return cell
	_members.append(cell)
	return cell


## Disarm: this scope will no longer tear down its members.
##
## Disarming disposes NOTHING. It is not a soft dispose, and calling it must
## leave every member live and running.
## (`disarm_disposes_nothing.json`)
func disarm() -> void:
	_armed = false


func is_armed() -> bool:
	return _armed


func member_count() -> int:
	return _members.size()


## Teardown. Members are disposed in REVERSE creation order, so a member can
## rely on anything created before it still being alive while it tears down.
## (`teardown_runs_members_in_reverse_creation_order.json`)
func dispose() -> void:
	if _disposed:
		return
	_disposed = true
	if not _armed:
		# Disarmed: drop ownership without disposing anything. The members stay
		# live for whoever else holds them.
		_members.clear()
		return
	for i in range(_members.size() - 1, -1, -1):
		_members[i].dispose()
	_members.clear()


func is_disposed() -> bool:
	return _disposed
