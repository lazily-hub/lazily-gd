## Canonical-fixture loader with a RUNTIME manifest.
##
## Every fixture this returns is recorded, at the moment it is opened, to the
## path in `LAZILY_CONFORMANCE_MANIFEST`. That recording is the evidence
## `scripts/check-conformance-coverage.sh` reads.
##
## Why runtime and not a source grep: a fixture named in a comment, or
## hand-transcribed into a test, is present in a grep while never being replayed.
## lazily-cpp's queue tests drifted exactly that way. Presence in source is not
## proof of replay; observing the read is.
##
## A missing manifest is missing EVIDENCE, not evidence of absence — it means the
## suite ran without the recorder attached, and reporting OK in that state is the
## vacuous green the guard exists to prevent.
class_name LazilyFixtureLoader
extends RefCounted

const DEFAULT_SPEC_DIR := "../lazily-spec/conformance"


static func spec_dir() -> String:
	var override := OS.get_environment("LAZILY_SPEC_CONFORMANCE_DIR")
	if override != "":
		return override
	# res:// is the repo root; the sibling checkout lives beside it on disk.
	return ProjectSettings.globalize_path("res://").path_join(DEFAULT_SPEC_DIR)


## Delegated to `LazilyBlockLedger`, which owns the evidence channel now that the
## manifest carries block records as well as fixture ids. One resolver, so the
## fixture ledger and the block ledger cannot end up writing to two files.
static func manifest_path() -> String:
	return LazilyBlockLedger.manifest_path()


static func corpus_available() -> bool:
	return DirAccess.dir_exists_absolute(spec_dir())


## Load one fixture by its corpus-relative id, e.g. "reactive-graph/foo.json".
##
## Returns an empty Dictionary and records NOTHING when the read fails: a
## manifest entry must mean "this run opened and parsed it", or coverage computed
## from the manifest is a claim about files nobody read.
static func load_fixture(fixture_id: String) -> Dictionary:
	var full := spec_dir().path_join(fixture_id)
	if not FileAccess.file_exists(full):
		push_error("lazily: canonical fixture not found: %s" % full)
		return {}
	var text := FileAccess.get_file_as_string(full)
	if text.is_empty():
		push_error("lazily: canonical fixture is empty: %s" % full)
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("lazily: canonical fixture is not a JSON object: %s" % full)
		return {}
	_record(fixture_id)
	# Rung 0 (#lzgdblockledger). Inventoried HERE, at the moment the fixture is
	# read, so the ledger lists what the corpus CARRIES rather than what a runner
	# happened to look at. An inventory built at assert time could only ever list
	# blocks a runner already found.
	LazilyBlockLedger.declare(fixture_id, parsed)
	return parsed as Dictionary


## A bare id line, one per opened fixture. Append-only; see
## `LazilyBlockLedger.append_line`.
static func _record(fixture_id: String) -> void:
	LazilyBlockLedger.append_line(fixture_id)
