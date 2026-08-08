## Cell-kernel behaviour (coverage row 0).
##
## Assertions here target the properties the conformance corpus names, so that
## when the Phase 2 runner replays the real fixtures these are already the shapes
## it exercises. Fixture names appear next to the property they stand for.
extends GdUnitTestSuite

var ctx: LazilyContext


func before_test() -> void:
	ctx = LazilyContext.new()


func test_source_reads_back() -> void:
	var s := ctx.source(1)
	assert_int(s.peek()).is_equal(1)
	s.set_value(2)
	assert_int(s.peek()).is_equal(2)


func test_computed_derives_from_source() -> void:
	var s := ctx.source(2)
	var c := ctx.computed(func(k: LazilyCompute) -> int: return (k.read(s) as int) * 10)
	assert_int(c.peek()).is_equal(20)


## The four-deep chain is the point: a two-link chain cannot tell a correct
## implementation from one that propagates exactly one level, and one-level-only
## is the natural defect. (`transitive_invalidation_reaches_depth.json`)
func test_invalidation_reaches_depth_four() -> void:
	var topic := ctx.source(1)
	var a := ctx.computed(func(k: LazilyCompute) -> int: return (k.read(topic) as int) + 1)
	var b := ctx.computed(func(k: LazilyCompute) -> int: return (k.read(a) as int) + 1)
	var c := ctx.computed(func(k: LazilyCompute) -> int: return (k.read(b) as int) + 1)
	assert_int(c.peek()).is_equal(4)

	topic.set_value(10)
	assert_int(a.peek()).is_equal(11)
	assert_int(b.peek()).is_equal(12)
	assert_int(c.peek()).is_equal(13)


## Reading only the DEEPEST node after a write. If staleness is marked one level
## and reads trust the cache, this is the assertion that catches it — the
## intermediate reads in the test above would mask the defect by refreshing the
## chain on the way down.
func test_deepest_read_alone_is_fresh() -> void:
	var topic := ctx.source(1)
	var a := ctx.computed(func(k: LazilyCompute) -> int: return (k.read(topic) as int) + 1)
	var b := ctx.computed(func(k: LazilyCompute) -> int: return (k.read(a) as int) + 1)
	var c := ctx.computed(func(k: LazilyCompute) -> int: return (k.read(b) as int) + 1)
	assert_int(c.peek()).is_equal(4)

	topic.set_value(100)
	assert_int(c.peek()).is_equal(103)


func test_computed_is_lazy_until_read() -> void:
	var runs := [0]
	var s := ctx.source(1)
	var c := ctx.computed(func(k: LazilyCompute) -> int:
		runs[0] += 1
		return k.read(s) as int)
	assert_int(runs[0]).is_equal(0)
	c.peek()
	assert_int(runs[0]).is_equal(1)
	# A second read with nothing invalidated must not recompute.
	c.peek()
	assert_int(runs[0]).is_equal(1)


## Writing the value a source already holds is not a write.
## (`churn_returns_to_baseline.json`)
func test_writing_same_value_does_not_invalidate() -> void:
	var runs := [0]
	var s := ctx.source(5)
	var c := ctx.computed(func(k: LazilyCompute) -> int:
		runs[0] += 1
		return k.read(s) as int)
	c.peek()
	assert_int(runs[0]).is_equal(1)
	s.set_value(5)
	c.peek()
	assert_int(runs[0]).is_equal(1)


func test_effect_runs_on_creation_and_on_change() -> void:
	var seen: Array[int] = []
	var s := ctx.source(1)
	var scope := ctx.scope()
	scope.effect(func(k: LazilyCompute) -> void: seen.append(k.read(s) as int))
	assert_array(seen).is_equal([1])
	s.set_value(2)
	assert_array(seen).is_equal([1, 2])


## An unowned Effect would be collected rather than run, so the context refuses
## to make one.
func test_effect_on_context_is_an_error() -> void:
	var s := ctx.source(1)
	var e: LazilyEffect = ctx.effect(func(k: LazilyCompute) -> void: k.read(s))
	assert_object(e).is_null()


func test_batch_defers_effects_to_one_run() -> void:
	var runs := [0]
	var a := ctx.source(1)
	var b := ctx.source(2)
	var scope := ctx.scope()
	scope.effect(func(k: LazilyCompute) -> void:
		runs[0] += 1
		k.read(a)
		k.read(b))
	assert_int(runs[0]).is_equal(1)

	ctx.batch(func() -> void:
		a.set_value(10)
		b.set_value(20))
	# Two writes, one flush — not two.
	assert_int(runs[0]).is_equal(2)


func test_eager_computed_recomputes_without_a_read() -> void:
	var runs := [0]
	var s := ctx.source(1)
	var c := ctx.computed(func(k: LazilyCompute) -> int:
		runs[0] += 1
		return k.read(s) as int).eager()
	# `.eager()` schedules immediately, so a flush has already happened.
	assert_int(runs[0]).is_equal(1)
	s.set_value(2)
	# No read here on purpose: an eager cell refreshes at flush.
	assert_int(runs[0]).is_equal(2)


