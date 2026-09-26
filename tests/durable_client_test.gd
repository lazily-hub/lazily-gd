extends GdUnitTestSuite

const FIXTURE_ID := "durable-client/envelope_v1.json"

func test_replays_canonical_durable_client_corpus() -> void:
	var fixture := LazilyFixtureLoader.load_fixture(FIXTURE_ID)
	assert_bool(fixture.owner_authority).is_false()
	for vector: Dictionary in fixture.envelope_vectors:
		var envelope := _from_wire(vector.envelope)
		LazilyBlockLedger.bind(vector.expected)
		assert_str(envelope.validate()).is_equal(vector.expected.reason)
		assert_bool(envelope.validate() == "accepted").is_equal(vector.expected.accepted)
		assert_bool(envelope.validate() == "accepted").is_equal(vector.expected.payload_decoded)
	for vector: Dictionary in fixture.ordering_vectors:
		var client := _client()
		for message_id: String in vector.observed_message_ids:
			client.decode(LazilyDurableClient.Envelope.new(message_id, 1, 1, PackedByteArray()))
		assert_array(client.observed_message_ids()).is_equal(vector.expected_delivery_order)
		assert_bool(client.owner_order_inferred()).is_equal(vector.owner_order_inferred)
	for vector: Dictionary in fixture.projection_ordering_vectors:
		var order := LazilyDurableClient.AdvisoryProjectionOrder.new()
		var classifications: Array[String] = []
		for position: int in vector.observed_source_positions:
			var classification := order.observe(position, "source-%d" % position)
			classifications.append(classification)
		assert_array(classifications).is_equal(vector.expected_delivery_classification)
		var expected_positions: Array[int] = []
		for position: float in vector.expected_applied_positions:
			expected_positions.append(int(position))
		assert_array(order.applied_positions()).is_equal(expected_positions)
		assert_bool(order.broker_order_authoritative()).is_equal(vector.broker_order_authoritative)
		assert_bool(order.may_authorize_transition()).is_equal(vector.may_authorize_transition)
	for vector: Dictionary in fixture.dedup_vectors:
		var client := _client()
		var classifications: Array[String] = []
		for delivery: Dictionary in vector.deliveries:
			var classification := client.classify(_from_wire(delivery))
			classifications.append(classification)
		assert_array(classifications).is_equal(vector.expected_classification)
	for vector: Dictionary in fixture.receipt_vectors:
		var receipt := _receipt(vector.receipt)
		var expected := _receipt(vector.expected_round_trip)
		assert_str(receipt.receipt_id).is_equal(expected.receipt_id)
		assert_str(receipt.message_id).is_equal(expected.message_id)
		assert_str(receipt.outcome).is_equal(expected.outcome)
		assert_int(receipt.owner_position).is_equal(expected.owner_position)
		assert_bool(receipt.transport_ack_equivalent()).is_equal(vector.transport_ack_equivalent)
	for vector: Dictionary in fixture.projection_fingerprint_vectors:
		var left := _fingerprint(vector.left)
		var right := _fingerprint(vector.right)
		LazilyBlockLedger.bind(vector.expected)
		assert_bool(left.source_position == right.source_position).is_equal(vector.expected.same_source)
		assert_bool(left.fingerprint == right.fingerprint).is_equal(vector.expected.same_fingerprint)
		assert_bool(left.completeness == right.completeness).is_equal(vector.expected.same_completeness)
		assert_bool(left.equivalent_to(right)).is_equal(vector.expected.equivalent)
		assert_bool(left.may_authorize_transition()).is_false()

