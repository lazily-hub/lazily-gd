## Replays a canonical `ReactiveGraph` fixture against the cell kernel.
##
## Interprets the fixture's own `steps`/`expect` data. It does not re-state the
## expectations in GDScript — a hand-transcribed expectation is a second source
## of truth that drifts from the corpus silently, which is the drift the runtime
## manifest exists to catch one level down.
##
## Returns a list of human-readable failures; empty means the fixture passed.
class_name LazilyReactiveGraphRunner
extends RefCounted

var ctx: LazilyContext
var cells: Dictionary[String, LazilyCell] = {}
var scopes: Dictionary[String, LazilyScope] = {}
## Effects, by fixture id, so `cleanup_order` and `observed_by` can name them.
var effects: Dictionary[String, LazilyEffect] = {}
var effect_scope_of: Dictionary[String, String] = {}
## Ordered record of which effect bodies ran since the last checkpoint.
var observed: Array[String] = []
var cleanup_order: Array[String] = []
## Effects the fixture declared as writing into their own dependency cone.
var _root_scope: LazilyScope

var failures: Array[String] = []


func run(fixture: Dictionary) -> Array[String]:
	ctx = LazilyContext.new()
	# Unscoped effects in a fixture still need an owner, because a scope is the
	# sole strong owner in this binding. The runner is that owner; the fixture's
	# semantics are unchanged, since it never tears this scope down.
	_root_scope = ctx.scope()
	var steps: Array = fixture.get("steps", [])
	for i in steps.size():
		var step: Dictionary = steps[i]
		var op: Dictionary = step.get("op", {})
		_apply(op, i)
		var expect: Variant = step.get("expect")
		if expect != null:
			_check(expect as Dictionary, op, i)
	return failures


func _fail(i: int, msg: String) -> void:
	failures.append("step %d: %s" % [i, msg])


func _apply(op: Dictionary, i: int) -> void:
	# `observed_by` means "ran because of THIS step", so the ledger resets per
	# step. Clearing it only when an expectation reads it would let the effects
	# that ran at creation leak into a later step's assertion.
	observed = []
	ctx.take_read_error()
	var t: String = op.get("type", "")
	match t:
		"cell":
			cells[op["id"]] = ctx.source(op.get("value"))
		"computed":
			var reads: Array = op.get("reads", [])
			var offset: int = int(op.get("offset", 0))
			var c := ctx.computed(func(k: LazilyCompute) -> Variant:
				var total: int = offset
				for r: String in reads:
					total += _as_int(k.read(cells[r]))
				return total)
			cells[op["id"]] = c
			var sc: String = op.get("scope", "")
			if sc != "":
				scopes[sc].own(c)
		"effect":
			_make_effect(op, i)
		"set_cell":
			var target: Variant = cells.get(op["id"])
			if target == null:
				_fail(i, "set_cell names unknown cell '%s'" % op["id"])
				return
			(target as LazilySource).set_value(op.get("value"))
		"read":
			var cell: Variant = cells.get(op["id"])
			if cell == null:
				_fail(i, "read names unknown cell '%s'" % op["id"])
				return
			# Reading through the context is the untracked path — a fixture read
			# is an observation, not a dependency.
			ctx.peek(cell as LazilyCell)
		"begin_scope":
			scopes[op["scope"]] = ctx.scope()
		"end_scope":
			var s: Variant = scopes.get(op["scope"])
			if s == null:
				_fail(i, "end_scope names unknown scope '%s'" % op["scope"])
				return
			(s as LazilyScope).dispose()
		"disarm":
			var d: Variant = scopes.get(op["scope"])
			if d == null:
				_fail(i, "disarm names unknown scope '%s'" % op["scope"])
				return
			(d as LazilyScope).disarm()
		"dispose":
			var victim: Variant = cells.get(op["id"])
			if victim != null:
				(victim as LazilyCell).dispose()
			elif effects.has(op["id"]):
				effects[op["id"]].dispose()
			else:
				_fail(i, "dispose names unknown id '%s'" % op["id"])
		_:
			_fail(i, "unsupported op '%s' — this runner replays only the Phase 1 vocabulary" % t)


func _make_effect(op: Dictionary, _i: int) -> void:
	var id: String = op["id"]
	var reads: Array = op.get("reads", [])
	var writes_own_cone: String = op.get("writes_own_cone", "")
	var sc: String = op.get("scope", "")
	var owner: LazilyScope = scopes[sc] if sc != "" and scopes.has(sc) else _root_scope

	# `writes_own_cone` describes an effect that feeds back when it REACTS. The
	# establishing run is not a reaction, and treating it as one would diverge at
	# creation — which the fixture explicitly expects not to happen
	# (`drain_exhausted: false` immediately after the effect op).
	var established := [false]
	var e := owner.effect(func(k: LazilyCompute) -> void:
		observed.append(id)
		var total := 0
		for r: String in reads:
			total += _as_int(k.read(cells[r]))
		if writes_own_cone != "" and established[0]:
			# Deliberate feedback: writing a cell this body reads. The contract
			# is that the drain reports exhaustion, not that it settles.
			var target := cells[writes_own_cone] as LazilySource
			target.set_value(_as_int(target.peek()) + 1)
		established[0] = true)
	effects[id] = e
	effect_scope_of[id] = sc
	# Teardown order is observed through the scope's member list, so wrap the
	# member slot with a recorder rather than trusting a separate list.
	var members := owner._members
	members[members.size() - 1] = _CleanupRecorder.new(cleanup_order, id, e)


