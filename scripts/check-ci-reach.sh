#!/usr/bin/env bash
# CI-reachability guard (#lzcheckcireachguard).
#
# Fails the build when `make check` runs a gate that CI never reaches. That is the
# drift this guard exists for: someone adds a target to `check`, it passes locally
# forever, and no CI job ever executes it — which is exactly how #lzinteroppeerci
# happened. The interop peer, the single cross-binding wire-compatibility gate, was
# in every binding's `check` and in no binding's workflow, for months.
#
# It also exists because the obvious hand-audit is WRONG. Grepping the workflows
# for "make check" reported all nine bindings as covered; every one of those hits
# was a COMMENT. Comments are the reason this is a script and not a convention:
# only `run:` bodies count here, and comment lines inside them are stripped before
# anything is matched.
#
# WHAT IT PROVES
#
#   For every target in `check`'s prerequisite closure, at least one CI `run:`
#   step invokes the same program with the same distinguishing flags.
#
# WHAT IT DOES NOT PROVE
#
#   That CI runs it against the same inputs, in the same environment, or that the
#   command means the same thing there. Reach is a floor, not equivalence. The
#   sibling guards (conformance-coverage, assertion-keys, scenario-coverage) are
#   what prove a run examined anything.
#
# HOW A TARGET IS MATCHED
#
#   Recipes are read through `make -n`, so make variables are already expanded and
#   we compare real command lines rather than source text. `make -p` is
#   deliberately NOT used: it dumps the entire environment to stdout, which would
#   print every secret in the job's env into the CI log.
#
#   Each command is split on the shell's sequencing operators, redirections are
#   dropped, and the remainder is reduced to an ANCHOR: the program basename plus
#   its subcommands and flag NAMES (values dropped), with path arguments reduced to
#   basenames and bare path globs discarded. A target is reached when EVERY one of
#   its anchors is a subsequence of some CI command's token list, or when CI runs
#   `make <target>` — or `make <any ancestor of target>`, since that runs the
#   whole closure. Every, not any: a target that runs two gates and is
#   half-covered by CI is a gap, and "any" would report it green.
#
#   Keeping flag names in the anchor is what makes the guard falsifiable rather
#   than decorative: `go test -race` does not match a CI step that only runs
#   `go test -count=1`, so dropping the race job reddens this guard instead of
#   being absorbed by the plain test job.
#
#   An argument that is still a VARIABLE reference at this point — `$MANIFEST` in
#   a CI step, or a `$$VAR` a recipe leaves for the shell — names a value the
#   guard cannot resolve, so it becomes a WILDCARD matching exactly one token on
#   the other side (#lzcireachvaranchor). Make and CI routinely spell the same
#   path differently, one through an expanded `$(VAR)` and the other through the
#   environment, and they are the same command. Dropping the token instead, which
#   is what this used to do, lost the argument as well as its value and reported
#   a step that genuinely ran the gate as unreachable — a false RED that cost one
#   binding a hardcoded second spelling of the path plus a hand-written equality
#   assertion, which is a new drift surface invented to satisfy a guard whose job
#   is detecting drift. Arity still counts: `script.sh $A` does not match a CI
#   step that passes no argument at all.
#
#   Commands whose program is a shell builtin or a plain file/text utility carry no
#   gate, so they contribute no anchor. A target with no non-trivial command at all
#   (a mkdir-only reset step, say) is reported as carrying no gate and is not
#   required to appear in CI. It cannot fail a build, so it cannot hide one.
#
# THE EXCUSE LIST IS THE OTHER HALF OF THE DELIVERABLE
#
#   scripts/ci-reach.conf names the workflows that count and the targets that are
#   deliberately local-only, each with a reason. It is the one place a reader can
#   see what this binding does not enforce in CI, in the same spirit as
#   KNOWN_UNCOVERED. Excuses are checked in BOTH directions: an excused target that
#   CI turns out to reach fails too, so the list cannot rot into a list of things
#   that used to be true.
#
# AND THE CLOSURE'S MEMBERSHIP IS PINNED, ALSO IN BOTH DIRECTIONS
#
#   Everything above answers "is each target in the closure reached?". Until
#   #pinreachclosure nothing answered "are these the targets?" — so deleting a
#   prerequisite from the root's list made the gate stop being required and this
#   guard reported `OK — N-1 target(s) reached by CI` at exit 0 without naming the
#   target that left. `expected-closure-target` in the conf is compared by EXACT
#   SET EQUALITY against the walked closure, `expected-root-target` against the
#   root actually walked, and an `excuse` naming a target outside the closure is
#   an error rather than a silent no-op. The conf carries the reasoning and the
#   measurements; the rule here is that those are all membership facts about the
#   set every other number in this script describes, so they are reported
#   together and they are fatal.
set -euo pipefail

MAKE_BIN="${MAKE:-make}"
ROOT_TARGET="${CI_REACH_ROOT_TARGET:-check}"
CONF="${CI_REACH_CONF:-scripts/ci-reach.conf}"

if [ ! -f Makefile ]; then
	echo "check-ci-reach: no Makefile in $(pwd)" >&2
	exit 1
fi

# ---------------------------------------------------------------- configuration

workflows=()
workflow_count=0
excused_targets=()
excused_reasons=()
excuse_count=0
expected_targets=()
expected_count=0
expected_root=""
expected_nogate=()
expected_nogate_count=0

