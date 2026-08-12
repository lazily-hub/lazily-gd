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


## The edge index keys on `get_instance_id()` and justifies that with "an id is
## never reused". This measures the claim instead of believing it — and corrects
## the reason usually given for it.
##
## Over 200k allocations both halves come out:
##
##   - the SLOT is recycled aggressively (the low 32 bits repeat on almost every
##     allocation), so "Godot instance ids are monotonic" is FALSE as usually
##     stated — ObjectDB is a free list, not a counter;
##   - the composed id still never repeats, because the high bits carry a
##     validator that increments on each reuse of a slot.
##
## So the allocator is generational: a free list over slot indices with a
## generation tag, which is the id layer `recycled_id_inherits_nothing.json`
## presumes a binding has to build. It does not follow that keying on the slot
## alone would break this binding, and that was measured too rather than
## asserted: keying `_dependents` on `id & 0xFFFFFFFF` leaves the whole suite
## green, because the entries are `WeakRef`s and a slot is only handed out after
## its previous occupant is gone. Id uniqueness is a second guarantee here, not
## the only thing holding the index up.
func test_instance_ids_are_generational_not_monotonic() -> void:
	var seen := {}
	var slots := {}
	var slot_reuse := 0
	var count := 200000
	for i in count:
		var o := RefCounted.new()
		var id := o.get_instance_id()
		seen[id] = true
		# Godot composes an instance id from a slot index in the low bits and a
		# validator in the high bits.
		var slot := id & 0xFFFFFFFF
		if slots.has(slot):
			slot_reuse += 1
		slots[slot] = true
		# Dropping the last reference frees the slot for the next allocation.
		o = null

	assert_int(seen.size()).override_failure_message(
		"an instance id was reused across %d allocations — the edge index keys on "
		% count + "it, so a dead entry could be mistaken for a live successor"
	).is_equal(count)

	# The negative half. Without it this test passes on an engine that simply
	# never reuses a slot, and it would then prove nothing about the aliasing
	# hazard it exists to rule out.
	assert_int(slot_reuse).override_failure_message(
		"no id slot was recycled in %d allocations, so this run cannot say " % count
		+ "whether the validator is what prevents aliasing"
	).is_greater(count / 2)


func test_addon_does_not_depend_on_this_project() -> void:
	# What ships is addons/lazily/, dropped into a consumer's project. If the
	# addon ever reads a project setting defined in THIS project.godot, it works
	# here and breaks there — the failure mode the loading model exists to avoid.
	var source := FileAccess.get_file_as_string("res://addons/lazily/lazily.gd")
	assert_str(source).is_not_empty()
	assert_bool(source.contains("ProjectSettings")).override_failure_message(
		"addons/lazily/ reads ProjectSettings; a consumer project will not have set it"
	).is_false()
