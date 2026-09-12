## Cross-side pin for the assertion-block digest rule (#lzgdblockledger).
##
## `scripts/check-conformance-coverage.sh` already compares the GDScript digest
## against its python twin on every run — not just the two cardinalities but the
## whole site -> digest MAP, over all 136 blocks in the opened set. That is the
## strongest check available, and it is why a twin that hashed differently but
## consistently cannot pass.
##
## It only exercises the value domain the corpus HAPPENS to carry, though: today
## every one of the 240 numbers in those blocks is a whole integer below 2^53,
## every key is ASCII, and no block nests an array of objects. The lanes below
## are therefore unexercised by the corpus and unguarded by the map comparison —
## so they are pinned here against vectors computed by the python twin and
## committed, rather than left to be discovered the day the corpus grows one.
##
## These vectors are not cosmetic. The rule they pin replaced an earlier one,
## "integer when whole, else `%.17e`", which was MEASURED against Godot 4.7.2 and
## found unusable twice over: GDScript's `%` operator does not implement `%e` at
## all (`"%.17e" % 1.5` returns the literal string `"%.17e"`, folding every
## non-whole number onto one digest), and `1e-320` compares equal to zero after
## Godot parses it. Numbers are folded by their IEEE-754 binary64 bits instead.
##
## If one of these reddens after a Godot upgrade, the engine changed how it
## encodes doubles, sorts keys, or encodes UTF-8 — and the python twin in
## `check-conformance-coverage.sh` must be brought back into agreement in the
## same change, not have its expectation retyped.
extends GdUnitTestSuite

## `[json text, expected 16-hex digest]`, digests produced by the python twin.
const VECTORS: Array = [
	# The degenerate block. A digest rule that returned "" for it would make
	# every empty block indistinguishable from a missing one.
	["{}", "5465b82568e85fc4"],
	# TYPE TAGS: a number and its own spelling as a string are different claims.
	# An untagged stream folds these together, which is the single most likely
	# way for two distinct expectations to read as one.
	["{\"value\":101}", "786f1710d2d8820b"],
	["{\"value\":\"101\"}", "6d35dc04c863059d"],
	["{\"a\":true,\"b\":false}", "d83348c160316f68"],
	["{\"a\":null}", "d39f8e75b08d0a1e"],
	# NON-WHOLE and extreme numbers — the lane the corpus does not exercise and
	# the lane the rejected `%.17e` rule would have collapsed.
	["{\"n\":1.5}", "f25aba79dbc6c842"],
	["{\"n\":-0.125}", "2910998110023e4a"],
	# Inexact as an integer: both sides must round the decimal token to the SAME
	# double rather than one keeping an exact big integer.
	["{\"n\":9007199254740993}", "b470c52583f0ba2e"],
	["{\"n\":1e300}", "bab82c681380d287"],
	# Arrays, and an array of objects — the `name[]` bucket's value shape.
	["{\"order\":[\"watch_b\",\"b\",\"a\"]}", "c8bf21f48c2d87ed"],
	["{\"nested\":[{\"k\":1},{\"k\":2}]}", "3332a196066cc929"],
	# Non-ASCII, to pin that both sides hash UTF-8 bytes.
	["{\"uni\":\"naïve ✓\"}", "df9017ec66edad87"],
]


func test_digest_matches_the_python_twin() -> void:
	assert_int(VECTORS.size()).override_failure_message(
		"no digest vectors to check — this suite would pass having compared nothing"
	).is_greater(0)
	for vector: Array in VECTORS:
		var text: String = vector[0]
		var parsed: Variant = JSON.parse_string(text)
		assert_int(typeof(parsed)).override_failure_message(
			"vector %s is not parseable as a JSON object" % text
		).is_equal(TYPE_DICTIONARY)
		assert_str(LazilyBlockLedger.digest(parsed as Dictionary)).override_failure_message(
			"digest rule drifted from the python twin for %s" % text
		).is_equal(vector[1])


## Key ORDER is not part of a block's identity.
##
## Both sides sort keys before hashing, so a fixture that reorders a block's keys
## is still the same block. Without this, a corpus reformatting would read as
## every reordered block becoming a new one on whichever side preserved document
## order — and the digest dimension would report a corpus-wide change that did
## not happen.
func test_key_order_does_not_change_the_digest() -> void:
	var a: Variant = JSON.parse_string("{\"a\":1,\"b\":2}")
	var b: Variant = JSON.parse_string("{\"b\":2,\"a\":1}")
	assert_str(LazilyBlockLedger.digest(a as Dictionary)).is_equal(
		LazilyBlockLedger.digest(b as Dictionary)
	)
	assert_str(LazilyBlockLedger.digest(a as Dictionary)).is_equal("fb4efc17042c57a2")


## `-0` and `0` are ONE claim.
##
## python's `json` reads `-0` as the int 0 and loses the sign; Godot reads it as
## -0.0 and keeps it. `encode_double` would then fold the same claim to two
## different digests on the two sides, and every site in the corpus would read as
## unbound with no hint why. The rule normalises the sign bit; this is the
## assertion that keeps it normalised.
func test_negative_zero_folds_onto_zero() -> void:
	var neg: Variant = JSON.parse_string("{\"n\":-0.0}")
	var pos: Variant = JSON.parse_string("{\"n\":0}")
	assert_str(LazilyBlockLedger.digest(neg as Dictionary)).is_equal(
		LazilyBlockLedger.digest(pos as Dictionary)
	)
	assert_str(LazilyBlockLedger.digest(pos as Dictionary)).is_equal("eeb9f38e4ae4c045")


## The walk's own shape, independent of any fixture.
##
## An object-valued block is one site; an array-valued block is one site per
## plain-object element under the `name[]` bucket; a non-object element declares
## nothing. gd's opened set carries no array-valued block today — which is
## exactly why this is asserted on a synthetic document rather than left to the
## corpus to cover.
func test_walk_buckets_object_and_array_blocks() -> void:
	var doc: Variant = JSON.parse_string("""
		{
			"steps": [
				{"expect": {"value": 1}},
				{"expect": [{"emitted": "a"}, 7, {"emitted": "b"}]},
				{"op": {"type": "cell"}}
			],
			"expected": {"final_state": {"read": {"x": 1}}}
		}
	""")
	assert_int(typeof(doc)).is_equal(TYPE_DICTIONARY)
	var sites: Array = LazilyBlockLedger.declare_sites(doc)
	var seen: Array = []
	for site: Array in sites:
		seen.append("%s %s" % [site[0], site[2]])
	seen.sort()
	assert_array(seen).is_equal([
		"expect .steps[0].expect",
		"expect[] .steps[1].expect[0]",
		"expect[] .steps[1].expect[2]",
		"expected .expected",
	])
