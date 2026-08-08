#!/usr/bin/env bash
# Conformance-coverage guard (#portconformancecoverage), GDScript edition.
#
# Fails when the canonical corpus in ../lazily-spec/conformance/ holds a fixture
# that no test in this repo replays and that is not listed below with a reason.
#
# Reads the RUNTIME manifest, not a source grep. The suite records every fixture
# it actually opens (see tests/conformance/fixture_loader.gd), so a fixture named
# in a comment or hand-transcribed into a test — the drift found in lazily-cpp's
# queue tests — is caught here. A source grep cannot see that case at all:
# `present in a grep` is not proof of replay; only observing the read is.
#
# A missing manifest is missing EVIDENCE and fails. It does not mean "no fixtures
# were read"; it means the suite ran without the recorder attached, and passing
# in that state is the vacuous green this guard exists to prevent.
set -euo pipefail

SPEC_DIR="${LAZILY_SPEC_CONFORMANCE_DIR:-../lazily-spec/conformance}"

# A missing corpus is a legitimate local state (no sibling checkout) and an
# illegitimate CI state (#lzvacuousrun). Skipping under CI is the vacuous green
# this guard exists to prevent: every rung below reasons about fixtures the run
# OPENED, so an absent corpus reports OK over nothing at all.
if [ ! -d "$SPEC_DIR" ]; then
  if [ -n "${CI:-}" ]; then
    echo "ERROR: canonical corpus not found at $SPEC_DIR, and CI is set." >&2
    echo "       Under CI this is missing EVIDENCE, not evidence of absence." >&2
    exit 1
  fi
  echo "SKIP: canonical corpus not found at $SPEC_DIR (clone the lazily-spec sibling)" >&2
  echo "      Local checkout only — this would be a hard failure under CI." >&2
  exit 0
fi

# Fixtures this binding deliberately does not replay YET. Each entry is a claim
# that someone looked; shrinking this list is the work. lazily-gd is a staged
# entry (see tasks/software/plan-lazily-gd.md), so at Phase 2 this is nearly the
# whole corpus — that is honest, not alarming. What matters is that it is
# EXPLICIT: a fixture is either replayed or named here.
#
# Expressed as the families this binding IMPLEMENTS. Everything outside them is
# excused automatically, so the list does not rot as the corpus grows; everything
# inside them must be replayed or named in KNOWN_UNCOVERED with a reason.
#
# CROSS-REPO CONTRACT. lazily-spec's scripts/check-coverage-claims.mjs parses this
# array by name to decide which canonical fixtures this ledger even speaks for.
# Without it, that guard reads "absent from KNOWN_UNCOVERED" as "replayed" and all
# 128 family-excused fixtures count as replayed — a `✅` on any of them passes.
# Renaming this array, or replacing it with a different narrowing mechanism, must
# be classified in that file in the same change. An unrecognized array here is a
# hard failure there, on purpose.
IMPLEMENTED_FAMILY_PREFIXES=(
  "reactive-graph/"
)

# Fixtures in an IMPLEMENTED family that are still not replayed. These are the
# entries that must carry a reason, because their family is one this binding
# claims to support.
KNOWN_UNCOVERED=(
  # merge_cell is the multi-write ingress mechanism; the merge family is not
  # implemented, so these read nothing the kernel can express yet.
  "reactive-graph/exact_fold_paths_stay_exact.json"
  "reactive-graph/merge_cell_acquires_no_dependency_edge.json"
  "reactive-graph/merge_feed_through_a_formula_coalesces.json"
  "reactive-graph/merge_folds_synchronously_in_batch.json"
  "reactive-graph/merge_per_settled_cone_not_per_write.json"
  # `signal` / `dispose_signal` ops: materialization is not in the Phase 1
  # vocabulary.
  "reactive-graph/dispose_signal_reverts_to_lazy.json"
  "reactive-graph/signal_materializes_once_per_batch.json"
  "reactive-graph/signal_materializes_without_a_read.json"
  # `fanout` / `churn` / `dispose_fanout` / `dispose_stale_handle` bulk ops are
  # not implemented; id recycling needs explicit work beyond instance ids.
  "reactive-graph/churn_returns_to_baseline.json"
  "reactive-graph/recycled_id_inherits_nothing.json"
  # `fail_next` needs an injectable compute failure the runner cannot express yet.
  "reactive-graph/failed_compute_is_never_cached.json"
  # shape=scenarios, not shape=steps; the runner replays steps fixtures only.
  "reactive-graph/scope_teardown_equals_fold_of_disposals.json"
)

