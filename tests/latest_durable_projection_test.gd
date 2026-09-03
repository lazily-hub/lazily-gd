extends GdUnitTestSuite

const FIXTURE_ID := "egress/latest_durable_projection.json"


func test_replays_canonical_fixture_against_core_and_reactive_shell() -> void:
	var fixture := LazilyFixtureLoader.load_fixture(FIXTURE_ID)
	assert_str(fixture.get("kind", "")).is_equal("LatestDurableProjection")
	assert_str(fixture.get("model", "")).is_equal("LatestDurableProjectionCore")
	var scenarios: Array = fixture.get("scenarios", [])
	assert_int(scenarios.size()).is_greater(0)

	var steps_replayed := 0
	for scenario: Dictionary in scenarios:
		var generation := int(scenario["generation"])
		var core := LazilyLatestDurableProjectionCore.new(generation)
		steps_replayed += _replay_scenario(core, true, scenario)

		var ctx := LazilyContext.new()
		var reactive := LazilyLatestDurableProjection.new(ctx, generation)
		steps_replayed += _replay_scenario(reactive, false, scenario)

	assert_int(steps_replayed).is_greater(0)


func test_reactive_reader_advances_once_only_for_state_changes() -> void:
	var ctx := LazilyContext.new()
	var projection := Lazily.latest_durable_projection(ctx, 1)
	assert_int(int(ctx.peek(projection.state_reader()))).is_equal(0)

	assert_dict(projection.upsert_desired("doc", 1, "A")).is_equal({"upsert": "accepted"})
	assert_int(int(ctx.peek(projection.state_reader()))).is_equal(1)
	assert_dict(projection.upsert_desired("doc", 1, "A")).is_equal({"upsert": "unchanged"})
	assert_int(int(ctx.peek(projection.state_reader()))).is_equal(1)
	assert_dict(projection.claim("doc", 1)).contains_key_value("claim", "claimed")
	assert_int(int(ctx.peek(projection.state_reader()))).is_equal(2)
	assert_dict(projection.ack_applied("doc", 0, 1)).is_equal({
		"ack": "stale_generation",
		"current": 1,
	})
	assert_int(int(ctx.peek(projection.state_reader()))).is_equal(2)


func test_empty_commands_do_not_materialize_key_state() -> void:
	var core := LazilyLatestDurableProjectionCore.new(3)
	assert_dict(core.claim("absent", 3)["outcome"]).is_equal({"claim": "empty"})
	assert_dict(core.ack_applied("absent", 3, 1)["outcome"]).is_equal({"ack": "unknown_epoch"})
	assert_dict(core.fail_retryable("absent", 3, 1)["outcome"]).is_equal({"failure": "unknown_epoch"})
	assert_dict(core.snapshot()).is_equal({"generation": 3, "entries": []})


func _replay_scenario(model: RefCounted, core_mode: bool, scenario: Dictionary) -> int:
	var steps: Array = scenario.get("steps", [])
	assert_int(steps.size()).is_greater(0)
	for step: Dictionary in steps:
		var outcome := _invoke(model, core_mode, step["op"])
		assert_dict(outcome).override_failure_message(
			"%s outcome mismatch for %s" % [scenario["id"], step["op"]]
		).is_equal(_normalize_numbers(step["returns"]))
		var actual: Dictionary = model.call("snapshot")
		assert_dict(actual).override_failure_message(
			"%s state mismatch after %s" % [scenario["id"], step["op"]]
		).is_equal(_normalize_numbers(step["expected"]))
	return steps.size()


func _invoke(model: RefCounted, core_mode: bool, op: Dictionary) -> Dictionary:
	var result: Dictionary
	match op["type"]:
		"upsert_desired":
			result = model.call("upsert_desired", op["key"], int(op["epoch"]), op["value"])
		"claim":
			result = model.call("claim", op["key"], int(op["generation"]))
		"ack_applied":
			result = model.call(
				"ack_applied", op["key"], int(op["generation"]), int(op["epoch"])
			)
		"fail_retryable":
			result = model.call(
				"fail_retryable", op["key"], int(op["generation"]), int(op["epoch"])
			)
		"reconnect":
			result = model.call("reconnect", int(op["generation"]))
		_:
			fail("unsupported latest-durable operation: %s" % [op])
			return {}
	if core_mode:
		return result["outcome"]
	return result


## Godot's JSON parser represents every number as float, while the public epoch
## and generation API is intentionally typed int. Normalize whole fixture values
## before strict gdUnit dictionary comparison; this preserves all other types.
func _normalize_numbers(value: Variant) -> Variant:
	match typeof(value):
		TYPE_FLOAT:
			if value == floor(value):
				return int(value)
		TYPE_ARRAY:
			var normalized_array: Array = []
			for item: Variant in value:
				normalized_array.append(_normalize_numbers(item))
			return normalized_array
		TYPE_DICTIONARY:
			var normalized_dictionary := {}
			for key: Variant in value:
				normalized_dictionary[key] = _normalize_numbers(value[key])
			return normalized_dictionary
	return value
