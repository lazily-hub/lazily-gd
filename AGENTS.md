# lazily-gd

Pure-GDScript binding of the lazily reactive-signals family, shipped as a Godot
addon. The reactive kernel is a port of the reference semantics, not an
independent design: when this repo and
[lazily-spec](https://github.com/lazily-hub/lazily-spec) disagree, the spec wins
and this repo is the finding.

**Status: Phase 0 (scaffold).** The kernel is not implemented yet. This repo
currently proves only that the harness runs and that the engine floor holds. It
is deliberately not a column in `lazily-spec/coverage.json` yet — a column of
`—` marks would claim a binding exists. That lands in Phase 1 alongside coverage
rows 0 and 15.

Staged plan and the reasoning behind every decision below:
`tasks/software/plan-lazily-gd.md` in the agent-loop workspace.

## Minimum Godot version: 4.4

Set at typed dictionaries (`Dictionary[K, V]`), which is what the edge index
keyed on `get_instance_id()` and the keyed-collections family are written
against. **4.5's `@abstract` is therefore not available** — the base kind that
`Source`/`Computed`/`Effect` share is a conventional base class with erroring
stubs, not an abstract one. Do not reach for a 4.5+ feature because the engine
you happen to run supports it; CI pins 4.4.1 precisely so that mistake fails
here rather than in a consumer's project.

## Layout

The **repo root is the addon host**, and `addons/lazily/` is what ships:

- `addons/lazily/` — shipping code. Nothing else goes in a consumer's project.
- `tests/` — the suite. Outside the addon, so installing it ships no tests.
- `project.godot` — exists so `godot --headless` has something to open. It is
  not what ships. Never let `addons/lazily/` read a setting defined here: it
  would work in this repo and break in every consumer project.
- `scripts/install-gdunit4.sh` — installs the pinned test framework into
  `addons/gdUnit4/`, gitignored.

The consumer-facing folder is `addons/lazily/`, not `addons/lazily-gd/` — a
project only ever has one.

## Test framework: gdUnit4, pinned at v5.1.1

**Not the newest release, and the pin is load-bearing.** gdUnit4 v6.x does not
compile on the 4.4 floor: on 4.4.1 it fails to resolve its own classes and then
**hangs instead of exiting**, so CI burns its job limit rather than reporting a
failure. Upstream's compatibility table row listing `v4.3, v4.4, v4.4.1` covers
the **v5.x** line — reading it as "gdUnit4 supports 4.4" and pinning v6 is the
mistake to avoid. Verified both directions: v5.1.1 passes on 4.4.1 (the CI floor)
and on 4.7.1 (a current engine). Raising the Godot floor is what should unlock
v6, not bumping the framework pin on its own.


Chosen over GUT for a reason specific to this binding: gdUnit4 reports **orphan
nodes** per test. This binding's one novel problem is that `RefCounted` has no
cycle collector, so back-edges are `WeakRef` and `ctx.scope()` is the sole strong
owner of effects. Orphan detection turns "teardown actually frees" from an
assertion nobody remembers to write into a property the harness checks on every
test. Treat a nonzero orphan count as a failure, not noise.

## Verification

```bash
make check     # installs gdUnit4 if absent, imports, runs the suite
```

`make check` carries a **vacuity guard**. gdUnit4's CLI exits 0 when it runs zero
test cases — a misnamed directory, a suite that failed to parse, or a bad `-a`
path all produce "OK" over nothing at all. The guard reads the executed-test
count out of the run and fails when it is zero or unreadable, so "no tests ran"
reports as missing EVIDENCE rather than as success. Every binding in this family
has a version of this guard; do not remove it, and re-drive it (point `-a` at an
empty directory) after changing how the suite is invoked.

Both the import and the test run are wrapped in `timeout`. A hang is a distinct
failure mode from a red test and needs its own guard — an incompatible framework
never exits, and an unbounded CI job reports nothing at all.

The import step before the run is not optional: without
`.godot/global_script_class_cache.cfg` every `class_name` fails to resolve,
including gdUnit4's own CLI entrypoint, and the run dies as a parse error that
reads like a broken framework rather than a missing step.

## Commit & Push

Commit and push completed work at the end of every turn that changed code,
tests, docs, or CI.