if [ -f "$CONF" ]; then
	while IFS= read -r line || [ -n "$line" ]; do
		line="${line%%$'\r'}"
		case "$line" in
		'#'* | '') continue ;;
		esac
		key="${line%%:*}"
		val="${line#*:}"
		val="$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
		case "$key" in
		workflow)
			workflows+=("$val")
			workflow_count=$((workflow_count + 1))
			;;
		excuse)
			tgt="${val%%[[:space:]]*}"
			reason="${val#"$tgt"}"
			reason="$(printf '%s' "$reason" | sed -e 's/^[[:space:]]*//')"
			if [ -z "$reason" ]; then
				echo "check-ci-reach: excuse for '$tgt' has no reason — an excuse without a reason is not an excuse" >&2
				exit 1
			fi
			excused_targets+=("$tgt")
			excused_reasons+=("$reason")
			excuse_count=$((excuse_count + 1))
			;;
		expected-closure-target)
			# One name per line, same grain as `excuse`, so dropping a pinned
			# target is a one-line reviewable diff rather than an edit inside a
			# list. No trailing text is allowed: a reason belongs on an excuse,
			# and silently ignoring the rest of the line is how a typo becomes a
			# target name nobody pinned.
			case "$val" in
			*[[:space:]]*)
				echo "check-ci-reach: expected-closure-target '$val' in $CONF carries more than one word." >&2
				echo "                One target name per line. This pin is a SET, not a list with notes;" >&2
				echo "                a name with trailing text would be compared as the whole string and" >&2
				echo "                could never match a real target." >&2
				exit 1
				;;
			'')
				echo "check-ci-reach: an empty expected-closure-target in $CONF names nothing" >&2
				exit 1
				;;
			esac
			for already in ${expected_targets[@]+"${expected_targets[@]}"}; do
				if [ "$already" = "$val" ]; then
					echo "check-ci-reach: expected-closure-target '$val' is pinned twice in $CONF." >&2
					echo "                A duplicate cannot change the set comparison, so it is a typo" >&2
					echo "                signal, not a fact — and it makes the count this guard reports" >&2
					echo "                disagree with the number of distinct targets pinned." >&2
					exit 1
				fi
			done
			expected_targets+=("$val")
			expected_count=$((expected_count + 1))
			;;
		expected-nogate-target)
			# The CLASSIFICATION pin. Membership says a target is still run;
			# it says nothing about whether the target still carries a gate, and
			# `no gate` targets are not required to appear in CI at all. Same
			# one-name-per-line grain and the same duplicate rejection.
			case "$val" in
			*[[:space:]]*)
				echo "check-ci-reach: expected-nogate-target '$val' in $CONF carries more than one word." >&2
				echo "                One target name per line; this pin is a SET." >&2
				exit 1
				;;
			'')
				echo "check-ci-reach: an empty expected-nogate-target in $CONF names nothing" >&2
				exit 1
				;;
			esac
			for already in ${expected_nogate[@]+"${expected_nogate[@]}"}; do
				if [ "$already" = "$val" ]; then
					echo "check-ci-reach: expected-nogate-target '$val' is pinned twice in $CONF" >&2
					exit 1
				fi
			done
			expected_nogate+=("$val")
			expected_nogate_count=$((expected_nogate_count + 1))
			;;
		expected-root-target)
			# Pinned separately because the root is not a member of its own
			# prerequisite list: it is the argument this whole walk starts from,
			# and `CI_REACH_ROOT_TARGET` can move it without touching the Makefile.
			if [ -n "$expected_root" ]; then
				echo "check-ci-reach: expected-root-target is set twice in $CONF ('$expected_root' then '$val')" >&2
				echo "                There is one root. Two pins mean one of them is not being checked." >&2
				exit 1
			fi
			if [ -z "$val" ]; then
				echo "check-ci-reach: an empty expected-root-target in $CONF names nothing" >&2
				exit 1
			fi
			expected_root="$val"
			;;
		*)
			echo "check-ci-reach: unknown key '$key' in $CONF" >&2
			exit 1
			;;
		esac
	done <"$CONF"
fi

if [ "$workflow_count" -eq 0 ]; then
	workflows=(".github/workflows/ci.yml")
	workflow_count=1
fi

for wf in "${workflows[@]}"; do
	if [ ! -f "$wf" ]; then
		echo "check-ci-reach: workflow '$wf' listed in $CONF does not exist" >&2
		exit 1
	fi
done

# ------------------------------------------------------- make target extraction

# A Makefile may set .RECIPEPREFIX to something other than tab (lazily-rs uses
# `>`), which puts recipe lines at column 0 where a rule line lives. Without this
# a recipe such as `>cargo test --features a:b` reads as a rule named `>cargo`.
RECIPE_PREFIX="$(awk -F= '/^[[:space:]]*\.RECIPEPREFIX[[:space:]]*[:+]?=/ {
	v = $2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); if (v != "") print substr(v, 1, 1); exit
}' Makefile)"

# Prerequisites of a target, straight from the Makefile source, with `\`
# continuations joined and trailing comments removed. Order-only prerequisites are
# dropped: they constrain ordering, not what runs.
prereqs_of() {
	awk -v target="$1" -v rp="$RECIPE_PREFIX" '
		BEGIN { pat = "^" target ":([^=]|$)"; if (rp == "") rp = "\t" }
		{
			line = $0
			# Only the ACTUAL recipe prefix marks a recipe line. Treating any
			# leading whitespace as one loses a rule that is merely indented,
			# which under a non-tab .RECIPEPREFIX is perfectly legal make and
			# collapses the whole closure to a single target. A continuation is
			# exempt: under the default tab prefix a wrapped prerequisite list is
			# normally tab-indented.
			if (!cont && substr(line, 1, 1) == rp) next
			sub(/^[[:space:]]+/, "", line)
			if (cont) {
				buf = buf " " line
				if (line ~ /\\[[:space:]]*$/) next
				cont = 0
				emit(buf)
				exit
			}
			if (line !~ pat) next
			buf = line
			if (line ~ /\\[[:space:]]*$/) { cont = 1; next }
			emit(buf)
			exit
		}
		function emit(s,   rest, n, i, parts) {
			gsub(/\\/, " ", s)
			sub(/#.*$/, "", s)
			rest = substr(s, index(s, ":") + 1)
			sub(/\|.*$/, "", rest)
			n = split(rest, parts, /[[:space:]]+/)
			for (i = 1; i <= n; i++) if (parts[i] != "") print parts[i]
		}
	' Makefile
}

# Is this name an explicit rule in the Makefile?
is_makefile_target() {
	awk -v target="$1" -v rp="$RECIPE_PREFIX" '
		BEGIN { pat = "^" target ":([^=]|$)"; if (rp == "") rp = "\t"; found = 0 }
		substr($0, 1, 1) == rp { next }
		{ line = $0; sub(/^[[:space:]]+/, "", line) }
		line ~ pat { found = 1; exit }
		END { exit found ? 0 : 1 }
	' Makefile
}

# Breadth-first closure of ROOT_TARGET's prerequisites, parents before children.
closure=""
queue="$ROOT_TARGET"
seen=" "
while [ -n "$queue" ]; do
	current="${queue%%$'\n'*}"
	if [ "$current" = "$queue" ]; then queue=""; else queue="${queue#*$'\n'}"; fi
	[ -n "$current" ] || continue
	case "$seen" in
	*" $current "*) continue ;;
	esac
	seen="$seen$current "
	closure="$closure$current"$'\n'
	while IFS= read -r dep; do
		[ -n "$dep" ] || continue
		if is_makefile_target "$dep"; then
			queue="$queue$dep"$'\n'
		fi
	done < <(prereqs_of "$current")
