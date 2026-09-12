## Assertion-block inventory and bind ledger (#lzgdblockledger, #lznullformblind).
##
## Rung 0 of the conformance ladder. Every rung ABOVE this one is scoped to a
## block a runner already bound — `_check`'s fail-closed default, for instance,
## reports an unmodelled KEY but only inside a block something reads. A block no
## runner binds is not caught one rung up; it reports NOTHING AT ALL, because
## nothing reads its keys. Measured here before this file existed: falsifying
## every value in `scope_teardown_equals_fold_of_disposals.json`'s top-level
## `expected` — `observationally_equal` naming scenarios that do not exist,
## `dependents_of.topic` 999, `observed_by` `["bogus"]` — left `make check` GREEN
## at exit 0. Deleting the block outright also left it green.
##
## So the loader inventories every assertion-bearing block a fixture carries at
## READ time (`declare`), each runner books the ones it asserts (`bind`), and
## `scripts/check-conformance-coverage.sh` fails on any inventoried block nothing
## bound. The inventory is the positive evidence: without it, zero declared
## blocks means zero unbound blocks, which reports OK having compared nothing
## (#lzvacuousrun).
##
## Content-keyed, never name-keyed. A runner cannot satisfy the ledger by
## recognising the WORD `expect`; it has to bind the block whose bytes the loader
## inventoried.
class_name LazilyBlockLedger
extends RefCounted

## Every spelling the corpus uses for an executable output claim, as the UNION of
## what the family's bindings track — the same five `lazily-spec`'s
## `check-corpus-floors.mjs` pins. Maximal on purpose: a narrower set leaves the
## difference unguarded, and `expect_initial` / `expect_after` blocks elsewhere in
## the corpus are exactly the ones a three-name pin would let be deleted in
## silence. gd's opened set carries only `expect` and `expected` today, which is
## why all three of lazily-spec's walk rows report the same 136 for gd — but the
## set is the contract, not the observation.
const BLOCK_NAMES: Array[String] = [
	"assertions",
	"expect",
	"expect_after",
	"expect_initial",
	"expected",
]

# ── the digest rule, pinned DELIBERATELY (see also the python twin) ───────────
#
# lazily-cs keys its digest on `JsonElement.GetRawText()` — a number folded by
# its RAW LEXICAL FORM. That rule CANNOT be copied here: Godot's JSON parser
# hands back a parsed tree with no per-node access to the source text, and
# reports every number as TYPE_FLOAT (`3` and `3.0` are indistinguishable
# afterwards). `tests/latest_durable_projection_test.gd` already carries a
# `_normalize_numbers` helper for the same reason.
#
# The first rule attempted here was "integer when whole, else `%.17e`". It was
# MEASURED against Godot 4.7.2 before being written, and it is unusable twice
# over:
#
#   1. GDScript's `%` operator does not implement `%e` AT ALL. `"%.17e" % 1.5`
#      returns the literal string `"%.17e"`. Every non-whole number in the corpus
#      would have folded to one constant — distinct claims collapsing into one
#      digest, silently, in the guard built to detect exactly that.
#   2. `1e-320` compares EQUAL to zero after Godot parses it, so it would have
#      taken the whole-number branch and folded to `0` while python folded it as
#      a subnormal.
#
# So numbers are folded by their IEEE-754 binary64 BITS instead — exact,
# lossless, and free of any dependence on either side's float formatter.
# Verified byte-for-byte against `struct.pack("<d", v)` for `0`, `-0`, `3`,
# `3.0`, `1.5`, `-0.125`, `101`, `9007199254740993` (both sides round the
# inexact integer to the same double), `1e300` and `0.1`.
#
# ONE divergence survives and is guarded rather than hidden: Godot's JSON parser
# flushes magnitudes below the smallest normal double to zero (`1e-320` parses to
# `0`), where python keeps the subnormal. The python twin REFUSES such a value
# with a named error instead of hashing it, so the day the corpus grows one the
# build fails loudly rather than the two sides disagreeing in silence. No number
# in gd's opened set is affected: all 240 are whole and below 2^53.
const FNV_PRIME := 0x01000193
## Two independent 32-bit lanes rather than one 64-bit hash. GDScript has no
## unsigned 64-bit integer, so a real FNV-1a-64 would depend on signed int64
## multiplication wrapping; masking each lane to 32 bits after every step needs
## no such assumption and is reproduced exactly in python. The second basis is
## written as the XOR expression rather than its value so both sides are visibly
## the same constant.
const LANE0_BASIS := 0x811C9DC5
const LANE1_BASIS := 0x811C9DC5 ^ 0x5BF03635
const U32 := 0xFFFFFFFF


## Content digest of one assertion block, as 16 lowercase hex characters.
static func digest(block: Dictionary) -> String:
	var stream := PackedByteArray()
	_feed(stream, block)
	return "%08x%08x" % [_fnv(stream, LANE0_BASIS), _fnv(stream, LANE1_BASIS)]


static func _fnv(bytes: PackedByteArray, basis: int) -> int:
	var h := basis
	for b in bytes:
		h = (h ^ b) & U32
		h = (h * FNV_PRIME) & U32
	return h


