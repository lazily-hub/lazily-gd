# lazily-gd — build, test, and verification targets.

.PHONY: all check test gdunit4 import clean

GODOT ?= godot
REPORTS := build/reports

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
	@$(GODOT) --headless --path . --import >/dev/null 2>&1 || true

test: import
	@mkdir -p $(REPORTS)
	@set -o pipefail; $(GODOT) --headless --path . \
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

check: test

clean:
	rm -rf build addons/gdUnit4
