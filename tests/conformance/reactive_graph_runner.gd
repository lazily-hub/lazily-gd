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
## The handle first bound to each fixture id, kept forever so
## `dispose_stale_handle` can dispose through a reference to a node that is
## already gone. Separate from `cells`/`effects` on purpose: churn rebinds an id
## to a replacement node, and the stale-handle op asks about the ORIGINAL.
var stale_handles: Dictionary[String, LazilyCell] = {}
## Ordered record of which effect bodies ran since the last checkpoint.
var observed: Array[String] = []

## Cumulative fold count per merge cell, never reset — `merges_of` is a running
## total from scenario start, mirroring `computes_of`, so a fixture can assert
## that a step did NOT fold by repeating the previous step's number.
var merges: Dictionary[String, int] = {}

## Cumulative run count per effect, for `computes_of` on an effect id.
var effect_runs: Dictionary[String, int] = {}
var cleanup_order: Array[String] = []
## Effects the fixture declared as writing into their own dependency cone.
var _root_scope: LazilyScope

## Cumulative compute-function runs per cell id. The runner builds every compute
## body here, so it counts them at the only place that cannot disagree with what
## actually ran — a kernel-side counter would be a second source of truth, and an
## inferred count would be the hand-transcribed expectation this runner exists to
## avoid.
var computes: Dictionary[String, int] = {}
## Compute failures still armed per cell id, decremented as each one fires.
## Injected in the runner rather than the kernel: the contract under test is
## that a FAILED compute is not cached, and that holds however the body failed.
## A kernel-side failure switch would test the switch.
var fail_next: Dictionary[String, int] = {}

## Names the scenario a failure came from; empty for a shape=steps fixture.
var _scenario := ""

## Scenario ids this run actually replayed, in order.
##
## The declared-vs-replayed rung. A scenario the runner skips contributes no
## failures, so replaying 1 of 2 scenarios reports conformance over half the
## fixture — indistinguishable from replaying both. The suite asserts this
## against the ids the fixture declares.
var scenarios_replayed: Array[String] = []

var failures: Array[String] = []


## Replays a fixture of either shape.
##
## `shape: "scenarios"` is a fixture carrying several INDEPENDENT runs, not a
## longer one. Each scenario gets a fresh context and fresh runner state, and
## carrying state across them would let an earlier scenario's graph satisfy a
## later scenario's assertion — which is how a multi-scenario fixture reports
## conformance it never demonstrated.
func run(fixture: Dictionary) -> Array[String]:
	# Fail CLOSED on a shape this runner does not model (#lzledgeragreementaudit).
	# `fixture.get("shape", "steps")` used to fall through to the `steps` arm for
	# ANY other value, and a fixture whose steps moved under a different key then
	# read as an empty step list: zero steps replayed, zero failures, green. Both
	# ledgers would still agree — the fixture is named in REPLAYED and absent from
	# KNOWN_UNCOVERED — while the run proved nothing. Every canonical
	# reactive-graph fixture carries an explicit `shape`, so a missing one is drift
	# too, not a default worth honouring.
	var shape: String = str(fixture.get("shape", ""))
	if shape != "steps" and shape != "scenarios":
		failures.append(
			("unsupported fixture shape '%s' — this runner replays only `steps` " % shape)
			+ "and `scenarios`. Teach it the shape, or name the fixture in "
			+ "KNOWN_UNCOVERED in scripts/check-conformance-coverage.sh with a reason"
		)
		return failures
	if shape == "scenarios":
		var scenarios: Array = fixture.get("scenarios", [])
		if scenarios.is_empty():
			failures.append("shape=scenarios but the fixture carries none — "
				+ "replaying nothing must not report conformance")
			return failures
		for sc: Dictionary in scenarios:
			# The id is required rather than defaulted to a position: a scenario
			# booked by index cannot be named in an excuse and silently renumbers
			# when the corpus grows.
			var sid: String = str(sc.get("id", sc.get("name", "")))
			if sid == "":
				failures.append("a scenario carries neither `id` nor `name`")
				continue
			scenarios_replayed.append(sid)
			_replay(sc.get("steps", []), sid)
		return failures
	var steps: Array = fixture.get("steps", [])
	if steps.is_empty():
		# The `steps` twin of the scenarios rung above: replaying nothing must not
		# report conformance.
		failures.append("shape=steps but the fixture carries none — "
			+ "replaying nothing must not report conformance")
		return failures
	_replay(steps, "")
	return failures