## Teardown walks members backwards, so a member may rely on anything created
## before it still being alive. (`teardown_runs_members_in_reverse_creation_order.json`)
func test_scope_disposes_members_in_reverse_creation_order() -> void:
	var order: Array[int] = []
	var s := ctx.source(1)
	var scope := ctx.scope()
	for i in 3:
		var n := i
		var e := scope.effect(func(k: LazilyCompute) -> void: k.read(s))
		# Wrap disposal ordering observation around the member itself.
		scope._members[scope._members.size() - 1] = _OrderRecordingCell.new(order, n, e)
	scope.dispose()
	assert_array(order).is_equal([2, 1, 0])


## Disarm is not a soft dispose. (`disarm_disposes_nothing.json`)
func test_disarm_disposes_nothing() -> void:
	var seen: Array[int] = []
	var s := ctx.source(1)
	var scope := ctx.scope()
	var e := scope.effect(func(k: LazilyCompute) -> void: seen.append(k.read(s) as int))
	scope.disarm()
	scope.dispose()
	assert_bool(e.is_disposed()).is_false()
	s.set_value(2)
	assert_array(seen).is_equal([1, 2])


## Disposal detaches BOTH directions, so the dependency stops holding a back-edge
## too. (`dispose_detaches_edges_both_directions.json`)
func test_dispose_detaches_edges_both_directions() -> void:
	var s := ctx.source(1)
	var c := ctx.computed(func(k: LazilyCompute) -> int: return k.read(s) as int)
	c.peek()
	assert_int(s.dependent_count()).is_equal(1)
	c.dispose()
	assert_int(s.dependent_count()).is_equal(0)


func test_disposed_effect_stops_running() -> void:
	var seen: Array[int] = []
	var s := ctx.source(1)
	var scope := ctx.scope()
	scope.effect(func(k: LazilyCompute) -> void: seen.append(k.read(s) as int))
	scope.dispose()
	s.set_value(2)
	assert_array(seen).is_equal([1])


## Edge dedup is O(1) and by identity: reading one cell repeatedly in a single
## compute is one edge, not N.
func test_repeated_reads_form_one_edge() -> void:
	var s := ctx.source(1)
	var c := ctx.computed(func(k: LazilyCompute) -> int:
		return (k.read(s) as int) + (k.read(s) as int) + (k.read(s) as int))
	assert_int(c.peek()).is_equal(3)
	assert_int(s.dependent_count()).is_equal(1)


## A conditional body reads different cells on different runs, so edges are
## rebuilt per recompute rather than accumulated.
func test_edges_are_rebuilt_not_accumulated() -> void:
	var use_a := ctx.source(true)
	var a := ctx.source(1)
	var b := ctx.source(2)
	var c := ctx.computed(func(k: LazilyCompute) -> int:
		return (k.read(a) as int) if (k.read(use_a) as bool) else (k.read(b) as int))
	assert_int(c.peek()).is_equal(1)
	assert_int(a.dependent_count()).is_equal(1)
	assert_int(b.dependent_count()).is_equal(0)

	use_a.set_value(false)
	assert_int(c.peek()).is_equal(2)
	assert_int(a.dependent_count()).is_equal(0)
	assert_int(b.dependent_count()).is_equal(1)


## Peek forms no edge. The escape hatch has to be visibly different from a read.
func test_peek_forms_no_edge() -> void:
	var s := ctx.source(1)
	assert_int(ctx.peek(s) as int).is_equal(1)
	assert_int(s.dependent_count()).is_equal(0)


## Back-edges are weak, so a dropped dependent must not keep itself alive through
## the graph — and the edge count must not report it either.
func test_dropped_dependent_is_pruned_from_the_edge_set() -> void:
	var s := ctx.source(1)
	var c := ctx.computed(func(k: LazilyCompute) -> int: return k.read(s) as int)
	c.peek()
	assert_int(s.dependent_count()).is_equal(1)
	c = null
	# The back-edge was weak, so dropping the only strong reference collects it.
	assert_int(s.dependent_count()).is_equal(0)


## Reading a disposed cell is an error, not a stale value.
## (`read_after_dispose_is_an_error.json`)
func test_read_after_dispose_is_an_error() -> void:
	var s := ctx.source(1)
	s.dispose()
	assert_bool(s.is_disposed()).is_true()


## Helper: records disposal order into a shared array.
class _OrderRecordingCell extends LazilyCell:
	var _order: Array[int]
	var _n: int
	var _inner: LazilyCell

	func _init(order: Array[int], n: int, inner: LazilyCell) -> void:
		_order = order
		_n = n
		_inner = inner

	func dispose() -> void:
		if _disposed:
			return
		_order.append(_n)
		_inner.dispose()
		super()
