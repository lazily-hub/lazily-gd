## Replays the canonical ReactiveGraph fixtures this binding claims.
##
## The list below is what `coverage.json` will be allowed to claim. Every other
## canonical fixture is named in `scripts/check-conformance-coverage.sh` under
## KNOWN_UNCOVERED with a reason, so "not replayed" is always visible somewhere
## rather than merely absent.
extends GdUnitTestSuite

## Fixtures whose ops the Phase 1 kernel vocabulary covers in full.
const REPLAYED := [
	"reactive-graph/transitive_invalidation_reaches_depth.json",
	"reactive-graph/teardown_runs_members_in_reverse_creation_order.json",
	"reactive-graph/dispose_detaches_edges_both_directions.json",
	"reactive-graph/disposal_does_not_run_surviving_effects.json",
	"reactive-graph/disarm_disposes_nothing.json",
	"reactive-graph/cross_scope_teardown_hazard.json",
	"reactive-graph/scoping_bounds_teardown_not_visibility.json",
	"reactive-graph/read_after_dispose_is_an_error.json",
	"reactive-graph/feedback_drain_bound_reports_exhaustion.json",
	# `signal` / `dispose_signal`: an eager `Computed` plus its puller.
	"reactive-graph/signal_materializes_without_a_read.json",
	"reactive-graph/signal_materializes_once_per_batch.json",
	"reactive-graph/dispose_signal_reverts_to_lazy.json",
	# `fail_next`: an injected compute failure, to pin that it is never cached.
	"reactive-graph/failed_compute_is_never_cached.json",
	# shape=scenarios: several independent runs in one fixture.
	"reactive-graph/scope_teardown_equals_fold_of_disposals.json",
	# `merge_cell` / `merges_into`: a source cell folding under a policy, fed by
	# an effect that owns the edge. The accumulator acquires none.
	"reactive-graph/merge_cell_acquires_no_dependency_edge.json",
	"reactive-graph/merge_folds_synchronously_in_batch.json",
	"reactive-graph/merge_per_settled_cone_not_per_write.json",
	"reactive-graph/merge_feed_through_a_formula_coalesces.json",
	"reactive-graph/exact_fold_paths_stay_exact.json",
	# `fanout` / `churn` / `dispose_fanout` / `dispose_stale_handle`: bulk
	# subscribe-unsubscribe vocabulary, plus disposal through a handle whose node
	# is already gone.
	"reactive-graph/churn_returns_to_baseline.json",
	"reactive-graph/recycled_id_inherits_nothing.json",
]


func test_canonical_corpus_is_present() -> void:
	# A missing sibling checkout must not read as "nothing to replay". Every
	# assertion below reasons about fixtures the run OPENED, so an absent corpus
	# would report OK having examined nothing.
	assert_bool(LazilyFixtureLoader.corpus_available()).override_failure_message(
		"canonical corpus not found at %s — clone the lazily-spec sibling"
		% LazilyFixtureLoader.spec_dir()
	).is_true()


## Scenario isolation, asserted directly.
##
## `scope_teardown_equals_fold_of_disposals.json` does NOT discriminate this:
## both of its scenarios define the same ids, so a runner that leaked state
## between them overwrites the stale entries and still passes. That was measured,
## not assumed — deleting the per-scenario reset leaves the canonical fixture
## green. So the isolation gets its own assertion, on a synthetic input, rather
## than an unverified belief that the corpus covers it.
##
## Synthetic input is appropriate HERE and nowhere else in this file: it tests
## the runner's own bookkeeping, not a normative expectation. Restating a
## canonical expectation in GDScript is the drift this suite exists to avoid.
func test_scenarios_do_not_share_state() -> void:
	var fixture := {
		"kind": "ReactiveGraph",
		"shape": "scenarios",
		"scenarios": [
			{"id": "defines", "steps": [{"op": {"type": "cell", "id": "x", "value": 1}}]},
			{"id": "must_not_see_it", "steps": [{"op": {"type": "read", "id": "x"}}]},
		],
	}
	var runner := LazilyReactiveGraphRunner.new()
	var fails := runner.run(fixture)
	assert_array(runner.scenarios_replayed).is_equal(["defines", "must_not_see_it"])
	# The second scenario must not see the first scenario's cell.
	assert_int(fails.size()).override_failure_message(
		"a scenario saw a cell defined by an earlier scenario: %s" % [fails]
	).is_equal(1)
	assert_str(fails[0]).contains("must_not_see_it")
	assert_str(fails[0]).contains("unknown cell 'x'")


## The runner must refuse a shape it does not model (#lzledgeragreementaudit).
##
## Runner bookkeeping again, so synthetic input is right here for the same reason
## as above. The dispatch used to read `shape` with a `"steps"` default and fall
## through for every other value, so a fixture whose steps moved under a new key
## replayed an empty list: no ops, no failures, green — while both ledgers still
## agreed, because the fixture is named in REPLAYED and absent from
## KNOWN_UNCOVERED. Two ledgers agreeing about a run that proved nothing is the
## same vacuous green the manifest guard exists to prevent, one rung up.
func test_unknown_shape_fails_closed() -> void:
	var runner := LazilyReactiveGraphRunner.new()
	var fails := runner.run({"kind": "ReactiveGraph", "shape": "table", "rows": []})
	assert_int(fails.size()).override_failure_message(
		"an unmodelled shape replayed as `steps` instead of failing: %s" % [fails]
	).is_equal(1)
	assert_str(fails[0]).contains("unsupported fixture shape 'table'")

	# A missing `shape` is drift, not a default: every canonical reactive-graph
	# fixture declares one.
	var absent := LazilyReactiveGraphRunner.new()
	assert_str(absent.run({"kind": "ReactiveGraph", "steps": []})[0]).contains(
		"unsupported fixture shape ''"
	)

	# And the declared-but-empty twin of the `scenarios` rung: a fixture that
	# replays nothing must not report conformance.
	var empty := LazilyReactiveGraphRunner.new()
	assert_str(empty.run({"kind": "ReactiveGraph", "shape": "steps", "steps": []})[0]).contains(
		"replaying nothing must not report conformance"
	)


func test_replays_every_claimed_fixture() -> void:
	assert_int(REPLAYED.size()).is_greater(0)
	for fixture_id: String in REPLAYED:
		var fixture := LazilyFixtureLoader.load_fixture(fixture_id)
		assert_dict(fixture).override_failure_message(
			"fixture %s failed to load" % fixture_id
		).is_not_empty()
		assert_str(fixture.get("kind", "")).override_failure_message(
			"fixture %s is not a ReactiveGraph fixture" % fixture_id
		).is_equal("ReactiveGraph")

		var runner := LazilyReactiveGraphRunner.new()
		var fails := runner.run(fixture)

		# Declared-vs-replayed, for the fixtures that carry several independent
		# runs. A skipped scenario raises no failure of its own, so without this
		# a runner that replayed one of two would report the fixture conformant.
		if fixture.get("shape", "steps") == "scenarios":
			var declared: Array[String] = []
			for sc: Dictionary in fixture.get("scenarios", []):
				declared.append(str(sc.get("id", sc.get("name", ""))))
			assert_array(runner.scenarios_replayed).override_failure_message(
				"%s declares scenarios %s but replayed %s"
				% [fixture_id, declared, runner.scenarios_replayed]
			).is_equal(declared)
		assert_array(fails).override_failure_message(
			"%s did not conform:\n  %s" % [fixture_id, "\n  ".join(fails)]
		).is_empty()
