# lazily-gd

Pure-GDScript binding of the [lazily](https://github.com/lazily-hub/lazily-spec)
reactive-signals family, shipped as a Godot addon.

> **Status: Phase 2 — conformance runner.** The cell kernel is implemented, and
> 9 of the 21 canonical `reactive-graph` fixtures replay against it. Not yet a
> column in the cross-language coverage matrix — see AGENTS.md for the ledger-format
> blocker that has to be resolved first.

## Requirements

**Godot 4.4 or newer.** The floor sits at typed dictionaries
(`Dictionary[K, V]`); below it the addon does not merely lose ergonomics, it
fails to parse. CI pins 4.4.1 so a newer language feature cannot slip in and
break only in a consumer's project.

## Install

Copy `addons/lazily/` into your project's `addons/` directory. That folder is
the entire shipping surface — the tests, the fixture runner, and `project.godot`
in this repo are development scaffolding and are not part of the addon.

## Why GDScript, and not a GDExtension over lazily-cpp

`lazily-cpp` is header-only C++17 and its reactive core is wasm-clean, so a
GDExtension is technically viable. It was rejected anyway, and the blocker is
**consoles**, not web: Switch/PS/Xbox Godot builds come from third-party porting
houses, so you cannot produce those GDExtension binaries yourself. GDScript
ships wherever Godot ships — no binary matrix, no `godot-cpp` pinning, no
per-platform debug/release pairs tracking Godot minor releases.

The design argument points the same way. The wasm-hostile parts of `lazily-cpp`
(`transport.hpp`, `reliable_sync.hpp`) are exactly what a Godot SDK should
replace with Godot's own `WebSocketPeer`, so what you actually want from lazily
here is the layer with zero native dependencies.

## Usage

```gdscript
var ctx := LazilyContext.new()

var celsius := ctx.source(20)
var fahrenheit := ctx.computed(func(k: LazilyCompute) -> float:
	return (k.read(celsius) as float) * 9.0 / 5.0 + 32.0)

# Effects are owned by a scope, never unowned: back-edges in this binding are
# weak, so an unowned Effect would be collected rather than run.
var scope := ctx.scope()
scope.effect(func(k: LazilyCompute) -> void:
	print("%d C = %s F" % [k.read(celsius), k.read(fahrenheit)]))

celsius.set_value(100)          # effect re-runs
ctx.batch(func() -> void:       # many writes, one flush
	celsius.set_value(0))
scope.dispose()                 # tears down members in reverse creation order
```

Reads inside a compute go through `k.read(cell)`, which forms the dependency
edge. `ctx.peek(cell)` reads without forming one. The tracked read is `read()`
rather than `get()` because `Object.get(property)` is a Godot builtin.

## Development

```bash
make check     # installs the pinned gdUnit4, imports, runs the suite
```

See [AGENTS.md](AGENTS.md) for the layout rules, the vacuity guard, and why
orphan-node detection matters to this binding in particular.

## License

MIT — see [LICENSE](LICENSE).
