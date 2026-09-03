## Latest-value durable projection authority (`#lzlatestdurableprojection`).
##
## Contract: lazily-spec v0.38.0,
## `conformance/egress/latest_durable_projection.json`.
## Corrected formal model: lazily-formal v0.38.1,
## `LazilyFormal.LatestDurableProjection`.
class_name LazilyLatestDurableProjectionCore
extends RefCounted

var _generation: int
var _entries: Dictionary = {}


func _init(generation: int) -> void:
	_generation = generation


func generation() -> int:
	return _generation


func count() -> int:
	return _entries.size()


func _entry(key: Variant) -> Dictionary:
	if not _entries.has(key):
		_entries[key] = {
			"desired": null,
			"inflight": null,
			"durable_through": null,
		}
	return _entries[key]


func state(key: Variant) -> Variant:
	if not _entries.has(key):
		return null
	return (_entries[key] as Dictionary).duplicate(true)


func pending(key: Variant) -> bool:
	if not _entries.has(key):
		return false
	var item: Dictionary = _entries[key]
	return item["inflight"] == null and item["desired"] != null


## Complete observable state. Entries are sorted by their string keys so the
## canonical trace and diagnostic output remain deterministic.
func snapshot() -> Dictionary:
	var keys := _entries.keys()
	keys.sort_custom(func(left: Variant, right: Variant) -> bool: return str(left) < str(right))
	var projected: Array[Dictionary] = []
	for key: Variant in keys:
		var item: Dictionary = (_entries[key] as Dictionary).duplicate(true)
		item["key"] = key
		projected.append(item)
	return {"generation": _generation, "entries": projected}


func upsert_desired(key: Variant, epoch: int, value: Variant) -> Dictionary:
	var item := _entry(key)
	var durable: Variant = item["durable_through"]
	if durable != null and epoch <= int(durable):
		return _transition(false, {"upsert": "already_durable", "durable_through": durable})

	var newest: Variant = item["desired"]
	var inflight: Variant = item["inflight"]
	if inflight != null and (newest == null or int(inflight["epoch"]) > int(newest["epoch"])):
		newest = inflight
	if newest != null:
		var current := int(newest["epoch"])
		if epoch < current:
			return _transition(false, {"upsert": "stale_epoch", "current": current})
		if epoch == current:
			if value == newest["value"]:
				return _transition(false, {"upsert": "unchanged"})
			return _transition(false, {"upsert": "epoch_conflict"})

	item["desired"] = {"epoch": epoch, "value": value}
	return _transition(true, {"upsert": "accepted"})


func claim(key: Variant, actor_generation: int) -> Dictionary:
	if actor_generation != _generation:
		return _transition(false, {"claim": "stale_generation", "current": _generation})
	if not _entries.has(key):
		return _transition(false, {"claim": "empty"})
	var item: Dictionary = _entries[key]
	if item["inflight"] != null:
		return _transition(false, {"claim": "busy"})
	var desired: Variant = item["desired"]
	if desired == null:
		return _transition(false, {"claim": "empty"})
	var envelope := {
		"generation": _generation,
		"key": key,
		"epoch": desired["epoch"],
		"value": desired["value"],
	}
	item["desired"] = null
	item["inflight"] = envelope
	return _transition(true, {"claim": "claimed", "envelope": envelope.duplicate(true)})


func ack_applied(key: Variant, actor_generation: int, epoch: int) -> Dictionary:
	if actor_generation != _generation:
		return _transition(false, {"ack": "stale_generation", "current": _generation})
	if not _entries.has(key):
		return _transition(false, {"ack": "unknown_epoch"})
	var item: Dictionary = _entries[key]
	var inflight: Variant = item["inflight"]
	if inflight == null or int(inflight["epoch"]) != epoch:
		var durable: Variant = item["durable_through"]
		if durable != null and epoch <= int(durable):
			return _transition(false, {"ack": "unchanged", "durable_through": durable})
		return _transition(false, {"ack": "unknown_epoch"})

	item["inflight"] = null
	var durable: Variant = item["durable_through"]
	if durable == null or epoch > int(durable):
		item["durable_through"] = epoch
		return _transition(true, {"ack": "advanced", "durable_through": epoch})
	return _transition(true, {"ack": "unchanged", "durable_through": durable})


func fail_retryable(key: Variant, actor_generation: int, epoch: int) -> Dictionary:
	if actor_generation != _generation:
		return _transition(false, {"failure": "stale_generation", "current": _generation})
	if not _entries.has(key):
		return _transition(false, {"failure": "unknown_epoch"})
	var item: Dictionary = _entries[key]
	var inflight: Variant = item["inflight"]
	if inflight == null or int(inflight["epoch"]) != epoch:
		return _transition(false, {"failure": "unknown_epoch"})

	item["inflight"] = null
	var desired: Variant = item["desired"]
	if desired != null and int(desired["epoch"]) > int(inflight["epoch"]):
		return _transition(true, {"failure": "superseded"})
	item["desired"] = {"epoch": inflight["epoch"], "value": inflight["value"]}
	return _transition(true, {"failure": "pending"})


func reconnect(new_generation: int) -> Dictionary:
	if new_generation < _generation:
		return _transition(false, {"reconnect": "stale_generation", "current": _generation})
	if new_generation == _generation:
		return _transition(false, {"reconnect": "unchanged", "generation": _generation})

	var requeued := 0
	var superseded := 0
	for item: Dictionary in _entries.values():
		var inflight: Variant = item["inflight"]
		if inflight == null:
			continue
		var desired: Variant = item["desired"]
		if desired != null and int(desired["epoch"]) > int(inflight["epoch"]):
			superseded += 1
		else:
			item["desired"] = {"epoch": inflight["epoch"], "value": inflight["value"]}
			requeued += 1
		item["inflight"] = null
	_generation = new_generation
	return _transition(true, {
		"reconnect": "advanced",
		"generation": new_generation,
		"requeued": requeued,
		"superseded": superseded,
	})


func _transition(changed: bool, outcome: Dictionary) -> Dictionary:
	return {"change": {"state": changed}, "outcome": outcome}
