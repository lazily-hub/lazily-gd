## Typed durable-envelope-v1 client over injected NATS-compatible callables.
## This client observes advisory data and never gains durable-owner authority.
class_name LazilyDurableClient
extends RefCounted

const PROTOCOL_VERSION := 1

class Envelope extends RefCounted:
	var protocol_version: int
	var message_id: String
	var schema_version: int
	var codec_version: int
	var payload: PackedByteArray

	func _init(
		p_message_id: String,
		p_schema_version: int,
		p_codec_version: int,
		p_payload: PackedByteArray,
		p_protocol_version: int = PROTOCOL_VERSION,
	) -> void:
		protocol_version = p_protocol_version
		message_id = p_message_id
		schema_version = p_schema_version
		codec_version = p_codec_version
		payload = p_payload.duplicate()

	func validate() -> String:
		if protocol_version != PROTOCOL_VERSION:
			return "unsupported_protocol_version"
		if message_id.is_empty():
			return "invalid_message_id"
		if schema_version <= 0 or schema_version > 0xffffffff:
			return "invalid_schema_version"
		if codec_version <= 0 or codec_version > 0xffffffff:
			return "invalid_codec_version"
		return "accepted"

	func same_content(other: Envelope) -> bool:
		return protocol_version == other.protocol_version \
			and schema_version == other.schema_version \
			and codec_version == other.codec_version \
			and payload == other.payload

class BrokerPubAck extends RefCounted:
	var stream: String
	var sequence: int
	var duplicate: bool
	func _init(p_stream: String, p_sequence: int, p_duplicate := false) -> void:
		stream = p_stream
		sequence = p_sequence
		duplicate = p_duplicate

class HostReceipt extends RefCounted:
	var protocol_version := PROTOCOL_VERSION
	var receipt_id: String
	var message_id: String
	var outcome: String
	var owner_position: int
	func _init(p_receipt_id: String, p_message_id: String, p_outcome: String, p_owner_position: int) -> void:
		receipt_id = p_receipt_id
		message_id = p_message_id
		outcome = p_outcome
		owner_position = p_owner_position
	func transport_ack_equivalent() -> bool:
		return false

class ProjectionFingerprint extends RefCounted:
	var projection_id: String
	var source_position: int
	var fingerprint: String
	var completeness: String
	func _init(p_projection_id: String, p_source_position: int, p_fingerprint: String, p_completeness := "complete_history") -> void:
		projection_id = p_projection_id
		source_position = p_source_position
		fingerprint = p_fingerprint
		completeness = p_completeness
	func equivalent_to(other: ProjectionFingerprint) -> bool:
		return projection_id == other.projection_id \
			and source_position == other.source_position \
			and fingerprint == other.fingerprint \
			and completeness == other.completeness
	func may_authorize_transition() -> bool:
		return false

class AdvisoryProjectionOrder extends RefCounted:
	var _applied_through := 0
	var _pending: Dictionary[int, String] = {}
	var _applied: Dictionary[int, String] = {}
	var _applied_positions: Array[int] = []
	func observe(source_position: int, fingerprint: String) -> String:
		if _applied.has(source_position):
			return "duplicate" if _applied[source_position] == fingerprint else "conflict"
		if _pending.has(source_position):
			return "duplicate" if _pending[source_position] == fingerprint else "conflict"
		if source_position > _applied_through + 1:
			_pending[source_position] = fingerprint
			return "buffered"
		if source_position <= _applied_through:
			return "conflict"
		_apply_one(source_position, fingerprint)
		while _pending.has(_applied_through + 1):
			var next_position := _applied_through + 1
			var next_fingerprint: String = _pending[next_position]
			_pending.erase(next_position)
			_apply_one(next_position, next_fingerprint)
		return "applied"
	func _apply_one(position: int, fingerprint: String) -> void:
		_applied_through = position
		_applied[position] = fingerprint
		_applied_positions.append(position)
	func applied_positions() -> Array[int]:
		return _applied_positions.duplicate()
	func broker_order_authoritative() -> bool:
		return false
	func may_authorize_transition() -> bool:
		return false

var _publish: Callable
var _subscribe: Callable
var _encode: Callable
var _decode: Callable
var _seen: Dictionary[String, Envelope] = {}
var _observed_message_ids: Array[String] = []

func _init(p_publish: Callable, p_subscribe: Callable, p_encode: Callable, p_decode: Callable) -> void:
	_publish = p_publish
	_subscribe = p_subscribe
	_encode = p_encode
	_decode = p_decode

static func capability_tiers() -> Dictionary[String, bool]:
	return {
		"core": true,
		"client": true,
		"durable_host": false,
		"distributed_host": false,
		"accelerated_host": false,
	}

func publish(subject: String, message_id: String, schema_version: int, codec_version: int, value: Variant) -> BrokerPubAck:
	var bytes: PackedByteArray = _encode.call(value)
	var envelope := Envelope.new(message_id, schema_version, codec_version, bytes)
	assert(envelope.validate() == "accepted", "invalid durable envelope")
	return _publish.call(subject, envelope)

## Validates the envelope before invoking the typed payload decoder.
func decode(envelope: Envelope) -> Dictionary:
	var validation := envelope.validate()
	if validation != "accepted":
		return {"validation": validation, "decoded": false, "value": null}
	_observed_message_ids.append(envelope.message_id)
	var classification := classify(envelope)
	if classification != "first":
		return {
			"validation": validation,
			"decoded": false,
			"classification": classification,
			"value": null,
		}
	return {
		"validation": validation,
		"decoded": true,
		"classification": classification,
		"value": _decode.call(envelope.payload),
	}

func subscribe(subject: String) -> Variant:
	return _subscribe.call(subject, func(envelope: Envelope) -> void: decode(envelope))

func classify(envelope: Envelope) -> String:
	var prior: Envelope = _seen.get(envelope.message_id)
	if prior == null:
		_seen[envelope.message_id] = envelope
		return "first"
	return "duplicate" if prior.same_content(envelope) else "conflict"

func observed_message_ids() -> Array[String]:
	return _observed_message_ids.duplicate()

func owner_order_inferred() -> bool:
	return false

func may_authorize_transition() -> bool:
	return false
