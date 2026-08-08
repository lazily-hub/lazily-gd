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


static func manifest_path() -> String:
	var p := OS.get_environment("LAZILY_CONFORMANCE_MANIFEST")
	if p != "":
		return p
	return ProjectSettings.globalize_path("res://build/conformance-fixtures-loaded.txt")


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
	return parsed as Dictionary


## Append-only, one id per line, flushed per entry.
##
## Appending rather than rewriting matters: gdUnit4 may run suites in separate
## passes, and a rewrite would leave the manifest describing only the last one.
static func _record(fixture_id: String) -> void:
	var path := manifest_path()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("lazily: cannot open conformance manifest for append: %s" % path)
		return
	f.seek_end()
	f.store_line(fixture_id)
	f.close()
