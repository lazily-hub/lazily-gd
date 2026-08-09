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
]


func test_canonical_corpus_is_present() -> void:
	# A missing sibling checkout must not read as "nothing to replay". Every
	# assertion below reasons about fixtures the run OPENED, so an absent corpus
	# would report OK having examined nothing.
	assert_bool(LazilyFixtureLoader.corpus_available()).override_failure_message(
		"canonical corpus not found at %s — clone the lazily-spec sibling"
		% LazilyFixtureLoader.spec_dir()
	).is_true()


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
		assert_array(fails).override_failure_message(
			"%s did not conform:\n  %s" % [fixture_id, "\n  ".join(fails)]
		).is_empty()