done

# ── the closure's MEMBERSHIP, before anything is said about it (#pinreachclosure)
#
# Every number printed below this point — reached, excused, no gate — is an
# assertion ABOUT this set. Until the set is the one somebody approved, those
# numbers describe a closure nobody agreed to, which is exactly how
# `OK — 6 target(s) reached by CI` came to be a passing verdict for a Makefile
# that had just stopped running `load-graph`. So membership is settled first.
#
# `LC_ALL=C` on both sorts is not decoration: `comm` compares under the
# collation its inputs were sorted in, and a locale that orders `-` differently
# from the sort that produced the other file makes it report spurious
# differences in both directions at once.
closure_sorted="$(printf '%s' "$closure" | sed '/^$/d' | LC_ALL=C sort -u)"
membership_status=0

# The root is pinned separately because it is not a member of its own
# prerequisite list — it is the argument this walk starts from. Renaming `check:`
# and leaving a stub is already caught by the vacuity rule at the bottom (the
# whole closure collapses to one gateless target), and pointing
# CI_REACH_ROOT_TARGET at a leaf already fails here because `make check` in CI
# stops being an ancestor of anything. This pin is what makes either failure say
# WHICH root was walked instead of leaving a reader to infer it from a target
# list that got shorter.
if [ -z "$expected_root" ]; then
	echo "check-ci-reach: $CONF pins no expected-root-target." >&2
	echo "                Add \`expected-root-target: $ROOT_TARGET\`. Without it a renamed or" >&2
	echo "                retargeted root silently changes what every number below is about." >&2
	membership_status=1
elif [ "$expected_root" != "$ROOT_TARGET" ]; then
	echo "check-ci-reach: this run walked the closure of '$ROOT_TARGET', but $CONF pins" >&2
	echo "                expected-root-target: $expected_root" >&2
	echo "                Either the root was retargeted (CI_REACH_ROOT_TARGET, or the" >&2
	echo "                \`ci-reach\` recipe) and should not have been, or the aggregate was" >&2
	echo "                deliberately renamed and the pin needs updating in the same commit." >&2
	membership_status=1
fi

# An absent pin has to be an ERROR, not a skip. A guard whose pin can be deleted
# to make it quiet is the pre-#pinreachclosure guard again, reachable by an edit
# smaller than the one it is defending against.
if [ "$expected_count" -eq 0 ]; then
	echo "check-ci-reach: $CONF pins no expected-closure-target, so nothing constrains" >&2
	echo "                WHICH targets 'make $ROOT_TARGET' has to run. Dropping a gate from its" >&2
	echo "                prerequisites would then be reported as OK with one fewer target" >&2
	echo "                reached, which is the defect this pin exists for." >&2
	echo "                Today's closure, paste-ready:" >&2
	while IFS= read -r t; do
		[ -n "$t" ] || continue
		echo "                  expected-closure-target: $t" >&2
	done <<<"$closure_sorted"
	membership_status=1
else
	pin_sorted="$(printf '%s\n' "${expected_targets[@]}" | LC_ALL=C sort -u)"

	# SET EQUALITY, reported as two separate findings because they mean opposite
	# things and have opposite remedies. A count comparison would collapse them
	# and pass a SWAP; a subset test in either direction alone passes the other
	# direction's drift. See the conf for why this is not a floor or a ceiling.
	dropped="$(comm -23 <(printf '%s\n' "$pin_sorted") <(printf '%s\n' "$closure_sorted") || true)"
	unpinned="$(comm -13 <(printf '%s\n' "$pin_sorted") <(printf '%s\n' "$closure_sorted") || true)"

	if [ -n "$dropped" ]; then
		echo "check-ci-reach: target(s) pinned in $CONF that 'make $ROOT_TARGET' NO LONGER RUNS:" >&2
		while IFS= read -r t; do
			[ -n "$t" ] || continue
			echo "  - $t" >&2
		done <<<"$dropped"
		echo >&2
		echo "                This is the shape of a gate going quiet: it left the prerequisite" >&2
		echo "                closure, so nothing runs it and this guard has nothing to check it" >&2
		echo "                against. TWO different things it can mean, and they are not" >&2
		echo "                interchangeable:" >&2
		echo "                  * you broke a gate — restore the prerequisite (or fix the" >&2
		echo "                    rename), and leave the pin alone." >&2
		echo "                  * you meant to retire it — delete its expected-closure-target" >&2
		echo "                    line in the SAME commit, where a reviewer can see the gate" >&2
		echo "                    leaving and say whether that was intended." >&2
		membership_status=1
	fi

	if [ -n "$unpinned" ]; then
		echo "check-ci-reach: target(s) run by 'make $ROOT_TARGET' that $CONF does not pin:" >&2
		while IFS= read -r t; do
			[ -n "$t" ] || continue
			echo "  - $t" >&2
		done <<<"$unpinned"
		echo >&2
		echo "                Harmless on its own — a new gate is good news — but an unpinned" >&2
		echo "                member is one a later commit can remove silently, and it is the" >&2
		echo "                half of set equality that stops a SWAP (one gate out, one in)" >&2
		echo "                from being absorbed. Add:" >&2
		while IFS= read -r t; do
			[ -n "$t" ] || continue
			echo "                  expected-closure-target: $t" >&2
		done <<<"$unpinned"
		membership_status=1
	fi
