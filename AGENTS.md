# lazily-gd

Pure-GDScript binding of the lazily reactive-signals family, shipped as a Godot
addon. The reactive kernel is a port of the reference semantics, not an
independent design: when this repo and
[lazily-spec](https://github.com/lazily-hub/lazily-spec) disagree, the spec wins
and this repo is the finding.

**Status: Phase 2 (conformance runner).** The cell kernel is implemented under
`addons/lazily/cell/`, and the conformance runner replays **all 21 canonical
`reactive-graph` fixtures**. `KNOWN_UNCOVERED` is empty — every fixture in the
one family this binding claims is replayed, not excused.

`GDScript` is the 10th column in `lazily-spec/coverage.json`. The detail row
`reactive-graph` is `✅`; the Reactive-graph FAMILY roll-up stays `~`, because
that family also holds `thread-safe-context` and `async-reactive-context` (`—`,
no threads or async context here) and `merge-algebra` (`~`, whose sixth citation
is `collections/mergecell_algebra.json` — outside
`IMPLEMENTED_FAMILY_PREFIXES`). All 28 other families are `—`. Partial, and
visibly so.

Promoting that mark was not optional bookkeeping. `check-coverage-claims.mjs`
fails a `~` that its ledger cannot distinguish from `✅`, so emptying
`KNOWN_UNCOVERED` and leaving the mark alone is a hard error
(`#lzpartialmarkadjudicate`) — the ledger and the matrix move in the same change
or not at all.

**The ledger format had to be fixed before the column could exist**, and the
reason is worth keeping. `check-coverage-claims.mjs` reads each binding's
`KNOWN_UNCOVERED` and treats *absence from it* as "replayed". This repo's guard
excuses 128 fixtures by unimplemented FAMILY instead of naming each one, so to
that parser lazily-gd read as "audits the whole corpus, declares 12 gaps" — and
all 128 family-excused fixtures counted as replayed. It was demonstrated, not
assumed: a `✅` on a `codec/` row passed the guard before the fix and fails after
it. `IMPLEMENTED_FAMILY_PREFIXES` is now read spec-side alongside
`REQUIRED_AREAS`, and an *unrecognized* array in this file is a hard failure
there, so the next binding that invents a third narrowing mechanism cannot have
it silently ignored. Renaming or removing `IMPLEMENTED_FAMILY_PREFIXES` here is a
cross-repo change: classify the replacement in `check-coverage-claims.mjs` in the
same breath.

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

## Kernel invariants (do not regress these)

- **No ambient context.** The ctx is threaded explicitly; there is no "current
  context" global and no current-node stack. Dependency attribution comes from
  the `LazilyCompute` view threaded into each recompute, so a read cannot miss
  tracking and an untracked read cannot silently gain it.
- **No observers — only Effects.** Never add a subscribe / listener / callback
  registry to a reactive type. An observer registry is a second edge set that
  survives invalidation, which is what the edge index exists to prevent.
- **Back-edges are weak, forward edges strong**, and `LazilyScope` is the sole
  strong owner of Effects. `ctx.effect()` therefore refuses: an unowned Effect
  would be collected rather than run, failing silently. Use `ctx.scope().effect()`.
- **Prune before any edge-count read.** GDScript has no finalizer hook, so dead
  `WeakRef`s are pruned in `_live_dependents()`. Counting without pruning reads
  edges high — route every count through `dependent_count()`.
- **Invalidation is transitive, never one level.** A one-level mark plus a
  cache-trusting read drops writes at depth 2. `test_deepest_read_alone_is_fresh`
  is the assertion that catches it; the other depth test can mask the defect by
  refreshing the chain on its way down.
- **The tracked read is `read()`, not `get()`.** `Object.get(property)` is a
  Godot builtin and shadowing it would break `obj.get("prop")` for consumers.

## The conformance runner

`tests/conformance/` replays canonical fixtures from `../lazily-spec/conformance`
by interpreting their own `steps`/`expect` data. It does **not** restate the
expectations in GDScript: a hand-transcribed expectation is a second source of
truth that drifts from the corpus silently.

`fixture_loader.gd` records every fixture it opens into
`LAZILY_CONFORMANCE_MANIFEST` at the moment it opens it, and
`scripts/check-conformance-coverage.sh` reads that RUNTIME manifest. A fixture
named in a comment, or transcribed into a test, is present in a grep while never
being replayed — lazily-cpp's queue tests drifted exactly that way. Observing the
read is the only proof.

The guard states which families this binding **implements** rather than listing
what it does not. An exclusion list needs editing every time the corpus grows,
and the edit that never happens is the one that turns a gap green. A new family
is excused automatically; a new `reactive-graph/` fixture fails until replayed or
named in `KNOWN_UNCOVERED` with a reason.

Re-drive it after changing the runner. Proven branches: empty manifest fails as
missing evidence, a manifest entry naming no real file fails as a corrupt
evidence channel, and dropping a replayed fixture fails as unexcused. Also
perturb the kernel — making invalidation one-level-only must redden
`transitive_invalidation_reaches_depth` at depth 2 and beyond. A replay that
survives that perturbation is not replaying anything.

### The bulk vocabulary, and what it actually pins here

`fanout` / `churn` / `dispose_fanout` / `dispose_stale_handle` build subscribers
as **Effects, not derived cells**. `churn_returns_to_baseline` asserts
`observed_count` on a publish, and in a lazy binding only a sink observes a
publish without being pulled — a `Computed` subscriber satisfies every degree
assertion in both fixtures while the propagation assertion reads 0, which is the
leak-as-work half going quietly missing.

Both fixtures were measured against kernel mutations rather than assumed live:

- `Effect._detach()` made a no-op → `churn_returns_to_baseline` reports 508 and
  509 dependents against a baseline of 8 (the leak the fixture predicts, to the
  count), and `recycled_id_inherits_nothing` reports 64 where it wants 0.
- `Computed._detach()` made a no-op → `recycled_id_inherits_nothing` reddens
  alongside four already-replayed fixtures.

`dispose_stale_handle` is a different case and worth stating plainly: it is
**structurally satisfied** here, not discriminating. Handles in this binding are
`RefCounted` references, which is one of the two outs the fixture's own note
names, so disposal through a stale one cannot reach an unrelated node. The
runner still CHECKS the declared `handle_kind` against the handle it recorded, so
a runner that quietly disposed something else is caught.

The same goes for the "recycled id" half. Godot's ObjectDB is a free list over
slots with a generation tag — measured in
`test_instance_ids_are_generational_not_monotonic`, which also corrects the usual
"ids are monotonic" phrasing — but the reason the fixture's aliasing hazard
cannot arise is simpler and outranks it: the edge index lives INSIDE the node, so
there is no owner-keyed side table to alias. Keying `_dependents` on the slot
alone (`id & 0xFFFFFFFF`) was tried and leaves the suite green.

**Resolve the corpus root through `LazilyFixtureLoader.spec_dir()`, never by
spelling `../lazily-spec/conformance` in a runner.** A hardcoded root ignores
`LAZILY_SPEC_CONFORMANCE_DIR`, so the replay reads the REAL corpus while a
perturbation probe believes it redirected it — and is green either way, which is
why nothing reports it. lazily-zig carried fourteen such sites: truncating
fourteen fixtures reddened zero tests before the fix and 26 after. lazily-gd
measured clean, and the first rung of `check-conformance-coverage.sh` keeps it
that way. It folds `path_join`/`+` concatenations before looking, because
lazily-go's and lazily-js's grep-shaped versions were both proven evadable by
splitting the root across two literals. Comments are skipped by design;
`fixture_loader.gd` is the one allowlisted file, since it defines the default.

## The load-graph check

`make load-graph` runs `scripts/load_graph_check.gd` as **its own headless Godot
process** and asserts that loading the cell kernel loads no other family. The
isolation is load-bearing: inside the suite process everything is already
resident, so the measurement would answer about the harness rather than the
kernel.

It measures rather than reads. `ResourceLoader.get_dependencies()` returns `[]`
for GDScript — it models `.import`-style resource deps, not `class_name` /
`extends` / `preload` edges — and scanning source for `preload(` proves only what
is written. This observes what the engine actually resolved, via
`ResourceLoader.has_cached()`.

It refuses to pass vacuously: if nothing outside `KERNEL_CLOSURE` exists to
assert against, it fails rather than reporting OK over an empty set. Re-drive it
after touching the kernel's imports by adding a cross-family `preload()` and
confirming it fails.

`preload()` is eager and transitive, which is why this lands in Phase 1 rather
than late — retrofitting layering after six families exist is the expensive order.

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
