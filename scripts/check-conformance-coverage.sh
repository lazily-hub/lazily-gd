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

# ── no runner spells the corpus root itself (#lzcorpusrootguards) ─────────────
#
# Every rung below reasons about the corpus the run READ. This one is about
# WHICH corpus that was. LAZILY_SPEC_CONFORMANCE_DIR repoints replays at a
# scratch copy so a perturbation probe can truncate fixtures; a runner that
# builds its own path out of a hardcoded default root ignores the override,
# reads the REAL corpus while believing it was redirected, and is green either
# way — so nothing reports it. lazily-zig carried fourteen such sites across
# twelve areas: truncating fourteen fixtures reddened ZERO tests before the fix
# and 26 after. lazily-rs was worse, 0 of 25 areas redirected.
#
# lazily-gd MEASURED CLEAN — both path-building sites are override-first. This
# rung exists so it stays that way. The surface being two sites is not safety;
# it is exactly the size at which a third one gets added without anyone noticing.
#
# Build corpus paths with `LazilyFixtureLoader.spec_dir()`, which resolves the
# root at runtime. `tests/conformance/fixture_loader.gd` is the one legitimate
# mention: it DEFINES the default that `spec_dir()` falls back to.
#
# It runs BEFORE the corpus-presence check below, which exits 0 on a checkout
# without the sibling corpus. This is a SOURCE scan and does not need the corpus
# — and a checkout without the sibling is exactly where a new runner gets
# written.
#
# The scan is not a grep. lazily-go's and lazily-js's equivalents were both
# proven evadable by splitting the root across two literals, so this one strips
# comments, inlines single-literal `const`/`var` bindings, and folds
# `path_join` / `+` concatenations before it looks. Comments are skipped on
# purpose: several files here legitimately quote the path while explaining the
# corpus, and requiring them to stop describing it would trade a real
# explanation for a lint.
python3 - <<'CORPUS_ROOT_GUARD' || exit 1
import os, re, sys

ROOTS = ["tests", "addons/lazily"]  # NOT addons/gdUnit4 — vendored third party.
ALLOW = {"tests/conformance/fixture_loader.gd"}
# Split so this guard never matches its own needle.
NEEDLE = "../lazily-" + "spec/conformance"
# Positive evidence: this tree has 14 GDScript sources. A walk that examined
# nothing (a moved directory, a bad root) would otherwise report OK over an
# empty set — the vacuous green every rung in this file refuses.
FLOOR = 8

OPENERS, CLOSERS = "([{", ")]}"
STR = r'"(?:[^"\\]|\\.)*"'
ASSIGN = re.compile(r"^\s*(?:const|var)\s+([A-Za-z_]\w*)\s*(?::\s*[\w.\[\], ]*)?:?=\s*(" + STR + r")\s*$")
JOIN = re.compile(r"(" + STR + r")\s*\.\s*path_join\(\s*(" + STR + r")\s*\)")
PLUS = re.compile(r"(" + STR + r")\s*\+\s*(" + STR + r")")