fi

# The other direction on excuses, symmetric with the reverse check KNOWN_UNCOVERED
# already does in check-conformance-coverage.sh ("lists 'X', which is not in the
# canonical corpus"). Before this, an excuse was only ever consulted while walking
# the closure, so one naming a target outside it — a typo, or a target that has
# since been retired — was a silent no-op: MEASURED at exit 0 reporting
# `0 excused` with an excuse for `clean` sitting in the conf. An excuse is a
# claim that something IS run locally and deliberately not in CI; when the named
# target is not run at all, the claim is false and the reason nobody can see is
# stale.
if [ "$excuse_count" -gt 0 ]; then
	excused_sorted="$(printf '%s\n' "${excused_targets[@]}" | LC_ALL=C sort -u)"
	phantom="$(comm -23 <(printf '%s\n' "$excused_sorted") <(printf '%s\n' "$closure_sorted") || true)"
	if [ -n "$phantom" ]; then
		echo "check-ci-reach: excuse(s) in $CONF naming a target 'make $ROOT_TARGET' does not run:" >&2
		while IFS= read -r t; do
			[ -n "$t" ] || continue
			echo "  - $t" >&2
		done <<<"$phantom"
		echo >&2
		echo "                An excuse says 'this gate runs locally and deliberately not in" >&2
		echo "                CI'. For a target outside the closure that says nothing, and it" >&2
		echo "                reads as coverage that does not exist. Either the target left the" >&2
		echo "                closure and the excuse should go with it, or the name is a typo" >&2
		echo "                and the real target is still unexcused." >&2
		membership_status=1
	fi
fi

if [ "$membership_status" -ne 0 ]; then
	exit 1
fi
# The OK line for this is NOT printed here. It is printed after the oracle below,
# because "these are the approved targets" is worth saying only once "make really
# runs these targets" has been established — and printing it first would announce
# a satisfied pin over a set the oracle is about to show does not run.

# `make -n` for a target emits its prerequisites' commands first, then its own.
# Asking make for the prerequisite list alone yields exactly that prefix — make
# applies the same de-duplication to both invocations — so removing it leaves the
# target's own recipe. Diagnostics make writes about targets it has nothing to do
# for are not commands and are dropped.
# A recipe line broken across physical lines with `\` reaches the shell as ONE
# command, and make -n prints it the way the Makefile spells it. Joining here is
# what keeps `VAR=x \` + `go test ./...` from being read as two commands, the
# second of which is where the whole gate lives.
join_continuations() {
	awk '
		{
			line = $0
			if (line ~ /\\[[:space:]]*$/) {
				sub(/\\[[:space:]]*$/, "", line)
				buf = buf line " "
				next
			}
			print buf line
			buf = ""
		}
		END { if (buf != "") print buf }
	'
}

dry_run() {
	"$MAKE_BIN" -n "$@" 2>/dev/null | grep -v -e '^make\[' -e '^make:' | join_continuations || true
}

own_commands() {
	local target="$1"
	local deps=()
	local dep_count=0
	while IFS= read -r dep; do
		[ -n "$dep" ] || continue
		if is_makefile_target "$dep"; then
			deps+=("$dep")
			dep_count=$((dep_count + 1))
		fi
	done < <(prereqs_of "$target")

	if [ "$dep_count" -eq 0 ]; then
		dry_run "$target"
		return
	fi
	local prefix
	prefix="$(dry_run "${deps[@]}" | wc -l)"
	dry_run "$target" | tail -n +"$((prefix + 1))"
}