## One independent run: fresh context, fresh state.
func _replay(steps: Array, scenario: String) -> void:
	_scenario = scenario
	ctx = LazilyContext.new()
	cells = {}
	scopes = {}
	effects = {}
	effect_scope_of = {}
	stale_handles = {}
	observed = []
	cleanup_order = []
	computes = {}
	fail_next = {}
	# Unscoped effects in a fixture still need an owner, because a scope is the
	# sole strong owner in this binding. The runner is that owner; the fixture's
	# semantics are unchanged, since it never tears this scope down MID-replay.
	_root_scope = ctx.scope()
	for i in steps.size():
		var step: Dictionary = steps[i]
		var op: Dictionary = step.get("op", {})
		_apply(op, i)
		var expect: Variant = step.get("expect")
		if expect != null:
			_check(expect as Dictionary, op, i)
	# Tear the owner down once every step and expectation is done. Nothing
	# observable depends on it — but `churn_returns_to_baseline` builds a
	# thousand subscribers, and each one's body captures this runner, so
	# `runner -> _root_scope -> effect -> body -> runner` is a reference cycle
	# and `RefCounted` has no collector to break it. Leaving it standing means
	# the runner that just proved a graph does not leak leaks that graph on the
	# way out. Clearing the member list is what breaks the ring.
	_root_scope.dispose()


