# lazily-gd — build, test, and verification targets.

# Not optional. The suite pipes godot through `tee`, so `pipefail` is what makes
# a failing run fail instead of reporting `tee`'s exit code — and `/bin/sh` is
# dash on Ubuntu, which has no `pipefail` at all. On a distro where /bin/sh is
# bash this difference is invisible locally and only appears in CI.
SHELL := /bin/bash

.PHONY: all check test load-graph conformance-coverage assertion-ordering-check ci-reach gdunit4 import clean

GODOT ?= godot
REPORTS := build/reports

# The canonical corpus AND the cross-binding static guards live in the sibling
# checkout. CI clones it next to this repo (see .github/workflows/ci.yml), so the
# default is the same path a developer uses.
LAZILY_SPEC_DIR ?= ../lazily-spec

# A hang is a distinct failure mode from a red test, and it needs its own guard:
# an incompatible gdUnit4 fails to compile its CLI and then never exits, which on
# CI burns the job limit instead of reporting anything. Bounded so that failure
# arrives as a diagnosable timeout.
TIMEOUT ?= timeout
IMPORT_TIMEOUT ?= 120
TEST_TIMEOUT ?= 300

all: check

# Test dependency, not a shipping one. Idempotent, so `make check` on a clean
# clone works without a separate setup step.
gdunit4:
	@scripts/install-gdunit4.sh

# The suite, plus the guard that makes a green result mean something.
#
# gdUnit4's CLI exits 0 when it runs zero tests — a misnamed directory, a suite
# that failed to parse, or a bad `-a` path all produce "OK" over nothing at all.
# Every binding in this family has a version of this guard (#lzvacuousrun); this
# is GDScript's. It asserts the magnitude explicitly before anything reports OK,
# so "no tests ran" fails as MISSING EVIDENCE rather than passing as success.
# Builds .godot/global_script_class_cache.cfg. Without it every `class_name` —
# gdUnit4's own CLI entrypoint included — fails to resolve, and the run dies as
# a parse error that looks like a broken framework rather than a missing step.
import: gdunit4
	@mkdir -p $(REPORTS)
	@$(TIMEOUT) $(IMPORT_TIMEOUT) $(GODOT) --headless --path . --import \
		> $(REPORTS)/import.log 2>&1 || true

# ABSOLUTE manifest path. The recorder runs inside the Godot process, whose
# working directory is not this one — a relative path silently writes the
# manifest somewhere nothing reads, and the guard then fails with "missing
# evidence" while the suite is green.
export LAZILY_CONFORMANCE_MANIFEST := $(CURDIR)/build/conformance-fixtures-loaded.txt

# ── the per-invocation run id (#lzstalemanifest) ──────────────────────────────
#
# Every rung in `conformance-coverage` reasons about what THIS run did. It reads
# that from `$(LAZILY_CONFORMANCE_MANIFEST)`, which the `test` recipe above
# truncates — but the guard runs in a SEPARATE process from the Godot run that
# fills it, so the file on disk is not necessarily this invocation's.
#
# MEASURED here before this was added, so the hole is not hypothetical:
#
#   * `make conformance-coverage` on its own, with no suite run at all, exited 0
#     reporting "22/156 canonical fixture(s) replayed" and "136/136 inventoried
#     site(s) BOUND" — entirely from the PREVIOUS invocation's manifest.
#   * a single scene run by hand (`godot -s .../GdUnitCmdTool.gd -a
#     tests/conformance_test.gd`) does not pass through this recipe, so nothing
#     truncates: it APPENDED its 250 records onto the previous run's 317, and the
#     guard then reported the same full green from the union of two runs.
#
# Godot is not the cached-task case lazily-kt has (`> Task :test UP-TO-DATE`);
# gdUnit4 re-executes every time and `test: import` has no way to be skipped.
# gd's exposure is the LEFTOVER FILE, which the same protocol closes.
#
# `:=` is load-bearing. A recursively-expanded `=` re-runs `$(shell)` at every
# reference, so the stamp written into the manifest and the value the guard
# compares against would be DIFFERENT ids and every run would fail — closed, but
# for a reason nobody could read off the message.
#
# Not overridable on purpose. There is no legitimate path that runs
# `conformance-coverage` outside `make check` here (CI is a single `make check`
# step, and `ci-reach` pins that), so an override would only ever be a way to
# hand the guard an id matching a stale manifest.
LAZILY_CONFORMANCE_RUN_ID := $(shell printf 'gd-%s-%s' "$$(date -u +%Y%m%dT%H%M%S%N)" "$$$$")
export LAZILY_CONFORMANCE_RUN_ID

# TWO markers, not one, and the second is the reason (#lzstalemanifest).
#
# `# lazily-run-id` is written by the truncation step, BEFORE Godot starts, so it
# says only "this file belongs to this invocation" — a run that dies in its first
# second leaves a correctly-stamped, empty manifest.
#
# `# lazily-run-complete` is appended only after the suite exited 0 through
# `pipefail` AND the executed-count guard passed, so it says "the recipe reached
# the end". It is a separate recipe line: make abandons the target on the first
# failing line, so a `timeout` kill, a parse error, a non-zero gdUnit4 exit or a
# zero-test run all leave the marker ABSENT.
#
# What it does NOT claim is completeness of the CONTENT. In GDScript a raise
# takes out the enclosing `for key in expect` loop, leaving every sibling key
# unasserted while the runner's own failure list stays empty (measured during
# #lzflagcoercion as `4 errors | 0 failures`), so a mid-way abort can look clean.
# The instrument for that is the CONTENT rungs, not this marker, and they were
# measured against a manifest carrying BOTH valid markers: truncating it in the
# middle is refused by the fixture rung (five `reactive-graph/` fixtures "NOT
# opened"), and removing every bind of three digests is refused by rung 0 ("3
# assertion block(s) ... bound by no runner"). One caveat, measured rather than
# assumed: 136 sites bind through 159 bind CALLS over 127 distinct digests, so
# deleting individual bind records can be absorbed by a duplicate. A bind that
# never happens at all cannot be, which is the abort case.