func test_envelope_order_dedup_receipt_fingerprint_and_tiers() -> void:
	var tiers := LazilyDurableClient.capability_tiers()
	assert_bool(tiers.core and tiers.client).is_true()
	assert_bool(tiers.durable_host or tiers.distributed_host or tiers.accelerated_host).is_false()
	var first := _envelope(PackedByteArray([65]))
	assert_str(first.validate()).is_equal("accepted")
	assert_str(_envelope(PackedByteArray([255]), 2).validate()).is_equal("unsupported_protocol_version")

	var client := _client()
	assert_str(client.classify(first)).is_equal("first")
	assert_str(client.classify(_envelope(PackedByteArray([65])))).is_equal("duplicate")
	assert_str(client.classify(_envelope(PackedByteArray([66])))).is_equal("conflict")

	var receipt := LazilyDurableClient.HostReceipt.new("receipt-1", first.message_id, "committed", 42)
	assert_bool(receipt.transport_ack_equivalent()).is_false()
	var left := LazilyDurableClient.ProjectionFingerprint.new("orders", 42, "aabbccdd")
	assert_bool(left.equivalent_to(LazilyDurableClient.ProjectionFingerprint.new("orders", 42, "aabbccdd"))).is_true()
	assert_bool(left.equivalent_to(LazilyDurableClient.ProjectionFingerprint.new("orders", 41, "aabbccdd"))).is_false()
	assert_bool(left.equivalent_to(LazilyDurableClient.ProjectionFingerprint.new("orders", 42, "aabbccdd", "latest_state_only"))).is_false()
	assert_bool(left.may_authorize_transition()).is_false()
	var projections := LazilyDurableClient.AdvisoryProjectionOrder.new()
	assert_str(projections.observe(2, "two")).is_equal("buffered")
	assert_str(projections.observe(1, "one")).is_equal("applied")
	assert_str(projections.observe(2, "two")).is_equal("duplicate")
	assert_array(projections.applied_positions()).is_equal([1, 2])
	assert_bool(projections.broker_order_authoritative()).is_false()
	assert_bool(projections.may_authorize_transition()).is_false()

func test_unknown_protocol_fails_before_decode_and_puback_is_separate() -> void:
	var decoded := [false]
	var client := LazilyDurableClient.new(
		func(_subject: String, _envelope: LazilyDurableClient.Envelope) -> LazilyDurableClient.BrokerPubAck:
			return LazilyDurableClient.BrokerPubAck.new("OWNER", 9),
		func(_subject: String, _handler: Callable) -> Variant: return null,
		func(value: String) -> PackedByteArray: return value.to_utf8_buffer(),
		func(bytes: PackedByteArray) -> String:
			decoded[0] = true
			return bytes.get_string_from_utf8(),
	)
	var result := client.decode(_envelope(PackedByteArray([255]), 2))
	assert_str(result.validation).is_equal("unsupported_protocol_version")
	assert_bool(decoded[0]).is_false()
	var ack := client.publish("owners.commands", "message-1", 7, 11, "go")
	assert_int(ack.sequence).is_equal(9)
	assert_bool(client.may_authorize_transition()).is_false()

func _client() -> LazilyDurableClient:
	return LazilyDurableClient.new(
		func(_subject: String, _envelope: LazilyDurableClient.Envelope) -> LazilyDurableClient.BrokerPubAck:
			return LazilyDurableClient.BrokerPubAck.new("OWNER", 9),
		func(_subject: String, _handler: Callable) -> Variant: return null,
		func(value: String) -> PackedByteArray: return value.to_utf8_buffer(),
		func(bytes: PackedByteArray) -> String: return bytes.get_string_from_utf8(),
	)

func _envelope(payload: PackedByteArray, protocol := 1) -> LazilyDurableClient.Envelope:
	return LazilyDurableClient.Envelope.new("sample-owner/message-4", 7, 11, payload, protocol)

func _from_wire(value: Dictionary) -> LazilyDurableClient.Envelope:
	return LazilyDurableClient.Envelope.new(
		value.message_id,
		int(value.schema_version),
		int(value.codec_version),
		PackedByteArray(value.payload),
		int(value.protocol_version),
	)

func _receipt(value: Dictionary) -> LazilyDurableClient.HostReceipt:
	return LazilyDurableClient.HostReceipt.new(
		value.receipt_id, value.message_id, value.outcome, int(value.owner_position)
	)

func _fingerprint(value: Dictionary) -> LazilyDurableClient.ProjectionFingerprint:
	return LazilyDurableClient.ProjectionFingerprint.new(
		value.projection_id, int(value.source_position), value.fingerprint, value.completeness
	)