func _fail(i: int, msg: String) -> void:
	if _scenario == "":
		failures.append("step %d: %s" % [i, msg])
	else:
		failures.append("scenario %s, step %d: %s" % [_scenario, i, msg])


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
			_remember_handle(op["id"], cells[op["id"]])
		"merge_cell":
			# A merge cell is an ordinary source node whose writes fold under a
			# policy — same class, so degree/read/dispose are unchanged. The
			# counter is registered HERE so `merges_of` on a cell that has folded
			# nothing reads 0 rather than failing as unknown, which is what
			# `merge_per_settled_cone_not_per_write.json` asserts on its first
			# step ("construction alone folds nothing").
			cells[op["id"]] = ctx.source_with(op.get("value"), _policy_of(op, i))
			_remember_handle(op["id"], cells[op["id"]])
			if not merges.has(op["id"]):
				merges[op["id"]] = 0
		"merge":
			# An explicit merge() call — exact, one fold per call. Not emitted by
			# the five landed fixtures (which fold inside a batch or through a
			# feed effect), but accepted so a future single-fold fixture is not an
			# unknown op silently routed somewhere else.
			var mtgt: Variant = cells.get(op["id"])
			if mtgt == null:
				_fail(i, "merge names unknown cell '%s'" % op["id"])
				return
			merges[op["id"]] = int(merges.get(op["id"], 0)) + 1
			(mtgt as LazilySource).merge(op.get("value"))
		"computed":
			var c := ctx.computed(_derivation(op))
			cells[op["id"]] = c
			_remember_handle(op["id"], c)
			var sc: String = op.get("scope", "")
			if sc != "":
				scopes[sc].own(c)
				_record_teardown_of(scopes[sc], op["id"], c)
		"signal":
			# A signal IS an eager `Computed`, not a distinct kind. Welding
			# eagerness into invalidation instead recomputes once per WRITE rather
			# than once per batch — the `#lzsignaleager` defect that every
			# values-only fixture passes.
			var sig := ctx.computed(_derivation(op)).eager()
			cells[op["id"]] = sig
			_remember_handle(op["id"], sig)
			var ssc: String = op.get("scope", "")
			if ssc != "":
				scopes[ssc].own(sig)
		"fail_next":
			# Arming must not itself compute — the fixture asserts the count is
			# unchanged at this step, which catches a binding that re-runs the body
			# in order to arm it.
			fail_next[op["id"]] = int(op.get("count", 1))
		"dispose_signal":
			var sg: Variant = cells.get(op["id"])
			if sg is LazilyComputed:
				(sg as LazilyComputed).lazy()
			else:
				_fail(i, "dispose_signal names unknown signal '%s'" % op["id"])
		"batch":
			# The writes land inside ONE batch so the flush happens once at exit.
			# Applying them individually would coalesce nothing and make
			# `signal_materializes_once_per_batch` indistinguishable from the
			# per-write defect it exists to catch.
			var writes: Array = op.get("writes", [])
			var batch_merges: Array = op.get("merges", [])
			ctx.batch(func() -> Variant:
				for w: Dictionary in writes:
					var wt: Variant = cells.get(w["id"])
					if wt == null:
						_fail(i, "batch write names unknown cell '%s'" % w["id"])
						continue
					(wt as LazilySource).set_value(w.get("value"))
				# Explicit merges inside a batch fold SYNCHRONOUSLY — only the
				# downstream cascade defers to batch exit. Counting here is exact
				# for the same reason the fold is: the caller decides how many ops
				# exist. A binding that deferred the FOLD as well shows fewer
				# merges than calls and, under Sum, the wrong value too
				# (`merge_folds_synchronously_in_batch.json`).
				for m: Dictionary in batch_merges:
					var mt: Variant = cells.get(m["id"])
					if mt == null:
						_fail(i, "batch merge names unknown cell '%s'" % m["id"])
						continue
					merges[m["id"]] = int(merges.get(m["id"], 0)) + 1
					(mt as LazilySource).merge(m.get("value"))
				return null)
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
			# An explicit disposal joins the same cleanup ledger as a scope
			# teardown. `scope_teardown_equals_fold_of_disposals.json` asserts the
			# two routes produce the SAME order, which it cannot do if only one of
			# them is observed.
			var victim: Variant = cells.get(op["id"])
			if victim != null:
				cleanup_order.append(op["id"])
				(victim as LazilyCell).dispose()
			elif effects.has(op["id"]):
				cleanup_order.append(op["id"])
				effects[op["id"]].dispose()
			else:
				_fail(i, "dispose names unknown id '%s'" % op["id"])
		"fanout":
			_fanout(op, i)
		"dispose_fanout":
			_dispose_fanout(op, i)
		"churn":
			_churn(op, i)
		"dispose_stale_handle":
			_dispose_stale_handle(op, i)
		_:
			_fail(i, "unsupported op '%s' — this runner replays only the Phase 1 vocabulary" % t)


## Bind `id` to the handle it is FIRST created with, and never rebind it.
##
## `cells`/`effects` follow the fixture's current meaning of an id; churn
## deliberately rebinds one. `dispose_stale_handle` asks the other question —
## what the id used to name — so it needs the binding that is no longer current.
func _remember_handle(id: String, node: LazilyCell) -> void:
	if not stale_handles.has(id):
		stale_handles[id] = node


## A fanout/churn subscriber, created as an EFFECT rather than a derived cell.
##
## `churn_returns_to_baseline` asserts `observed_count` on a publish, and in a
## lazy binding only a sink observes a publish without being pulled. A `Computed`
## subscriber would register the edge and then observe nothing: every degree
## assertion in both fixtures would still pass while the propagation assertion —
## the one that makes the leak visible as WORK and not only as memory — read 0.
##
## The scope is passed in because it is the sole strong owner here. A subscriber
## owned by `_root_scope` lives until the runner drops it; one owned by a
## per-cycle scope is gone when that scope ends, which is what the
## `scope_per_cycle` churn mode means.
func _subscriber(id: String, reads: Array, owner: LazilyScope) -> LazilyEffect:
	var e := owner.effect(func(k: LazilyCompute) -> void:
		observed.append(id)
		effect_runs[id] = int(effect_runs.get(id, 0)) + 1
		for r: String in reads:
			_as_int(k.read(cells[r])))
	effects[id] = e
	return e