test: import
	@mkdir -p $(REPORTS) $(CURDIR)/build
	@test -n "$(LAZILY_CONFORMANCE_RUN_ID)" || { \
		echo "ERROR: LAZILY_CONFORMANCE_RUN_ID came out EMPTY." >&2; \
		echo "       The manifest would then be stamped with nothing and the guard" >&2; \
		echo "       would accept any leftover file. Check that \`date -u +%N\` works" >&2; \
		echo "       on this host." >&2; \
		exit 1; }
	@printf '# lazily-run-id %s\n' '$(LAZILY_CONFORMANCE_RUN_ID)' > $(LAZILY_CONFORMANCE_MANIFEST)
	@set -o pipefail; $(TIMEOUT) $(TEST_TIMEOUT) $(GODOT) --headless --path . \
		-s res://addons/gdUnit4/bin/GdUnitCmdTool.gd \
		-a tests --continue --ignoreHeadlessMode 2>&1 | tee $(REPORTS)/gdunit4.log
	@executed=$$(sed -e 's/\x1b\[[0-9;]*m//g' $(REPORTS)/gdunit4.log \
		| grep -oE 'Executed test cases *: *\([0-9]+/' \
		| tail -1 | grep -oE '[0-9]+'); \
	if [ -z "$$executed" ]; then \
		echo "ERROR: could not read a test count from the gdUnit4 output." >&2; \
		echo "       That is missing EVIDENCE, not evidence of success: the run" >&2; \
		echo "       may have executed nothing. See $(REPORTS)/gdunit4.log." >&2; \
		exit 1; \
	fi; \
	if [ "$$executed" -eq 0 ]; then \
		echo "ERROR: gdUnit4 executed 0 test cases and reported success." >&2; \
		echo "       Check the -a path and that tests/ still holds *_test.gd." >&2; \
		exit 1; \
	fi; \
	echo "gdUnit4: $$executed test case(s) executed"
	@printf '# lazily-run-complete %s\n' '$(LAZILY_CONFORMANCE_RUN_ID)' >> $(LAZILY_CONFORMANCE_MANIFEST)

# Its own Godot process on purpose: inside the suite the kernel is already
# resident, so the measurement would answer about the harness, not the kernel.
load-graph: import
	@out="$$($(TIMEOUT) $(IMPORT_TIMEOUT) $(GODOT) --headless --path . \
		-s res://scripts/load_graph_check.gd 2>&1)"; \
	echo "$$out" | grep -E '^(load-graph OK|FAIL)' || true; \
	if echo "$$out" | grep -q '^FAIL'; then exit 1; fi; \
	if ! echo "$$out" | grep -q '^load-graph OK'; then \
		echo "ERROR: load-graph check produced no verdict — treating as failure." >&2; \
		echo "$$out" >&2; \
		exit 1; \
	fi

conformance-coverage:
	@scripts/check-conformance-coverage.sh

# The cross-binding assertion-ordering guard (`#lzgdorderingguard`). Nine sibling
# bindings ran this from their own `make check`; this one did not, and had no
# entry in the guard's own CHECKS table either — so it was outside the guard
# entirely. That is exactly the omission the guard's design note warns about
# ("a new standalone target would be a guard every existing workflow could
# silently omit"), arrived at by joining the family after the guard existed.
#
# It matters most here: this is the binding that PAID for an unpinned ordering
# contract, hitting `#lzexpectedkeyorder` while its bind ledger was built
# (`final_state` must be read before `after_publish` publishes, and
# `after_publish` sorts alphabetically first).
#
# Fail CLOSED on a missing sibling, in the sibling guards' own wording rather
# than a python traceback that reads like a broken toolchain: the checker lives
# over there, so without it this gate verifies nothing.
assertion-ordering-check:
	@test -f $(LAZILY_SPEC_DIR)/scripts/check-assertion-ordering.py || { \
	  echo "ERROR: canonical spec sibling not found at '$(LAZILY_SPEC_DIR)'."; \
	  echo "       git clone https://github.com/lazily-hub/lazily-spec.git ../lazily-spec"; \
	  echo "       (or override LAZILY_SPEC_DIR=/path/to/lazily-spec)"; \
	  echo "       This is a hard failure, not a skip: the ordering checker lives in"; \
	  echo "       the sibling, so without it this gate verifies nothing."; \
	  exit 1; }
	python3 $(LAZILY_SPEC_DIR)/scripts/check-assertion-ordering.py --binding gd --root .

# CI-reachability guard (`#lzcheckcireachguard`, ported here by #lzgdcireach).
# Fails when `make check` runs a gate no CI workflow step reaches — the drift that
# hid #lzinteroppeerci in every binding for months. It guards ITSELF by being in
# `check`, so CI has to run it too or it reports itself missing.
#
# SCOPE HERE, stated because it differs from the nine siblings. This repo's CI is
# a SINGLE `make check` step, so every gate is reached transitively and this guard
# cannot catch a missing per-gate CI step — there are no per-gate steps to miss.
# What it does pin is the INVOCATION: narrow that step to `make test` and
# load-graph, conformance-coverage and assertion-ordering-check go unreached and
# this fires. Measured, not assumed — see the commit that added it.
ci-reach:
	./scripts/check-ci-reach.sh

check: test load-graph conformance-coverage assertion-ordering-check ci-reach

clean:
	rm -rf build addons/gdUnit4