def strip_comment(line):
    """Return (code with any trailing `#` comment removed, bracket-depth delta)."""
    out, depth, quote, i = [], 0, None, 0
    while i < len(line):
        c = line[i]
        if quote is not None:
            out.append(c)
            if c == "\\" and i + 1 < len(line):
                out.append(line[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in "\"'":
            quote = c
            out.append(c)
        elif c == "#":
            break
        else:
            if c in OPENERS:
                depth += 1
            elif c in CLOSERS:
                depth -= 1
            out.append(c)
        i += 1
    return "".join(out), depth


def logical_lines(path):
    """Physical lines folded across `\\` and unclosed brackets, so a join split
    over two lines is still one string to look at."""
    with open(path, encoding="utf-8", errors="replace") as fh:
        raw = fh.read().splitlines()
    buf, start, depth = "", 0, 0
    for n, line in enumerate(raw, 1):
        code, delta = strip_comment(line)
        if not buf:
            start = n
        cont = code.rstrip().endswith("\\")
        if cont:
            code = code.rstrip()[:-1]
        buf += code
        depth += delta
        if depth <= 0 and not cont:
            yield start, buf
            buf, depth = "", 0
    if buf:
        yield start, buf


def fold(text):
    """`"a".path_join("b")` -> `"a/b"`, `"a" + "b"` -> `"ab"`, to fixpoint."""
    for _ in range(32):
        new = JOIN.sub(lambda m: '"%s/%s"' % (m.group(1)[1:-1], m.group(2)[1:-1]), text)
        new = PLUS.sub(lambda m: '"%s%s"' % (m.group(1)[1:-1], m.group(2)[1:-1]), new)
        if new == text:
            break
        text = new
    return text


def inline(text, consts):
    if not consts:
        return text
    pat = re.compile(r"\b(" + "|".join(map(re.escape, consts)) + r")\b")
    return pat.sub(lambda m: consts[m.group(1)], text)


examined, offenders = 0, []
for root in ROOTS:
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            if not name.endswith(".gd"):
                continue
            path = os.path.join(dirpath, name)
            examined += 1
            if path in ALLOW:
                continue
            lines = list(logical_lines(path))
            consts = {}
            for _, code in lines:
                m = ASSIGN.match(code)
                if m:
                    consts[m.group(1)] = m.group(2)
            for n, code in lines:
                if NEEDLE in fold(inline(code, consts)):
                    offenders.append((path, n))

if examined < FLOOR:
    sys.stderr.write(
        "ERROR: corpus-root scan examined %d GDScript source(s) in %s; expected at least %d.\n"
        % (examined, "/, ".join(ROOTS) + "/", FLOOR)
    )
    sys.stderr.write(
        "       Reporting OK here would be a pass over nothing (#lzvacuousrun).\n"
        "       Run this from the repo root, or fix the scan roots.\n"
    )
    sys.exit(1)

if offenders:
    sys.stderr.write(
        "ERROR: these sources spell the default corpus root instead of resolving it\n"
        "       at runtime:\n"
    )
    for path, n in offenders:
        sys.stderr.write("         %s:%d\n" % (path, n))
    sys.stderr.write(
        "       LAZILY_SPEC_CONFORMANCE_DIR does not reach them, so they replay the\n"
        "       REAL corpus while a perturbation probe believes it redirected them —\n"
        "       and their fixtures read as unfalsifiable. Build the path with\n"
        "       LazilyFixtureLoader.spec_dir() (#lzcorpusrootguards).\n"
    )
    sys.exit(1)

print(
    "corpus-root OK: %d GDScript source(s) scanned; none builds a corpus path from"
    " the default root" % examined
)
CORPUS_ROOT_GUARD

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
  "egress/"
)

# Fixtures in an IMPLEMENTED family that are still not replayed. These are the
# entries that must carry a reason, because their family is one this binding
# claims to support.
#
# EMPTY as of the bulk-op landing: every canonical `reactive-graph/` fixture is
# replayed. An empty list is not a licence to stop naming gaps — the next
# unreplayed fixture in an implemented family belongs here with a reason, and the
# loop below still refuses one that is neither replayed nor named.
#
# Kept in the MULTI-LINE form even while empty. lazily-spec's
# check-coverage-claims.mjs reads this array by scanning from `NAME=(` to the
# next line beginning with `)`, so the one-line `KNOWN_UNCOVERED=()` spelling
# has no terminator to find and the read runs on into whatever array closes
# next — a silently wrong gap ledger, in the guard whose whole job is to make
# gaps visible.
KNOWN_UNCOVERED=(
  # Replay-equivalence proof (`lazily-spec/docs/replay-equivalence.md`) is an
  # optional (MAY) coverage row and lazily-py is the reference implementation;
  # this binding has no harness yet, so it opens none of the three. Building one
  # is what removes these entries — they are not permanent carve-outs.
  "replay/canonical_encoding_equality.json"
  "replay/divergence_localization.json"
  "replay/fingerprint_log_binding.json"
  # The generic egress-machine fixtures require retry-budget/window machinery;
  # this binding currently implements only the latest-durable projection model.
  "egress/egress_generation_fence.json"
  "egress/egress_inflight_window.json"
  "egress/egress_ordered_ack.json"
  "egress/egress_retry_budget.json"
)

MANIFEST="${LAZILY_CONFORMANCE_MANIFEST:-build/conformance-fixtures-loaded.txt}"

if [ ! -s "$MANIFEST" ]; then
  echo "FAIL: no conformance manifest at $MANIFEST." >&2
  echo "      Run the suite with LAZILY_CONFORMANCE_MANIFEST set to an ABSOLUTE" >&2
  echo "      path so the recorder attaches (\`make check\` does this). An absent" >&2
  echo "      manifest is missing evidence, not evidence of absence." >&2
  exit 1
fi
# The manifest carries TWO kinds of record since the assertion-block rung landed
# (#lzgdblockledger): a bare `corpus/fixture.json` line means the file was
# OPENED, and a TAB-separated `blocks-declared` / `blocks-bound` line belongs to
# the block ledger at the bottom of this file. The fixture rungs here read only
# the bare lines — without this filter every block record reads as a fixture id
# that names no file, and the evidence-channel check below reports 127 corrupt
# entries for a manifest that is perfectly intact.
#
# `|| true` because `grep -v` exits 1 when it selects nothing, and under
# `pipefail` that would abort here rather than at the `covered -eq 0` guard
# below, which is the check that actually knows what an empty opened set means.
OPENED="$(grep -v -e $'\t' "$MANIFEST" | sort -u || true)"

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

# ── rung 0: the assertion-block BIND ledger (#lzgdblockledger, #lznullformblind)
#
# The rung UNDER everything above. Each rung so far reasons about fixtures the
# run OPENED and scenarios it REACHED; this one reasons about the assertion
# BLOCKS those fixtures carry. It is the floor because every other rung is
# scoped to a block a runner already bound — `_check`'s fail-closed default
# reports an unmodelled KEY, but only inside a block something reads. A block no
# runner binds reports NOTHING AT ALL, because nothing reads its keys.
#
# That was not a theoretical gap here. Before this rung existed, falsifying
# every value in `scope_teardown_equals_fold_of_disposals.json`'s top-level
# `expected` — `observationally_equal` naming scenarios that do not exist,
# `dependents_of.topic` 999, `read.outside` -1, `observed_by` ["bogus"] — left
# `make check` GREEN at exit 0, 31 test cases executed, 22/156 fixtures
# replayed. Deleting the block outright was also green. That block is the claim
# the fixture exists for, and nothing in this binding read it.
#
# Blocks are matched by CONTENT digest, never by name: a runner cannot satisfy
# this by recognising the word `expect`, only by binding the bytes the loader
# inventoried.

# Blocks an OPENED fixture carries that no runner binds, as
# `fixture|where|reason`. Each entry is a claim that someone looked and that the
# block cannot be bound here yet — so it stays VISIBLE on every run instead of
# invisible, which is the state this whole rung replaced.
#
# Its SIZE is pinned by `EXPECTED_LEDGERED_BLOCKS` below, as an exact equality
# defaulting to zero, because checks 1-3 make this an EQUALITY against the run
# and an equality is satisfied by any consistent pair — detaching a bind and
# adding its matching entry here passes both directions (#lzledgerratchet). It
# may SHRINK freely, but only in a commit that lowers that pin by the same
# amount; a pin left above the ledger is slack, and slack is what re-opens the
# detach-and-excuse hole.
#
# EMPTY, and that is the point: all 136 sites in the opened set are bound. The
# one that was not — `.expected` in
# `reactive-graph/scope_teardown_equals_fold_of_disposals.json` — is now bound by
# `LazilyReactiveGraphRunner._check_scenario_tail` / `_check_relation`, which
# assert `final_state`, `after_publish`, and the `observationally_equal` relation
# between the two scenarios.
#
# Kept in the MULTI-LINE form even while empty, for the same reason
# KNOWN_UNCOVERED above is: lazily-spec's check-corpus-floors.mjs reads a bash
# array by scanning from `NAME=(` to the next line beginning with `)`, and the
# one-line `NAME=()` spelling has no terminator to find, so the read runs on
# into whatever array closes next.
KNOWN_UNBOUND_BLOCKS=(
)

BLOCK_GUARD_PY="$(cat <<'PY'
import json
import os
import struct
import sys

manifest_path, spec_dir = sys.argv[1], sys.argv[2]

# ---- the excuse ledger, with its three staleness checks --------------------
excuses = {}
for raw in sys.argv[3:]:
    raw = raw.strip()
    if not raw:
        continue
    parts = raw.split("|", 2)
    if len(parts) != 3 or not parts[2].strip():
        sys.stderr.write(
            "ERROR: malformed KNOWN_UNBOUND_BLOCKS entry %r — expected\n"
            "       fixture|where|reason, with a NON-EMPTY reason. An excuse nobody had\n"
            "       to justify is an allowlist entry wearing a different hat.\n" % raw
        )
        sys.exit(1)
    excuses["%s|%s" % (parts[0], parts[1])] = parts[2].strip()

# ---- the digest rule, the python TWIN of tests/conformance/block_ledger.gd --
#
# Rule for rule. lazily-cs keys its digest on the raw lexical form of each
# number (`JsonElement.GetRawText()`); that rule CANNOT be mirrored in GDScript,
# because Godot's JSON parser exposes no per-node source text and reports every
# number as a float. So numbers are folded by their IEEE-754 binary64 BITS,
# which both sides can produce exactly and which depends on neither side's float
# formatter. `"integer when whole, else %.17e"` was measured and rejected first:
# GDScript's `%` operator does not implement `%e` at all and returns the literal
# string `"%.17e"`, which would have folded every non-whole number in the corpus
# onto one digest.
BLOCK_NAMES = ("assertions", "expect", "expect_after", "expect_initial", "expected")
FNV_PRIME = 0x01000193
LANE0_BASIS = 0x811C9DC5
LANE1_BASIS = 0x811C9DC5 ^ 0x5BF03635
U32 = 0xFFFFFFFF
# Smallest POSITIVE NORMAL binary64. Godot's JSON parser flushes anything below
# this to zero where python keeps the subnormal, so such a value is refused with
# a named error rather than hashed into a silent disagreement.
SMALLEST_NORMAL = 2.2250738585072014e-308


def feed(out, value, where):
    if isinstance(value, dict):
        out.append(b"{")
        for key in sorted(value):
            out.append(str(key).encode("utf-8"))
            out.append(b"=")
            feed(out, value[key], where)
        out.append(b"}")
    elif isinstance(value, list):
        out.append(b"[")
        for item in value:
            feed(out, item, where)
        out.append(b"]")
    elif isinstance(value, bool):
        out.append(b"b1" if value else b"b0")
    elif isinstance(value, str):
        out.append(b"s")
        out.append(value.encode("utf-8"))
    elif isinstance(value, (int, float)):
        f = float(value)
        if f != f or f in (float("inf"), float("-inf")):
            sys.stderr.write(
                "ERROR: %s carries the non-finite number %r. JSON cannot spell one, so\n"
                "       the corpus has been generated by something that can — and the two\n"
                "       digest sides would not agree on it.\n" % (where, value)
            )
            sys.exit(1)
        if f == 0.0:
            # `-0.0` and `0` are ONE claim; python's json reads `-0` as the int 0
            # (sign gone) while Godot reads it as -0.0 (sign kept).
            f = 0.0
        elif abs(f) < SMALLEST_NORMAL:
            sys.stderr.write(
                "ERROR: %s carries %r, a SUBNORMAL double.\n"
                "       Godot's JSON parser flushes magnitudes below %r to zero while\n"
                "       python keeps them, so the GDScript digest and this twin would\n"
                "       disagree about this block SILENTLY — every site in the corpus\n"
                "       would read as unbound with no hint why. Failing here instead.\n"
                "       Pin a shared rule for subnormals in block_ledger.gd and in this\n"
                "       file, in the same change, before the corpus carries one.\n"
                % (where, value, SMALLEST_NORMAL)
            )
            sys.exit(1)
        out.append(b"n")
        out.append(struct.pack("<d", f))
    else:
        out.append(b"z")


def fnv(stream, basis):
    h = basis
    for byte in stream:
        h = (h ^ byte) & U32
        h = (h * FNV_PRIME) & U32
    return h


def digest(block, where):
    parts = []
    feed(parts, block, where)
    stream = b"".join(parts)
    return "%08x%08x" % (fnv(stream, LANE0_BASIS), fnv(stream, LANE1_BASIS))


def walk(fixture_id, node, path, out):
    """The python twin of `LazilyBlockLedger._walk`.

    Object-valued block -> one site under its own name. Array-valued block ->
    one site per plain-object element, bucketed `name[]`. Descends INTO a block
    as well as past it, mirroring lazily-spec's maximal rule; no block in the
    corpus nests another today, so this changes no count.
    """
    if isinstance(node, list):
        for index, item in enumerate(node):
            walk(fixture_id, item, "%s[%d]" % (path, index), out)
        return
    if not isinstance(node, dict):
        return
    for key, value in node.items():
        where = path + "." + key
        if key in BLOCK_NAMES:
            site = "%s|%s" % (fixture_id, where)
            if isinstance(value, dict):
                out[site] = digest(value, site)
            elif isinstance(value, list):
                for index, item in enumerate(value):
                    if isinstance(item, dict):
                        nested = "%s|%s[%d]" % (fixture_id, where, index)
                        out[nested] = digest(item, nested)
        walk(fixture_id, value, where, out)


# ---- what the RUN inventoried and bound ------------------------------------
try:
    with open(manifest_path, encoding="utf-8") as fh:
        manifest_lines = fh.read().splitlines()
except (OSError, UnicodeDecodeError) as exc:
    sys.stderr.write(
        "ERROR: cannot read the conformance manifest %s (%s).\n"
        "       Evidence that cannot be decoded is not evidence of absence. Re-run the\n"
        "       suite with LAZILY_CONFORMANCE_MANIFEST set to an ABSOLUTE path,\n"
        "       truncated first, which is what `make test` does. Do not hand-edit it:\n"
        "       it is the run's own evidence.\n" % (manifest_path, exc)
    )
    sys.exit(1)

declared = {}
bound = set()
for line in manifest_lines:
    fields = line.split("\t")
    if fields[0] == "blocks-declared" and len(fields) == 4:
        declared[fields[3]] = fields[2]
    elif fields[0] == "blocks-bound" and len(fields) == 2:
        bound.add(fields[1])

# ---- the DERIVED expectation ----------------------------------------------
#
# Derived, never typed (#lzblockfloorpin). A hand-typed MIN_BLOCKS is wrong for
# the whole interval between the corpus moving and somebody noticing, and a `>=`
# comparison makes that interval invisible because corpus GROWTH never trips it.
#
# It comes from three things this repo can be held to and the RUN cannot
# influence: the canonical corpus listing under $SPEC_DIR, and this binding's own
# two committed ledgers — `IMPLEMENTED_FAMILY_PREFIXES` and `KNOWN_UNCOVERED`,
# the same pair the fixture rung above is checked against. Their intersection is
# exactly the set the suite opens (22 fixtures), which is what makes a staged
# binding's block magnitude well defined rather than a number the next port
# commit invalidates: implementing a family moves this in the SAME commit that
# adds the prefix.
#
# LIMITATION, stated rather than papered over: both this expectation and the
# run's inventory read the SAME corpus, so deleting a block from the real corpus
# moves them together and this equality cannot see it. What it does catch is the
# two WALKS disagreeing — a loader that stops descending, drops a block name,
# misses array elements, or detaches entirely. The corpus-against-its-own-history
# half of the job belongs to lazily-spec's `corpus-counts.json`.
prefixes = [p for p in os.environ.get("FAMILY_PREFIX_LEDGER", "").splitlines() if p.strip()]
uncovered = {u.strip() for u in os.environ.get("KNOWN_UNCOVERED_LEDGER", "").splitlines() if u.strip()}
if not prefixes:
    sys.stderr.write(
        "ERROR: IMPLEMENTED_FAMILY_PREFIXES reached this guard EMPTY, so the derived\n"
        "       expectation would be zero blocks over zero fixtures and every check\n"
        "       below would pass having compared nothing (#lzvacuousrun).\n"
    )
    sys.exit(1)

corpus = []
for root, _dirs, names in os.walk(spec_dir):
    for name in names:
        if name.endswith(".json"):
            rel = os.path.relpath(os.path.join(root, name), spec_dir).replace(os.sep, "/")
            corpus.append(rel)
corpus.sort()

opened = [
    f for f in corpus
    if any(f.startswith(p) for p in prefixes) and f not in uncovered
]

expected = {}
for fixture_id in opened:
    with open(os.path.join(spec_dir, fixture_id), encoding="utf-8") as fh:
        walk(fixture_id, json.load(fh), "", expected)

expected_digests = set(expected.values())
declared_digests = set(declared.values())

# ---- 1. every inventoried block must be BOUND by some runner ---------------
unbound = sorted(
    site for site, dig in declared.items() if dig not in bound and site not in excuses
)
if unbound:
    sys.stderr.write(
        "ERROR: %d assertion block(s) were carried by an OPENED fixture and bound by no\n"
        "       runner. Every other rung is scoped to blocks a runner bound, so these\n"
        "       report nothing at all rather than reporting a gap:\n" % len(unbound)
    )
    for site in unbound:
        sys.stderr.write("         %s\n" % site)
    sys.stderr.write(
        "       Bind each with LazilyBlockLedger.bind() and assert its keys, or add it\n"
        "       to KNOWN_UNBOUND_BLOCKS with a reason so the gap is visible on every\n"
        "       run instead of invisible.\n"
    )
    sys.exit(1)

# ---- 2. an excuse for a block a runner DID bind is a lie ------------------
stale = sorted(site for site in excuses if site in declared and declared[site] in bound)
if stale:
    sys.stderr.write(
        "ERROR: %d KNOWN_UNBOUND_BLOCKS entr(ies) name a block this run DID bind. The\n"
        "       excuse hides nothing and its reason is now false:\n" % len(stale)
    )
    for site in stale:
        sys.stderr.write('         %s — "%s"\n' % (site, excuses[site]))
    sys.stderr.write("       Delete each one.\n")
    sys.exit(1)

# ---- 3. an excuse for a block the opened corpus no longer carries ---------
unknown = sorted(site for site in excuses if site not in declared)
if unknown:
    sys.stderr.write(
        "ERROR: %d KNOWN_UNBOUND_BLOCKS entr(ies) name a block no OPENED fixture\n"
        "       declares — the fixture, the path, or the block is gone:\n" % len(unknown)
    )
    for site in unknown:
        sys.stderr.write('         %s — "%s"\n' % (site, excuses[site]))
    sys.stderr.write(
        "       Delete each one, or fix its `fixture|where` to a path the walk prints.\n"
    )
    sys.exit(1)
# ---- 3b. the ledger's SIZE, pinned as an EQUALITY (#lzledgerratchet) ------
#
# Checks 1-3 make the ledger an EQUALITY against the run: an unbound block
# nobody excused fails, and an excuse the run outlived fails. That is worth
# having and it is not enough, because an equality is satisfied by ANY
# CONSISTENT PAIR. A commit that detaches N binds AND writes the N matching
# entries passes both directions. MEASURED here, not argued: detaching the bind
# for one block and adding its `fixture|where|reason` left the whole of
# `make check` green at exit 0, reporting "135/136 ... both asserted EQUAL".
# The magnitude rung below cannot see it either — the site is still DECLARED,
# merely no longer bound, so 5a/5b/5c all still agree.
#
# What closes it is a pin the RUN CANNOT MOVE. Checks 1-3 compare the ledger
# against the RUN, and under that attack both sides travel together. This
# compares it against a COMMITTED CONSTANT, which does not travel at all, and
# that independence is the whole of the value. It is not a mirrored count of
# something already derived — ledger size is derivable from nothing.
#
# The operator is EXACT EQUALITY, in both directions, and it was a `>` ceiling
# first. A ceiling SELF-DISABLES. It refuses the detach-and-excuse commit only
# while its slack is zero: migrate one site, leave the constant alone, and slack
# is 1 — the same attack now passes. Slack accumulates once per migration and
# converges on exactly the hand-typed-floor-against-a-much-larger-actual defect
# the DERIVED magnitude below exists to replace. An equality has no slack by
# construction and cannot drift in silence, because a STALE pin FAILS: a shrink
# is refused as loudly as a growth. A number that fails when stale is a ratchet,
# not a floor.
#
# Zero, because gd's ledger is empty and all 136 sites in the opened set are
# bound. At zero the shrink half is semantically vacuous — nothing sits below
# zero — and the equality still has to land here, because the two operators
# diverge the moment anyone legitimately raises the pin, and that commit is the
# worst possible place to be discovering which one is in force.
#
# Raising it is legitimate, and must be deliberate and visible in the diff: a
# corpus that gains a genuinely unbindable block is the real case, and expect to
# be asked why the capability cannot exist here. Never raise it to park a block
# somebody has not got round to binding — that is the laundering this rung
# refuses. Lowering it is MANDATORY in the same commit that binds a ledgered
# site. The env override is for probing this guard, not for a build to opt out.
#
# Fail CLOSED on a pin that cannot be read. Falling back to the default would
# turn a typo in a CI environment into a silently different policy, which is the
# vacuous green every rung in this file exists to refuse.
EXPECTED_LEDGERED_BLOCKS_RAW = os.environ.get("EXPECTED_LEDGERED_BLOCKS", "0")
# ONE parse for the whole family (#lzpinparsestrict): a NON-EMPTY run of bare
# ASCII digits `0`-`9`, and nothing else. Validated BEFORE any parse runs, and
# deliberately stricter than both `int()` and `str.isdigit()`, because each of
# those silently accepts a number nobody wrote: `int("1_0")` is 10 (PEP 515
# separators), `int(" 7 ")` is 7, and `"\u0663".isdigit()` is TRUE for the
# Arabic-Indic three. This reader used to be `.strip().isdigit()`, so `" 7 "`
# became 7 and `٣` became 3. Refused now: whitespace around or inside, a leading
# `+` or `-`, separators, a radix prefix, a float or an exponent, and any
# non-ASCII digit. A negative falls out of the same check — no ledger size can
# equal it, so it would make this rung unsatisfiable rather than exact. Leading
# zeros are fine and `0` stays valid; this binding pins at zero.
#
# An UNSET variable takes the committed literal above. An EXPLICITLY EMPTY one is
# a REJECTION, not a fall-through to it: `os.environ.get(NAME, DEFAULT)`
# distinguishes the two, and whoever exported the wrong thing is the one person
# who cannot see that it was ignored.
if not EXPECTED_LEDGERED_BLOCKS_RAW or EXPECTED_LEDGERED_BLOCKS_RAW.strip("0123456789"):
    sys.stderr.write(
        "ERROR: EXPECTED_LEDGERED_BLOCKS=%r is not a non-negative integer in bare ASCII\n"
        "       digits (#lzpinparsestrict). This pin is the one side of the check the run\n"
        "       cannot move, so an unreadable pin is REFUSED rather than defaulted — not\n"
        "       even an empty one: a default would make the policy silently whatever the\n"
        "       typo implied.\n" % EXPECTED_LEDGERED_BLOCKS_RAW
    )
    sys.exit(1)
EXPECTED_LEDGERED_BLOCKS = int(EXPECTED_LEDGERED_BLOCKS_RAW)
if len(excuses) != EXPECTED_LEDGERED_BLOCKS:
    if len(excuses) > EXPECTED_LEDGERED_BLOCKS:
        sys.stderr.write(
            "ERROR: the unbound-block ledger GREW to %d entr(ies); the pin is %d. An\n"
            "       excuse was added without the pin being raised in the SAME commit.\n"
            "       Checks 1-3 cannot see this. They assert only that the ledger and the\n"
            "       run AGREE, and any CONSISTENT PAIR satisfies them: a commit that\n"
            "       detaches a bind and writes the matching entry passes both directions,\n"
            "       because a detached bind's site is still DECLARED. The magnitude rung\n"
            "       below agrees for that same reason.\n"
            "       Bind the block with LazilyBlockLedger.bind() and assert its keys.\n"
            "       Raise EXPECTED_LEDGERED_BLOCKS to %d in THIS commit only for a\n"
            "       genuinely unbindable block, with a reason. Ledgered sites:\n"
            % (len(excuses), EXPECTED_LEDGERED_BLOCKS, len(excuses))
        )
    else:
        sys.stderr.write(
            "ERROR: the unbound-block ledger SHRANK to %d entr(ies); the pin is still\n"
            "       %d. That is good news which still has to be RECORDED: %d ledgered\n"
            "       site(s) got bound and the pin was not lowered in the same commit. A\n"
            "       pin left above the ledger is SLACK, and slack is precisely what a\n"
            "       `<=` ceiling accumulates one migration at a time until it stops\n"
            "       refusing the detach-and-excuse commit at all.\n"
            "       LOWER EXPECTED_LEDGERED_BLOCKS TO %d IN THIS COMMIT. Remaining\n"
            "       ledgered sites:\n"
            % (
                len(excuses),
                EXPECTED_LEDGERED_BLOCKS,
                EXPECTED_LEDGERED_BLOCKS - len(excuses),
                len(excuses),
            )
        )
    listed = sorted(excuses)
    for site in listed[:20]:
        sys.stderr.write('         %s — "%s"\n' % (site, excuses[site]))
    if len(listed) > 20:
        sys.stderr.write(
            "         ... and %d more — read them from `git diff` on this script.\n"
            % (len(listed) - 20)
        )
    sys.exit(1)

# ---- 4. the zero-guard on each dimension ----------------------------------
#
# The whole reason this rung needs a magnitude. Without it, zero declared blocks
# means zero unbound blocks, and every check above reports OK having compared
# nothing (#lzvacuousrun). Each dimension gets its own guard because each can
# reach zero for its own reason.
for label, size, source in (
    ("derived site", len(expected), "the corpus walk"),
    ("derived distinct-digest", len(expected_digests), "the corpus walk"),
    ("inventoried site", len(declared), "the run's manifest"),
    ("inventoried distinct-digest", len(declared_digests), "the run's manifest"),
):
    if size == 0:
        sys.stderr.write(
            "ERROR: the %s count is ZERO, from %s.\n"
            "       That is missing EVIDENCE, not evidence of absence: a guard that\n"
            "       inventoried nothing must not report OK (#lzvacuousrun).\n"
            % (label, source)
        )
        sys.exit(1)

# ---- 5a. SITES, asserted EQUAL --------------------------------------------
if len(declared) != len(expected):
    direction = "FEWER than" if len(declared) < len(expected) else "MORE than"
    sys.stderr.write(
        "ERROR: the run inventoried %d assertion-block SITES; the canonical corpus at\n"
        "       %s, narrowed by IMPLEMENTED_FAMILY_PREFIXES and KNOWN_UNCOVERED,\n"
        "       derives %d over %d opened fixtures. The run has %s the corpus carries.\n"
        "       The DIGEST count below can agree while this does not: deleting a block\n"
        "       whose bytes recur elsewhere leaves the digest set whole and takes one\n"
        "       site away, so a digest count absorbs the deletion entirely.\n"
        "       Either the corpus moved under this checkout, or LazilyBlockLedger._walk\n"
        "       and its twin in this script stopped agreeing — fix whichever moved.\n"
        % (len(declared), spec_dir, len(expected), len(opened), direction)
    )
    sys.exit(1)

# ---- 5b. DISTINCT DIGESTS, asserted EQUAL ---------------------------------
if len(declared_digests) != len(expected_digests):
    direction = "FEWER than" if len(declared_digests) < len(expected_digests) else "MORE than"
    sys.stderr.write(
        "ERROR: the run inventoried %d DISTINCT assertion-block digests; the corpus\n"
        "       derives %d over %d opened fixtures. The run has %s the corpus carries.\n"
        "       The SITE count above can agree while this does not: two sites spelled\n"
        "       identically share one digest, so rewriting one block into another's\n"
        "       spelling collapses two distinct claims into one and leaves the site\n"
        "       count untouched.\n"
        "       Either the corpus moved under this checkout, or LazilyBlockLedger.digest\n"
        "       and its twin in this script stopped agreeing — fix whichever moved.\n"
        % (len(declared_digests), len(expected_digests), len(opened), direction)
    )
    sys.exit(1)

# ---- 5c. SET IDENTITY: WHICH digests, not how many ------------------------
#
# The check both counts are blind to. A twin that hashed differently but
# consistently would produce 136 sites and 127 distinct digests on both sides and
# satisfy 5a and 5b exactly, while not one digest matched — and the bind check
# above would then have nothing real to compare. Two sites swapping digests is
# the same class of miss. So compare the site -> digest MAPS.
if declared != expected:
    only_run = sorted(set(declared) - set(expected))
    only_corpus = sorted(set(expected) - set(declared))
    mismatched = sorted(s for s in set(declared) & set(expected) if declared[s] != expected[s])
    sys.stderr.write(
        "ERROR: the run's site -> digest map is not the corpus walk's, even though the\n"
        "       counts agree. The two walks or the two digest rules have diverged, and\n"
        "       a cardinality check cannot see it.\n"
    )
    for site in only_run[:10]:
        sys.stderr.write("         inventoried, not derived: %s\n" % site)
    for site in only_corpus[:10]:
        sys.stderr.write("         derived, not inventoried: %s\n" % site)
    for site in mismatched[:10]:
        sys.stderr.write(
            "         digest differs: %s (run %s, corpus %s)\n"
            % (site, declared[site], expected[site])
        )
    sys.stderr.write(
        "       LazilyBlockLedger.digest and the `digest` twin in this script must fold\n"
        "       numbers, strings, key order and type tags identically.\n"
    )
    sys.exit(1)

print(
    "assertion-block bind OK: %d/%d inventoried site(s) BOUND to a runner "
    "(%d declared unbindable, EXACTLY the pinned %d — an equality, in both directions, so "
    "enlarging the excused set is an explicit act rather than a side effect of detaching "
    "a bind, and a pin left stale by a migration FAILS instead of accruing slack; "
    "derived %d sites "
    "AND %d distinct digests from %d opened "
    "fixtures, both asserted EQUAL, and the site -> digest maps are identical; "
    "content-keyed, so a runner's block NAME cannot satisfy it)"
    % (
        len(declared) - len(excuses),
        len(declared),
        len(excuses),
        EXPECTED_LEDGERED_BLOCKS,
        len(expected),
        len(expected_digests),
        len(opened),
    )
)
PY
)"

command -v python3 >/dev/null 2>&1 || {
  echo "FAIL: python3 is required to inventory the corpus's assertion blocks." >&2
  echo "      Without it rung 0 cannot be verified, and passing in that state is" >&2
  echo "      missing evidence, not evidence of absence." >&2
  exit 1
}

# The two ledgers arrive as newline-joined scalars rather than as argv, so the
# excuse argv keeps its shape and this script adds no further top-level bash
# array for lazily-spec's check-corpus-floors.mjs to classify.
FAMILY_PREFIX_LEDGER="$(printf '%s\n' ${IMPLEMENTED_FAMILY_PREFIXES[@]+"${IMPLEMENTED_FAMILY_PREFIXES[@]}"})" \
KNOWN_UNCOVERED_LEDGER="$(printf '%s\n' ${KNOWN_UNCOVERED[@]+"${KNOWN_UNCOVERED[@]}"})" \
python3 -c "$BLOCK_GUARD_PY" "$MANIFEST" "$SPEC_DIR" \
  ${KNOWN_UNBOUND_BLOCKS[@]+"${KNOWN_UNBOUND_BLOCKS[@]}"}
