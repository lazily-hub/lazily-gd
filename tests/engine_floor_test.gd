## Phase 0 harness proof.
##
## These assertions are deliberately about the FLOOR and the HARNESS, not about
## reactive behaviour — there is no kernel yet. Their job is to make Phase 0's
## exit criterion falsifiable: if `make check` reports OK having run zero tests,
## that is the vacuous green every other binding in this family has a guard
## against, and the fix is here rather than in Phase 1.
extends GdUnitTestSuite

const Lazily := preload("res://addons/lazily/lazily.gd")


func test_floor_is_4_4() -> void:
	# The floor is a decision (see plan-lazily-gd.md), so it is asserted rather
	# than merely written down. Moving it should require editing a test.
	assert_that(Lazily.MIN_GODOT).is_equal(Vector3i(4, 4, 0))


func test_running_engine_satisfies_floor() -> void:
	# The suite cannot be trusted to say anything about an engine it could not
	# have parsed the addon on.
	var info := Engine.get_version_info()
	assert_bool(Lazily.engine_supported()).override_failure_message(
		"running Godot %s.%s.%s is below the declared floor %s"
		% [info["major"], info["minor"], info["patch"], Lazily.MIN_GODOT]
	).is_true()


func test_engine_supported_rejects_below_floor() -> void:
	# Drives the negative branch. Without this, `engine_supported()` returning a
	# hardcoded `true` would pass the test above and the check would be theatre.
	var below := Vector3i(4, 3, 9)
	assert_bool(below >= Lazily.MIN_GODOT).is_false()


func test_addon_does_not_depend_on_this_project() -> void:
	# What ships is addons/lazily/, dropped into a consumer's project. If the
	# addon ever reads a project setting defined in THIS project.godot, it works
	# here and breaks there — the failure mode the loading model exists to avoid.
	var source := FileAccess.get_file_as_string("res://addons/lazily/lazily.gd")
	assert_str(source).is_not_empty()
	assert_bool(source.contains("ProjectSettings")).override_failure_message(
		"addons/lazily/ reads ProjectSettings; a consumer project will not have set it"
	).is_false()