## Type-TAGGED canonical byte stream. The tags are what keep `{"a": 1}` and
## `{"a": "1"}` apart: an untagged stream would fold a number and its own
## spelling as a string onto one digest, and two different claims would read as
## one.
##
## Keys are sorted by code point, matching python's `sorted()`, so a fixture that
## reorders a block's keys is still the same block — rather than a new one on
## whichever side happens to preserve document order.
static func _feed(out: PackedByteArray, value: Variant) -> void:
	match typeof(value):
		TYPE_DICTIONARY:
			var d := value as Dictionary
			var keys: Array = d.keys()
			keys.sort()
			out.append_array("{".to_utf8_buffer())
			for k: Variant in keys:
				out.append_array(String(k).to_utf8_buffer())
				out.append_array("=".to_utf8_buffer())
				_feed(out, d[k])
			out.append_array("}".to_utf8_buffer())
		TYPE_ARRAY:
			out.append_array("[".to_utf8_buffer())
			for item: Variant in (value as Array):
				_feed(out, item)
			out.append_array("]".to_utf8_buffer())
		TYPE_STRING, TYPE_STRING_NAME:
			out.append_array("s".to_utf8_buffer())
			out.append_array(String(value).to_utf8_buffer())
		TYPE_BOOL:
			out.append_array(("b1" if bool(value) else "b0").to_utf8_buffer())
		TYPE_INT, TYPE_FLOAT:
			out.append_array("n".to_utf8_buffer())
			var f := float(value)
			if f == 0.0:
				# `-0.0` and `0` are ONE claim. The literal is +0.0, so this
				# assignment normalises the sign bit that `encode_double` would
				# otherwise fold into a different digest on one side only:
				# python's `json` reads `-0` as the int 0 (sign gone) while Godot
				# reads it as -0.0 (sign kept).
				f = 0.0
			var bits := PackedByteArray()
			bits.resize(8)
			bits.encode_double(0, f)
			out.append_array(bits)
		_:
			# TYPE_NIL and anything else a JSON document cannot carry.
			out.append_array("z".to_utf8_buffer())


## Every assertion-block SITE a parsed fixture carries, as
## `[[bucket, digest, path], ...]`.
##
## An OBJECT-valued block is one site under its own name. An ARRAY-valued block
## is one site PER plain-object element, bucketed `name[]` — gd's opened set
## carries none of those today, which is what makes its three walk rows
## identical, but the rule is here so the first one to arrive is inventoried by
## the change that adds it rather than by the change that later notices.
##
## The walk descends INTO a block as well as past it, mirroring
## `lazily-spec`'s maximal rule. No block in the corpus nests another today, so
## this changes no count.
static func declare_sites(doc: Variant) -> Array:
	var out: Array = []
	_walk(doc, "", out)
	return out


static func _walk(node: Variant, path: String, out: Array) -> void:
	match typeof(node):
		TYPE_ARRAY:
			var arr := node as Array
			for i in arr.size():
				_walk(arr[i], "%s[%d]" % [path, i], out)
		TYPE_DICTIONARY:
			var d := node as Dictionary
			for k: Variant in d.keys():
				var key := String(k)
				var child: Variant = d[key]
				var where := path + "." + key
				if BLOCK_NAMES.has(key):
					if typeof(child) == TYPE_DICTIONARY:
						out.append([key, digest(child as Dictionary), where])
					elif typeof(child) == TYPE_ARRAY:
						var items := child as Array
						for i in items.size():
							if typeof(items[i]) == TYPE_DICTIONARY:
								out.append([
									key + "[]",
									digest(items[i] as Dictionary),
									"%s[%d]" % [where, i],
								])
				_walk(child, where, out)


# ── the evidence channel ──────────────────────────────────────────────────────


## ABSOLUTE path, from the environment, or a repo-relative default.
##
## The recorder runs inside the Godot process, whose working directory is not the
## repo root — a relative path silently writes the manifest somewhere nothing
## reads, and the guard then fails with "missing evidence" while the suite is
## green. `make test` exports an absolute path for this reason.
static func manifest_path() -> String:
	var p := OS.get_environment("LAZILY_CONFORMANCE_MANIFEST")
	if p != "":
		return p
	return ProjectSettings.globalize_path("res://build/conformance-fixtures-loaded.txt")


## Append-only, one record per line, flushed per entry.
##
## Appending rather than rewriting matters: gdUnit4 may run suites in separate
## passes, and a rewrite would leave the manifest describing only the last one.
static func append_line(line: String) -> void:
	var path := manifest_path()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("lazily: cannot open conformance manifest for append: %s" % path)
		return
	f.seek_end()
	f.store_line(line)
	f.close()


## Inventory every block the fixture carries, at the moment it is read.
##
## Emitted at LOAD time and not at assert time on purpose: an inventory built
## where the runner asserts could only ever list blocks the runner already found,
## which is the tautology this rung exists to break.
static func declare(fixture_id: String, doc: Variant) -> void:
	for site: Array in declare_sites(doc):
		append_line("blocks-declared\t%s\t%s\t%s|%s" % [site[0], site[1], fixture_id, site[2]])


## Book one block as BOUND — "a runner asserted this content".
##
## Keyed by digest, so it does not matter which runner, which fixture, or which
## spelling of the block name reached it; two sites carrying identical bytes are
## one claim and one bind satisfies both.
static func bind(block: Dictionary) -> void:
	append_line("blocks-bound\t%s" % digest(block))