# ── every recipe this guard reads comes from `make -n`, which can FAIL ────────
#
# `dry_run` above ends in `|| true` and discards stderr. That is RIGHT for the
# legitimate zero it exists for: a recipe whose every line is a make diagnostic
# selects nothing through `grep -v` and genuinely carries no command. It is also
# indistinguishable from `make -n` FAILING, which prints nothing to stdout and
# exits nonzero — so a target whose dry run failed reads as "recipe runs no
# checkable command", which this guard reports as `no gate` and does NOT require
# CI to reach.
#
# MEASURED as a false GREEN, not a misdiagnosis. Giving `test` one prerequisite
# with no rule (`test: import does-not-exist.stamp`) made `make -n test` exit 2
# with "No rule to make target 'does-not-exist.stamp'", `2>/dev/null` swallowed
# it, and this guard printed
#
#     no gate  test    recipe runs no checkable command
#     check-ci-reach: OK — 6 target(s) reached by CI, 0 excused, 2 carrying no gate
#
# at exit 0, while `test` — the target carrying the whole suite and its
# executed-count guard — silently stopped being required in CI. The aggregate
# vacuity check at the bottom of this script cannot see it: the other six targets
# still carry gates, so it stays satisfied. lazily-py measured this shape first.
#
# The reachability judgement that missed it is worth recording, because it reads
# as sound: no target in this Makefile has a file prerequisite, so no `make -n`
# here can fail. That is a property of the Makefile AS WRITTEN, and this guard's
# whole job is to survive the edit that changes it. Adding a stamp file, a
# generated header or a vendored directory as a prerequisite is an ordinary
# commit, and it disarms the guard without touching the guard.
#
# Probed HERE, in the MAIN shell, and deliberately NOT inside `dry_run`: that
# function runs inside `$(...)` in `own_commands`, so an `exit 1` there kills
# only the subshell and the caller reads back the same empty output it always
# did. The status has to be examined where it can still end the script.
#
# EVERY target in the closure, not just the root. The root alone does catch this
# instance — a bad prerequisite anywhere in the tree fails `make -n check` too —
# but a per-target probe names the target that broke instead of blaming the
# aggregate, and it still holds for a closure member whose own dry run fails
# while the root's does not.
while IFS= read -r target; do
	[ -n "$target" ] || continue
	if ! make_n_stderr="$("$MAKE_BIN" -n "$target" 2>&1 >/dev/null)"; then
		echo "check-ci-reach: \`$MAKE_BIN -n $target\` FAILED, so this guard cannot read that" >&2
		echo "                target's recipe. An unreadable recipe is EMPTY here, and an empty" >&2
		echo "                recipe reads as 'carrying no gate' — which is not required to" >&2
		echo "                appear in CI at all, so the target would silently stop being" >&2
		echo "                enforced while this guard reported OK. That is missing evidence," >&2
		echo "                not evidence of absence." >&2
		echo "                make said:" >&2
		if [ -n "$make_n_stderr" ]; then
			echo "$make_n_stderr" >&2
		else
			echo "                  (nothing on stderr; re-run \`$MAKE_BIN -n $target\` by hand)" >&2
		fi
		exit 1
	fi
done <<<"$closure"

# ------------------------------------------------------------- workflow scraping

# Command lines from every `run:` step. Comment lines inside a run body are
# stripped here — the whole reason this guard is a script.
ci_commands() {
	awk '
		function flush() { if (buf != "") { print buf; buf = "" } }
		{
			line = $0
			indent = match(line, /[^ ]/) - 1
			if (indent < 0) indent = 9999

			if (inblock) {
				if (line ~ /^[[:space:]]*$/) next
				if (indent <= block_indent) { flush(); inblock = 0 }
				else {
					sub(/^[[:space:]]+/, "", line)
					if (substr(line, 1, 1) == "#") next
					if (line ~ /\\[[:space:]]*$/) {
						sub(/\\[[:space:]]*$/, "", line)
						buf = buf " " line
						next
					}
					if (buf != "") { print buf " " line; buf = "" } else print line
					next
				}
			}

			if (line ~ /^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*[|>][-+]?[[:space:]]*$/) {
				inblock = 1
				block_indent = indent
				buf = ""
				next
			}
			if (line ~ /^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*[^|>[:space:]]/) {
				sub(/^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*/, "", line)
				print line
			}
		}
		END { flush() }
	' "$@"
}

# ------------------------------------------------------------------- normalizing

