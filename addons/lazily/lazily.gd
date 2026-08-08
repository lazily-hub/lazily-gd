## `lazily` — reactive kernel for Godot, pure GDScript.
##
## Phase 0 scaffold. The kernel (`Source` / `Computed` / `Effect` / `Context`)
## lands in Phase 1; this file currently carries only the floor constants that
## the harness and consumers check against.
##
## See `tasks/software/plan-lazily-gd.md` in the agent-loop workspace for the
## staged plan and the decisions behind the Godot floor.
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
