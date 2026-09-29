## `lazily` — reactive kernel for Godot, pure GDScript.
##
## The public entry point exposes the engine floor and the currently shipped
## durable helpers. Kernel types are globally named and may also be used
## directly from consumer code.
class_name Lazily
extends RefCounted

## Minimum supported Godot version. 4.4 is where typed dictionaries
## (`Dictionary[K, V]`) landed, which is what the Phase 1 edge index and the
## keyed-collections family are written against. Below this the addon does not
## merely lose ergonomics, it fails to parse.
const MIN_GODOT := Vector3i(4, 4, 0)

## True when the running engine satisfies [constant MIN_GODOT].
##
## Checked by the suite rather than left implicit: a consumer on 4.3 otherwise
## meets this addon as a parse error in a file they did not write.
## Vector3i compares lexicographically (x, then y, then z), which is exactly
## semver ordering here. A future Godot 5 would satisfy this and should not —
## but that is a re-evaluation, not a silent clamp, so it is left to fail loudly
## against a real engine rather than guessed at now.
static func engine_supported() -> bool:
	var info := Engine.get_version_info()
	var running := Vector3i(info["major"], info["minor"], info["patch"])
	return running >= MIN_GODOT


## Construct a graph-backed latest-value durable projection.
static func latest_durable_projection(
	ctx: LazilyContext,
	generation: int,
) -> LazilyLatestDurableProjection:
	return LazilyLatestDurableProjection.new(ctx, generation)


## Construct a typed durable client over host-injected NATS-compatible callables.
static func durable_client(
	publish: Callable,
	subscribe: Callable,
	encode: Callable,
	decode: Callable,
) -> LazilyDurableClient:
	return LazilyDurableClient.new(publish, subscribe, encode, decode)