## `read_each` is honoured by construction here, and saying so is not free.
##
## An Effect runs — and therefore reads — at creation, so every subscriber this
## runner builds registers its edge immediately. That satisfies `read_each: true`
## exactly; it CANNOT express `read_each: false`, which describes a subscriber
## that is wired but never pulled. Doing the same thing for both values would
## replay a fixture other than the one on disk, so the false case fails closed.
func _requires_read_each(op: Dictionary, i: int, what: String) -> bool:
	if bool(op.get("read_each", false)):
		return true
	_fail(i, ("%s with read_each=false is not modelled — a subscriber here is an " % what)
		+ "Effect, which reads at creation; there is no wired-but-unpulled form")
	return false


func _fanout(op: Dictionary, i: int) -> void:
	var prefix: String = op.get("id_prefix", "")
	var reads: Array = op.get("reads", [])
	for r: String in reads:
		if not cells.has(r):
			_fail(i, "fanout reads unknown cell '%s'" % r)
			return
	if not _requires_read_each(op, i, "fanout"):
		return
	for n in int(op.get("count", 0)):
		_subscriber("%s_%d" % [prefix, n], reads, _root_scope)


## Tear down the whole fanout. Disposing an absent index is not silently fine:
## a count that outruns what was created means the fixture and the runner
## disagree about how wide the fanout was, and the degree assertion that follows
## would then be satisfied by a fanout that was never built.
func _dispose_fanout(op: Dictionary, i: int) -> void:
	var prefix: String = op.get("id_prefix", "")
	for n in int(op.get("count", 0)):
		var id := "%s_%d" % [prefix, n]
		if not effects.has(id):
			_fail(i, "dispose_fanout names '%s', which this run never created" % id)
			return
		effects[id].dispose()


## Subscribe/unsubscribe churn, in the two modes the corpus declares.
##
## Both hold the LIVE subscriber count invariant across the cycles; they differ
## only in who performs the teardown. That is the point of running both: scope
## teardown is meant to be the fold of the individual disposals, so a binding
## whose two routes disagree returns to different baselines.
func _churn(op: Dictionary, i: int) -> void:
	var src: String = op.get("source", "")
	if not cells.has(src):
		_fail(i, "churn names unknown source cell '%s'" % src)
		return
	if not _requires_read_each(op, i, "churn"):
		return
	var reads: Array = [src]
	var prefix: String = op.get("id_prefix", "")
	var cycles: int = int(op.get("cycles", 0))
	var mode: String = op.get("mode", "")
	match mode:
		"dispose_then_create":
			var width: int = int(op.get("live_width", 0))
			if width <= 0:
				_fail(i, "churn mode dispose_then_create needs a positive live_width")
				return
			for c in cycles:
				# Dispose BEFORE creating the replacement. Creating first would
				# hold width+1 subscribers for the length of a cycle, and the
				# steady-state count a leaking binding is measured against would
				# then depend on where the assertion happened to land.
				var id := "%s_%d" % [prefix, c % width]
				if effects.has(id):
					effects[id].dispose()
				_subscriber(id, reads, _root_scope)
		"scope_per_cycle":
			var id2 := "%s_scoped" % prefix
			for c in cycles:
				var s := ctx.scope()
				_subscriber(id2, reads, s)
				s.dispose()
		_:
			_fail(i, ("unsupported churn mode '%s' — this runner replays " % mode)
				+ "`dispose_then_create` and `scope_per_cycle`")