func _check(expect: Dictionary, op: Dictionary, i: int) -> void:
	for key: String in expect:
		match key:
			"note":
				continue
			"value":
				var cell: Variant = cells.get(op.get("id", ""))
				if cell == null:
					_fail(i, "expect.value but op names no known cell")
					continue
				var got: Variant = ctx.peek(cell as LazilyCell)
				if got != expect["value"]:
					_fail(i, "expect.value %s, got %s" % [expect["value"], got])
			"read":
				var wanted: Dictionary = expect["read"]
				for cid: String in wanted:
					var c: Variant = cells.get(cid)
					if c == null:
						_fail(i, "expect.read names unknown cell '%s'" % cid)
						continue
					var got2: Variant = ctx.peek(c as LazilyCell)
					if got2 != wanted[cid]:
						_fail(i, "expect.read['%s'] %s, got %s" % [cid, wanted[cid], got2])
			"readable":
				var want_map: Dictionary = expect["readable"]
				for rid: String in want_map:
					var target: Variant = cells.get(rid)
					if target == null and effects.has(rid):
						target = effects[rid]
					if target == null:
						_fail(i, "expect.readable names unknown id '%s'" % rid)
						continue
					var is_readable := not (target as LazilyCell).is_disposed()
					if is_readable != bool(want_map[rid]):
						_fail(i, "expect.readable['%s'] %s, got %s"
							% [rid, want_map[rid], is_readable])
			"error":
				# Read through the context rather than inferred from disposal
				# state: a Computed whose DEPENDENCY was disposed must also
				# report, and its own flag would say nothing.
				var got_err := ctx.take_read_error()
				var want_err: Variant = expect["error"]
				if want_err == null:
					if got_err != "":
						_fail(i, "expect.error null but got '%s'" % got_err)
				elif got_err == "":
					_fail(i, "expect.error %s but the read succeeded" % want_err)
				elif got_err != String(want_err):
					_fail(i, "expect.error %s, got '%s'" % [want_err, got_err])
			"dependents_of":
				var wanted2: Dictionary = expect["dependents_of"]
				for cid2: String in wanted2:
					var c5: Variant = cells.get(cid2)
					if c5 == null:
						_fail(i, "expect.dependents_of names unknown cell '%s'" % cid2)
						continue
					var got3 := (c5 as LazilyCell).dependent_count()
					if got3 != int(wanted2[cid2]):
						_fail(i, "expect.dependents_of['%s'] %s, got %d"
							% [cid2, wanted2[cid2], got3])
			"dependencies_of":
				var wanted3: Dictionary = expect["dependencies_of"]
				for cid3: String in wanted3:
					var got4 := _dependency_count(cid3)
					if got4 != int(wanted3[cid3]):
						_fail(i, "expect.dependencies_of['%s'] %s, got %d"
							% [cid3, wanted3[cid3], got4])
			"scope_owned_count":
				var wanted4: Dictionary = expect["scope_owned_count"]
				for sid: String in wanted4:
					var s2: Variant = scopes.get(sid)
					if s2 == null:
						_fail(i, "expect.scope_owned_count names unknown scope '%s'" % sid)
						continue
					var got5 := (s2 as LazilyScope).member_count()
					if got5 != int(wanted4[sid]):
						_fail(i, "expect.scope_owned_count['%s'] %s, got %d"
							% [sid, wanted4[sid], got5])
			"cleanup_order":
				var want_order: Array = expect["cleanup_order"]
				if cleanup_order != Array(want_order):
					_fail(i, "expect.cleanup_order %s, got %s" % [want_order, cleanup_order])
				cleanup_order = []
			"observed_by":
				var want_obs: Array = expect["observed_by"]
				var got_obs := observed.duplicate()
				got_obs.sort()
				var want_sorted := Array(want_obs).duplicate()
				want_sorted.sort()
				if got_obs != want_sorted:
					_fail(i, "expect.observed_by %s, got %s" % [want_sorted, got_obs])
				observed = []
			"drain_exhausted":
				var want_drain: bool = expect["drain_exhausted"]
				if ctx.drain_exhausted() != want_drain:
					_fail(i, "expect.drain_exhausted %s, got %s"
						% [want_drain, ctx.drain_exhausted()])
				ctx.clear_drain_exhausted()
			_:
				_fail(i, "unsupported expectation '%s' — this runner does not assert it, "
					% key + "and silently ignoring it would be a false green")


## A failed read yields null, and `int(null)` throws. The value is meaningless
## once the read errored — the error itself is what the fixture asserts.
static func _as_int(v: Variant) -> int:
	if v == null:
		return 0
	return int(v)


func _dependency_count(cell_id: String) -> int:
	var c: Variant = cells.get(cell_id)
	if c is LazilyComputed:
		return (c as LazilyComputed)._deps.size()
	if effects.has(cell_id):
		return effects[cell_id]._deps.size()
	return 0


## Records teardown order without changing it.
class _CleanupRecorder extends LazilyCell:
	var _order: Array[String]
	var _id: String
	var _inner: LazilyCell

	func _init(order: Array[String], id: String, inner: LazilyCell) -> void:
		_order = order
		_id = id
		_inner = inner

	func dispose() -> void:
		if _disposed:
			return
		_order.append(_id)
		_inner.dispose()
		super()