# Reduce command text to anchors, one per line, each a space-separated token list.
anchors() {
	awk '
		BEGIN {
			# Sentinel for an unresolvable variable reference. Deliberately not a
			# string any real argument can be.
			ANY = "\001any"
			split(": true false echo printf cd pushd popd mkdir rmdir rm cp mv ln touch " \
			      "export unset set local read eval exec trap wait sleep exit return " \
			      "if then else elif fi for while until do done case esac function " \
			      "test [ [[ pwd ls cat head tail sed awk grep egrep fgrep sort uniq " \
			      "wc tr cut paste tee xargs env dirname basename date git", t, / /)
			for (i in t) if (t[i] != "") trivial[t[i]] = 1
		}
		{
			n = split(split_unquoted($0), cmds, /\n/)
			for (i = 1; i <= n; i++) emit(cmds[i])
		}
		# Split on the shell'"'"'s sequencing operators, but ONLY outside quotes. Doing
		# this before quotes are stripped is what stops a `;` inside a message —
		# `echo "missing $(DIR); clone the sibling"` — from being read as a second
		# command and inventing an anchor for a gate that does not exist. That is a
		# false RED, so it costs a real target its verdict.
		function split_unquoted(s,   i, c, nxt, len, inq, q, out) {
			out = ""; inq = 0; q = ""; len = length(s)
			for (i = 1; i <= len; i++) {
				c = substr(s, i, 1)
				if (inq) {
					if (c == q) { inq = 0; q = "" }
					out = out c
					continue
				}
				if (c == "\"" || c == "'"'"'" || c == "`") { inq = 1; q = c; out = out c; continue }
				nxt = substr(s, i + 1, 1)
				if (c == ";") { out = out "\n"; continue }
				if ((c == "&" && nxt == "&") || (c == "|" && nxt == "|")) { out = out "\n"; i++; continue }
				if (c == "|") { out = out "\n"; continue }
				out = out c
			}
			return out
		}
		function emit(cmd,   m, j, tok, out, prog, started, parts) {
			gsub(/[`"'"'"']/, " ", cmd)
			gsub(/\$\(/, " ", cmd)
			gsub(/\$\{/, " ", cmd)
			gsub(/[(){}]/, " ", cmd)
			m = split(cmd, parts, /[[:space:]]+/)
			prog = ""
			out = ""
			started = 0
			for (j = 1; j <= m; j++) {
				tok = parts[j]
				if (tok == "" || tok == "\\") continue
				if (tok ~ /^[0-9]*>>?$/ || tok == "<" || tok ~ /^[0-9]+>&[0-9]+$/) break
				if (!started) {
					if (tok ~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue
					started = 1
					prog = tok
					sub(/.*\//, "", prog)
					if (prog == "" || (prog in trivial)) return
					out = prog
					continue
				}
				if (tok ~ /^-/) {
					sub(/=.*$/, "", tok)
					out = out " " tok
					continue
				}
				if (tok ~ /^\.{1,3}$/ || tok ~ /^\.{1,2}\/\.{0,3}$/) continue
				if (tok ~ /\//) {
					sub(/\/+$/, "", tok)
					sub(/.*\//, "", tok)
					if (tok == "" || tok ~ /^\.{1,3}$/) continue
				}
					# A token that is still a shell/make VARIABLE reference names a
					# value this guard cannot resolve — a CI step spelling a path as
					# "$LAZILY_CONFORMANCE_MANIFEST" and a Makefile recipe spelling the
					# same path through an expanded $(VAR) are the same command. Dropping
					# it (what this used to do) loses the ARGUMENT as well as its value,
					# so `script.sh <path>` no longer matched a CI step that really ran
					# `script.sh "$PATH"` and the target was reported unreachable. That is
					# a false RED, and it cost lazily-cpp a hardcoded second spelling of
					# the path plus a hand-written equality assertion to keep the two in
					# sync — a new drift surface invented to satisfy a guard that exists
					# to detect drift.
					#
					# Emit a WILDCARD instead: one token that matches one token, so arity
					# is preserved. `script.sh $A` still fails against a CI step that
					# passes no argument at all. This is the same looseness the normalizer
					# already applies to paths, which it reduces to basenames — reach is a
					# floor, not equivalence, exactly as the header says.
					if (substr(tok, 1, 1) == "$") { out = out " " ANY; continue }
				out = out " " tok
			}
			if (started && out != "") print out
		}
	'
}

# ── the ORACLE: does make actually RUN this closure? (#pinreachclosure) ───────
#
# `prereqs_of` above derives the closure by awk-scanning Makefile SOURCE TEXT for
# the first line matching `^<root>:`. It never asks make, and it does not
# evaluate make conditionals — so the awk closure and the set make really runs
# can be made to disagree, and then the membership pin is set-equal to a set that
# describes nothing.
#
# MEASURED HERE, not inherited. lazily-js found it; this is the same probe run
# against a byte-identical scratch copy of THIS Makefile, wrapping the real
# `check:` line:
#
#     ifeq ($(SKIP_SLOW),)
#     check: test load-graph conformance-coverage assertion-ordering-check ci-reach
#     else
#     check: test ci-reach
#     endif
#
# With `SKIP_SLOW=1`, `make -n check` runs ZERO `load_graph_check.gd` commands
# (1 on the honest branch), and this guard's verdict was `cmp -s` BYTE-IDENTICAL
# to the pristine healthy run at exit 0 — including, once the membership pin
# existed, its `closure membership OK — 8 target(s)` line. The pin passes that
# state BY CONSTRUCTION: the awk closure is a property of the source text, which
# is identical in both branches, so a set equality over it is constant too.
# `ifeq (0,1)` does the same with no variable to set at all, which is why this is
# not a "someone would have to run make oddly" problem.
#
# So the oracle is the load-bearing part and the pin is what gives it a name to
# report. It runs second only because it needs the readability probe above to
# have established that `make -n` works for every member.
#
# THE PROPERTY: if a target is genuinely in the root's prerequisite closure, then
# everything `make <target>` would run, `make <root>` would also run — make
# executes the target's whole subtree as part of the root's. So every anchor of
# `make -n <target>` must appear among the anchors of `make -n <root>`.
#
# Compared as ANCHORS, not as raw command lines, and that is not laxity here: the
# `test` recipe prints `$(LAZILY_CONFORMANCE_RUN_ID)`, a `:=` value built from
# `date +%N` and `$$`, so the raw text of that line DIFFERS between two make
# invocations and an exact line match would report a permanent false MISMATCH for
# the one target carrying the whole suite. `anchors` drops `printf` as trivial and
# reduces the rest to program + flag names, which is the same normalizer every
# other judgement in this script is made through.
#
# `make -n` only. `make -p` would dump the environment into the CI log (see the
# header) and it builds the default goal on the way.
root_run_anchors="$(dry_run "$ROOT_TARGET" | anchors | LC_ALL=C sort -u)"
oracle_status=0

while IFS= read -r target; do
	[ -n "$target" ] || continue
	# The root is skipped because the comparison would be against itself: a
	# tautology reports nothing, and leaving it in would invite a reader to
	# believe the root's own recipe was checked against something.
	[ "$target" = "$ROOT_TARGET" ] && continue

	oracle_missing=""
	while IFS= read -r a; do
		[ -n "$a" ] || continue
		# Deliberately NOT `printf ... | grep -qxF`: grep -q exits on the first
		# match, the producer takes SIGPIPE, and under `pipefail` the pipeline
		# then reports 141 — so the test INVERTS on a match, probabilistically,
		# below the pipe buffer. Same string-membership `case` the closure walk
		# above uses; a quoted variable in a case pattern matches literally.
		case $'\n'"$root_run_anchors"$'\n' in
		*$'\n'"$a"$'\n'*) ;;
		*) oracle_missing="$oracle_missing$a"$'\n' ;;
		esac
	done < <(dry_run "$target" | anchors | LC_ALL=C sort -u)

	if [ -n "$oracle_missing" ]; then
		echo "check-ci-reach: '$target' is in the closure this guard WALKED, but \`$MAKE_BIN -n $ROOT_TARGET\`" >&2
		echo "                does not run its commands:" >&2
		while IFS= read -r a; do
			[ -n "$a" ] || continue
			echo "                  $a" >&2
		done <<<"$oracle_missing"
		oracle_status=1
	fi
done <<<"$closure"

if [ "$oracle_status" -ne 0 ]; then
	echo >&2
	echo "                The closure above is read from Makefile SOURCE TEXT and does not" >&2
	echo "                evaluate make conditionals, so this is the two disagreeing: the" >&2
	echo "                target is pinned and reported as reached, and make runs none of" >&2
	echo "                it. Look for an \`ifeq\`/\`ifdef\` around '$ROOT_TARGET''s prerequisite" >&2
	echo "                list with a second, shorter spelling — or for an environment" >&2
	echo "                variable that selects one. Every other number this guard prints" >&2
	echo "                would be about targets that do not run." >&2
	exit 1
fi

echo "check-ci-reach: closure oracle OK — \`$MAKE_BIN -n $ROOT_TARGET\` runs the commands of every walked target"
echo "check-ci-reach: closure membership OK — $expected_count target(s), exactly the set pinned in $CONF, root '$ROOT_TARGET'"

# --------------------------------------------------------------------- matching

ci_raw="$(mktemp)"
ci_anchor="$(mktemp)"
trap 'rm -f "$ci_raw" "$ci_anchor"' EXIT
ci_commands "${workflows[@]}" >"$ci_raw"
anchors <"$ci_raw" | sort -u >"$ci_anchor"

if [ ! -s "$ci_anchor" ]; then
	echo "check-ci-reach: no run: steps found in ${workflows[*]} — a guard with an empty haystack passes everything" >&2
	exit 1
fi

# Does CI contain a command whose tokens contain this anchor as an in-order
# subsequence? Extra flags and arguments on the CI side are fine; missing ones are
# not.
anchor_reached() {
	awk -v want="$1" '
		BEGIN { ANY = "\001any"; wn = split(want, w, / /) }
		{
			hn = split($0, h, / /)
			wi = 1
			# A wildcard on EITHER side matches, because either side may be the
			# one that spelled the argument through a variable.
			for (hi = 1; hi <= hn && wi <= wn; hi++)
				if (h[hi] == w[wi] || h[hi] == ANY || w[wi] == ANY) wi++
			if (wi > wn) { found = 1; exit }
		}
		END { exit found ? 0 : 1 }
	' "$ci_anchor"
}

# CI invoking the target through make counts as reach without any anchor work.
make_invokes() {
	awk -v target="$1" '
		{
			n = split($0, t, / /)
			if (t[1] != "make") next
			for (i = 2; i <= n; i++) if (t[i] == target) { found = 1; exit }
		}
		END { exit found ? 0 : 1 }
	' "$ci_anchor"
}

# ...and so does CI invoking an ANCESTOR of it, because `make <ancestor>` runs
# every prerequisite in that ancestor's closure. Reach is definitional here: if a
# CI step runs `make check` then make runs `check`'s whole tree, and reporting a
# gate inside it as unreachable is a false RED, not a finding.
#
# This is not the anchor path being loosened. `make_invokes` above already
# treated a direct `make <target>` as reach; the only thing missing was that the
# relation is TRANSITIVE through the prerequisite graph the guard has already
# computed.
#
# WHAT THIS COSTS, stated rather than discovered later: for a binding whose CI
# runs the aggregate in one step, every gate becomes reached trivially and this
# guard stops being able to catch a missing CI step — because there is no per-gate
# CI step to miss. What it still pins there is the INVOCATION: narrow that single
# step from `make check` to `make test` and the gates outside `test`'s closure go
# unreached and this guard fires. Measured when this landed: none of the nine
# sibling bindings invokes `make check` from a `run:` step (their CI runs the
# underlying commands per gate), so for all nine this changes nothing at all —
# lazily-gd, whose CI is a single `make check`, is the binding it exists for.
make_invokes_ancestor() {
	local target="$1" ancestor
	while IFS= read -r ancestor; do
		[ -n "$ancestor" ] || continue
		[ "$ancestor" = "$target" ] && continue
		if make_invokes "$ancestor" && in_closure_of "$ancestor" "$target"; then
			return 0
		fi
	done <<<"$closure"
	return 1
}

# Is `descendant` in `ancestor`'s prerequisite closure? Breadth-first over the
# same `prereqs_of` the main closure is built from, so there is one notion of
# "prerequisite" in this script rather than two that can disagree.
in_closure_of() {
	local ancestor="$1" descendant="$2" seen="" queue="$ancestor" current prereq
	while [ -n "$queue" ]; do
		current="${queue%%$'\n'*}"
		if [ "$current" = "$queue" ]; then queue=""; else queue="${queue#*$'\n'}"; fi
		[ -n "$current" ] || continue
		case $'\n'"$seen" in *$'\n'"$current"$'\n'*) continue;; esac
		seen="$seen$current"$'\n'
		[ "$current" = "$descendant" ] && return 0
		while IFS= read -r prereq; do
			[ -n "$prereq" ] || continue
			queue="$queue$prereq"$'\n'
		done < <(prereqs_of "$current")
	done
	return 1
}

is_excused() {
	local t="$1" i
	for i in "${!excused_targets[@]}"; do
		[ "${excused_targets[$i]}" = "$t" ] && return 0
	done
	return 1
}

excuse_reason() {
	local t="$1" i
	for i in "${!excused_targets[@]}"; do
		if [ "${excused_targets[$i]}" = "$t" ]; then
			printf '%s' "${excused_reasons[$i]}"
			return
		fi
	done
}

unreached=""
unreached_count=0
stale=""
stale_count=0
nogate=""
nogate_count=0
reached=0
excused_ok=0

while IFS= read -r target; do
	[ -n "$target" ] || continue

	target_anchors="$(own_commands "$target" | anchors | sort -u || true)"

	if [ -z "$target_anchors" ]; then
		nogate="$nogate$target"$'\n'
		nogate_count=$((nogate_count + 1))
		continue
	fi

	hit=1
	missing_anchors=""
	if ! make_invokes "$target" && ! make_invokes_ancestor "$target"; then
		while IFS= read -r a; do
			[ -n "$a" ] || continue
			if ! anchor_reached "$a"; then
				hit=0
				missing_anchors="$missing_anchors$a"$'\n'
			fi
		done <<<"$target_anchors"
	fi

	if is_excused "$target"; then
		if [ "$hit" -eq 1 ]; then
			stale="$stale$target"$'\n'
			stale_count=$((stale_count + 1))
		else
			excused_ok=$((excused_ok + 1))
			printf 'excused  %-32s %s\n' "$target" "$(excuse_reason "$target")"
		fi
		continue
	fi

	if [ "$hit" -eq 1 ]; then
		reached=$((reached + 1))
		printf 'reached  %s\n' "$target"
	else
		unreached="$unreached$target"$'\n'
		unreached_count=$((unreached_count + 1))
		printf 'MISSING  %s\n' "$target"
		while IFS= read -r a; do
			[ -n "$a" ] || continue
			printf '           no CI run: step matches `%s`\n' "$a"
		done <<<"$missing_anchors"
	fi
done <<<"$closure"

while IFS= read -r target; do
	[ -n "$target" ] || continue
	printf 'no gate  %-32s recipe runs no checkable command\n' "$target"
done <<<"$nogate"

# ── the CLASSIFICATION pin (#pinreachclosure) ─────────────────────────────────
#
# Membership says a target is still RUN. It cannot say the target still carries a
# GATE — and a `no gate` target is not required to appear in CI at all, so
# reclassification is a second way to stop enforcing something while every count
# stays plausible.
#
# MEASURED on the byte-identical scratch copy: replacing `load-graph`'s whole
# recipe with `@true` and keeping its name left the membership pin satisfied at
# 8/8 and printed
#
#     no gate  load-graph                       recipe runs no checkable command
#     check-ci-reach: OK — 6 target(s) reached by CI, 0 excused, 2 carrying no gate
#
# at exit 0 — the SAME verdict shape this script's own header records as the
# dry_run false green it already fixed, arrived at from a different direction.
#
# The empty set is a legitimate value here and needs no declaration, which is why
# this pin has no "you must pin something" rung like the closure pin does: a conf
# with no expected-nogate-target asserts that EVERY closure member carries a
# gate, and deleting this file's one line therefore fails CLOSED — `check` is
# discovered as no-gate and matches nothing pinned. There is no way to spell this
# pin that makes the guard quieter.
if [ "$expected_nogate_count" -gt 0 ]; then
	nogate_pin_sorted="$(printf '%s\n' "${expected_nogate[@]}" | LC_ALL=C sort -u)"
else
	nogate_pin_sorted=""
fi
nogate_found_sorted="$(printf '%s' "$nogate" | sed '/^$/d' | LC_ALL=C sort -u)"

nogate_new="$(comm -13 <(printf '%s\n' "$nogate_pin_sorted" | sed '/^$/d') \
	<(printf '%s\n' "$nogate_found_sorted" | sed '/^$/d') || true)"
nogate_gone="$(comm -23 <(printf '%s\n' "$nogate_pin_sorted" | sed '/^$/d') \
	<(printf '%s\n' "$nogate_found_sorted" | sed '/^$/d') || true)"

# A guard that examined nothing must not report OK — the same vacuity rule the
# conformance guards apply (#lzvacuousrun).
if [ "$((reached + excused_ok + unreached_count))" -eq 0 ]; then
	echo "check-ci-reach: '$ROOT_TARGET' has no prerequisite target carrying a gate — nothing was verified" >&2
	exit 1
fi

status=0

# Reported before the reach findings, because a reclassification changes what
# `reached` and `no gate` are counting in the first place.
if [ -n "$nogate_new" ]; then
	echo >&2
	echo "check-ci-reach: target(s) now carrying NO GATE that $CONF does not pin as gateless:" >&2
	while IFS= read -r t; do
		[ -n "$t" ] || continue
		echo "  - $t" >&2
	done <<<"$nogate_new"
	echo >&2
	echo "                A gateless target is not required to appear in CI, so this is a" >&2
	echo "                target that has stopped being enforced while still being listed as" >&2
	echo "                a prerequisite. Two things it can mean:" >&2
	echo "                  * its recipe was emptied or reduced to shell builtins — restore" >&2
	echo "                    the command that made it a gate." >&2
	echo "                  * it was always meant to be a plain aggregate or setup step —" >&2
	echo "                    add \`expected-nogate-target: <t>\` in the SAME commit, where a" >&2
	echo "                    reviewer sees a gate being reclassified and can object." >&2
	status=1
fi

if [ -n "$nogate_gone" ]; then
	echo >&2
	echo "check-ci-reach: target(s) pinned as gateless in $CONF that are NOT gateless now:" >&2
	while IFS= read -r t; do
		[ -n "$t" ] || continue
		echo "  - $t" >&2
	done <<<"$nogate_gone"
	echo >&2
	echo "                Usually good news — the target grew a real command, and its reach" >&2
	echo "                is now checked against CI like any other gate. Drop its" >&2
	echo "                expected-nogate-target line. If instead the target left the" >&2
	echo "                closure entirely, the membership pin above names that separately." >&2
	status=1
fi

if [ "$stale_count" -gt 0 ]; then
	echo >&2
	while IFS= read -r t; do
		[ -n "$t" ] || continue
		echo "check-ci-reach: '$t' is excused in $CONF but CI DOES reach it — remove the excuse" >&2
	done <<<"$stale"
	status=1
fi

if [ "$unreached_count" -gt 0 ]; then
	echo >&2
	echo "check-ci-reach: $unreached_count target(s) run by 'make $ROOT_TARGET' that no CI run: step reaches:" >&2
	while IFS= read -r t; do
		[ -n "$t" ] || continue
		echo "  - $t" >&2
	done <<<"$unreached"
	echo >&2
	echo "Add a CI step that runs it, or add an excuse with a reason to $CONF." >&2
	status=1
fi

if [ "$status" -eq 0 ]; then
	echo "check-ci-reach: classification OK — $nogate_count gateless target(s), exactly the set pinned in $CONF"
	echo "check-ci-reach: OK — $reached target(s) reached by CI, $excused_ok excused, $nogate_count carrying no gate"
fi
exit "$status"