## Dispose through a handle whose node is already gone.
##
## The declared `handle_kind` is CHECKED, not trusted: it is the fixture's
## statement about what the recycled id used to name, and a runner that recorded
## something else would be disposing a different node than the contract
## describes while still observing the survivor it expects.
func _dispose_stale_handle(op: Dictionary, i: int) -> void:
	var of: String = op.get("handle_of", "")
	if not stale_handles.has(of):
		_fail(i, "dispose_stale_handle names '%s', for which no handle was recorded" % of)
		return
	var handle: LazilyCell = stale_handles[of]
	var want: String = op.get("handle_kind", "")
	var got := _handle_kind(handle)
	if got != want:
		_fail(i, "dispose_stale_handle declares handle_kind '%s' for '%s', but the "
			% [want, of] + "recorded handle is a '%s'" % got)
		return
	handle.dispose()


## The corpus's three handle kinds, as this binding spells them: a source cell is
## `cell`, a derived cell is `slot`, a sink is `effect`.
static func _handle_kind(handle: LazilyCell) -> String:
	if handle is LazilyEffect:
		return "effect"
	if handle is LazilySource:
		return "cell"
	return "slot"


## The compute body shared by the `computed` and `signal` ops, wrapped in the
## `computes` counter. Both derive identically — the ONLY difference is
## eagerness, which is exactly what `computes_of` discriminates.
func _derivation(op: Dictionary) -> Callable:
	var id: String = op["id"]
	var reads: Array = op.get("reads", [])
	var offset: int = int(op.get("offset", 0))
	return func(k: LazilyCompute) -> Variant:
		computes[id] = computes.get(id, 0) + 1
		# The count increments BEFORE the failure check: the body ran, and the
		# fixture asserts exactly that — a failed compute is still a compute.
		var armed: int = fail_next.get(id, 0)
		if armed > 0:
			fail_next[id] = armed - 1
			ctx._record_read_error("compute_failed")
			return null
		var total: int = offset
		for r: String in reads:
			total += _as_int(k.read(cells[r]))
		return total


## Resolve a merge cell's declared policy.
##
## The corpus only ever folds under `Sum`. An unknown name is refused rather
## than defaulted: folding under the wrong algebra satisfies every COUNT
## assertion while landing on the wrong value, which is the one failure a
## counting-only runner cannot see.
func _policy_of(op: Dictionary, i: int) -> LazilyMergePolicy:
	var name: String = op.get("policy", "Sum")
	if name == "Sum":
		return LazilyMergePolicy.sum()
	if name == "KeepLatest":
		return LazilyMergePolicy.keep_latest()
	_fail(i, "unsupported merge policy '%s' — this runner folds under Sum" % name)
	return LazilyMergePolicy.sum()


func _make_effect(op: Dictionary, _i: int) -> void:
	var id: String = op["id"]
	var reads: Array = op.get("reads", [])
	var writes_own_cone: String = op.get("writes_own_cone", "")
	var merges_into: String = op.get("merges_into", "")
	var sc: String = op.get("scope", "")
	var owner: LazilyScope = scopes[sc] if sc != "" and scopes.has(sc) else _root_scope

	# `writes_own_cone` describes an effect that feeds back when it REACTS. The
	# establishing run is not a reaction, and treating it as one would diverge at
	# creation — which the fixture explicitly expects not to happen
	# (`drain_exhausted: false` immediately after the effect op).
	var established := [false]
	var e := owner.effect(func(k: LazilyCompute) -> void:
		observed.append(id)
		effect_runs[id] = int(effect_runs.get(id, 0)) + 1
		var total := 0
		for r: String in reads:
			total += _as_int(k.read(cells[r]))
		if merges_into != "":
			# The FEED: read the upstream (the edge belongs to this effect), then
			# fold the sum into the accumulator. The counter ticks inside the
			# body, so it moves only when the runtime actually folds — ticking at
			# the call site would report this runner's intent rather than the
			# kernel's behaviour, and that is the single thing these fixtures
			# discriminate on.
			var acc := cells[merges_into] as LazilySource
			merges[merges_into] = int(merges.get(merges_into, 0)) + 1
			acc.merge(total)
		if writes_own_cone != "" and established[0]:
			# Deliberate feedback: writing a cell this body reads. The contract
			# is that the drain reports exhaustion, not that it settles.
			var target := cells[writes_own_cone] as LazilySource
			target.set_value(_as_int(target.peek()) + 1)
		established[0] = true)
	effects[id] = e
	_remember_handle(id, e)
	effect_scope_of[id] = sc
	_record_teardown_of(owner, id, e)


