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
)

# Fixtures in an IMPLEMENTED family that are still not replayed. These are the
# entries that must carry a reason, because their family is one this binding
# claims to support.
KNOWN_UNCOVERED=(
  # `fanout` / `churn` / `dispose_fanout` / `dispose_stale_handle` bulk ops are
  # not implemented; id recycling needs explicit work beyond instance ids.
  "reactive-graph/churn_returns_to_baseline.json"
  "reactive-graph/recycled_id_inherits_nothing.json"
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
