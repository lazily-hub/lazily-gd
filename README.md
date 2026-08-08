# lazily-gd

Pure-GDScript binding of the [lazily](https://github.com/lazily-hub/lazily-spec)
reactive-signals family, shipped as a Godot addon.

> **Status: Phase 0 — scaffold.** The reactive kernel is not implemented yet.
> This repo currently establishes the harness, the engine floor, and CI. It is
> not yet a column in the cross-language coverage matrix, because a column of
> `—` marks would claim a binding that does not exist.

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

## Development

```bash
make check     # installs the pinned gdUnit4, imports, runs the suite
```

See [AGENTS.md](AGENTS.md) for the layout rules, the vacuity guard, and why
orphan-node detection matters to this binding in particular.

## License

MIT — see [LICENSE](LICENSE).