MANIFEST="${LAZILY_CONFORMANCE_MANIFEST:-build/conformance-fixtures-loaded.txt}"

if [ ! -s "$MANIFEST" ]; then
  echo "FAIL: no conformance manifest at $MANIFEST." >&2
  echo "      Run the suite with LAZILY_CONFORMANCE_MANIFEST set to an ABSOLUTE" >&2
  echo "      path so the recorder attaches (\`make check\` does this). An absent" >&2
  echo "      manifest is missing evidence, not evidence of absence." >&2
  exit 1
fi
OPENED="$(sort -u "$MANIFEST")"

missing=0
total=0
covered=0
excused_family=0
excused_named=0

while IFS= read -r fixture; do
  total=$((total + 1))
  # Here-string, NOT a pipe: with `set -o pipefail`, `printf | grep -q` reports
  # FAILURE when grep matches, because grep exits on the first hit and printf
  # dies of SIGPIPE. The check would then invert and call every covered fixture
  # missing.
  if grep -qxF "$fixture" <<< "$OPENED"; then
    covered=$((covered + 1))
    continue
  fi

  # Excused by family unless the fixture belongs to a family this binding
  # CLAIMS. Stated as what is implemented, not as a list of what is not: an
  # exclusion list has to be edited every time the corpus grows a family, and
  # the edit that never happens is the one that turns a gap green. This way a
  # new family is excused automatically while a new `reactive-graph/` fixture
  # fails — which is the drift that matters while the binding is staged.
  implemented=0
  for prefix in "${IMPLEMENTED_FAMILY_PREFIXES[@]:-}"; do
    case "$fixture" in
      "$prefix"*) implemented=1; break ;;
    esac
  done
  if [ "$implemented" -eq 0 ]; then
    excused_family=$((excused_family + 1))
    continue
  fi

  skip=0

  for known in "${KNOWN_UNCOVERED[@]:-}"; do
    if [ "$known" = "$fixture" ]; then skip=1; break; fi
  done
  if [ "$skip" -eq 1 ]; then
    excused_named=$((excused_named + 1))
    continue
  fi

  echo "ERROR: canonical fixture '$fixture' was NOT opened by the suite." >&2
  echo "       A runner may still name it in source while no longer reading it —" >&2
  echo "       that is the drift this manifest exists to catch. Replay it, or add" >&2
  echo "       it to KNOWN_UNCOVERED with a reason." >&2
  missing=$((missing + 1))
done < <(cd "$SPEC_DIR" && find . -name '*.json' | sed 's|^\./||' | sort)

# The evidence channel guards itself. Every recorded id must resolve against the
# corpus root; otherwise the manifest was truncated or interleaved in transit,
# and coverage computed from it cannot be trusted.
while IFS= read -r id; do
  [ -n "$id" ] || continue
  if [ ! -f "$SPEC_DIR/$id" ]; then
    echo "ERROR: manifest records '$id', which names no file in $SPEC_DIR." >&2
    echo "       The recorder is dropping or interleaving writes; coverage" >&2
    echo "       computed from this manifest cannot be trusted." >&2
    missing=$((missing + 1))
  fi
done <<< "$OPENED"

# A guard that replayed nothing must not report OK. This is the magnitude
# assertion every binding in this family carries.
if [ "$covered" -eq 0 ]; then
  echo "ERROR: the manifest records zero canonical fixtures from $SPEC_DIR." >&2
  echo "       That is missing evidence, not evidence of absence." >&2
  exit 1
fi

if [ "$missing" -gt 0 ]; then
  echo "conformance coverage: $missing unexcused fixture(s)." >&2
  exit 1
fi

echo "conformance coverage OK: $covered/$total canonical fixture(s) replayed;" \
     "$excused_named named excuse(s), $excused_family in unimplemented families"