## Teardown order is observed through the scope's member list, so the member
## slot is wrapped with a recorder rather than trusting a separate list — a
## parallel list records the order the runner INTENDED, not the one the scope
## actually ran.
func _record_teardown_of(owner: LazilyScope, id: String, inner: LazilyCell) -> void:
	var members := owner._members
	members[members.size() - 1] = _CleanupRecorder.new(cleanup_order, id, inner)


## How many times the named effect has run, across the whole scenario.
##
## `observed` is per-step by design (it answers "ran because of THIS step"), so
## the cumulative count needs its own ledger.
func _effect_runs(id: String) -> int:
	return int(effect_runs.get(id, 0))


func _check(expect: Dictionary, op: Dictionary, i: int) -> void:
	for key: String in expect:
		match key:
			"note":
				continue
			"value":
				# A feed effect's step asserts `value` on the cell it FEEDS, not
				# on the effect — an effect has no value. The corpus names the
				# target in `merges_into`, so that is what the read resolves to.
				var value_id: String = op.get("merges_into", op.get("id", ""))
				var cell: Variant = cells.get(value_id)
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
			"observed_count":
				# The bulk twin of `observed_by`: a fanout's members are named by
				# position, so a fixture that publishes to hundreds of them
				# asserts HOW MANY reacted rather than which. This is the
				# assertion that makes a dependent-set leak visible as work —
				# the degree assertions alone can be satisfied by a binding that
				# counts edges correctly and still walks a stale list on publish.
				var want_n := int(expect["observed_count"])
				if observed.size() != want_n:
					_fail(i, "expect.observed_count %d, got %d (%s)"
						% [want_n, observed.size(), observed])
				observed = []
			"merges_of":
				var want_m: Dictionary = expect["merges_of"]
				for mcid: String in want_m.keys():
					if not merges.has(mcid):
						_fail(i, "expect.merges_of names '%s', which is not a merge cell" % mcid)
						continue
					var got_m: int = merges[mcid]
					if got_m != int(want_m[mcid]):
						_fail(i, "expect.merges_of['%s'] %s, got %d"
							% [mcid, str(want_m[mcid]), got_m])
			"computes_of":
				# Cumulative, never reset between steps: the fixtures assert a running
				# total, and resetting would turn "recomputed twice" into "recomputed
				# once" at every checkpoint.
				var want_c: Dictionary = expect["computes_of"]
				for ccid: String in want_c:
					if not cells.has(ccid) and not effects.has(ccid):
						_fail(i, "expect.computes_of names unknown node '%s'" % ccid)
						continue
					# On a derived cell this is the compute counter; on an EFFECT
					# — `merge_folds_synchronously_in_batch`'s `watch` is an
					# observer of the accumulator — the "computes" are its runs,
					# already recorded by name in the run ledger. Counting there
					# needs no second counter and no change to how effects build.
					var got_c: int = (
						_effect_runs(ccid) if effects.has(ccid) else int(computes.get(ccid, 0))
					)
					if got_c != int(want_c[ccid]):
						_fail(i, "expect.computes_of['%s'] %s, got %d"
							% [ccid, want_c[ccid], got_c])
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
		# A member disposed explicitly already booked itself at the `dispose` op.
		# Booking it again at scope teardown would report a disposal that did not
		# happen here and corrupt the order the fixture compares.
		if _inner.is_disposed():
			super()
			return
		_order.append(_id)
		_inner.dispose()
		super()
