extends GdUnitTestSuite


func test_view_conformance() -> void:
	var dir := LazilyFixtureLoader.spec_dir().path_join("view")
	if not DirAccess.dir_exists_absolute(dir):
		return
	var found: Array[String] = []
	var listing := DirAccess.open(dir)
	assert_object(listing).is_not_null()
	listing.list_dir_begin()
	var name := listing.get_next()
	while name != "":
		if name.ends_with(".json"):
			found.append(name)
		name = listing.get_next()
	found.sort()
	var want: Array[String] = ["batch_send.json", "counter.json", "field_change.json", "malformed_rejected.json"]
	assert_array(found).is_equal(want)
	for fixture_name: String in ["counter.json", "field_change.json", "batch_send.json"]:
		var fixture := LazilyFixtureLoader.load_fixture("view/%s" % fixture_name)
		assert_str(fixture.get("kind", "")).is_equal("View")
		_replay(fixture_name, fixture)
	var malformed := LazilyFixtureLoader.load_fixture("view/malformed_rejected.json")
	var cases: Array = malformed.get("cases", [])
	assert_int(cases.size()).is_greater(0)
	for scenario: Dictionary in cases:
		var view := LazilyView.install(scenario["view"])
		assert_bool(view._ctx == null).override_failure_message(
			"%s must be rejected" % scenario.get("name", "")
		).is_true()


func _replay(fixture_name: String, fixture: Dictionary) -> void:
	var view := LazilyView.install(fixture["view"])
	assert_bool(view._ctx != null).override_failure_message("%s install" % fixture_name).is_true()
	_same("%s signals" % fixture_name, view.signals_json(), fixture["signals"])
	_same("%s expressions" % fixture_name, view.expressions_json(), fixture["expressions"])
	_same("%s layout" % fixture_name, view.layout_json(), fixture["layout"])
	_same("%s trace" % fixture_name, [], fixture["trace"])
	_same("%s chart" % fixture_name, view.chart_json(), fixture["chart"])
	var i := 0
	for step: Dictionary in fixture["steps"]:
		var trace := view.dispatch(str(step["node"]), str(step["event"]), step.get("value", null))
		var label := "%s step %d" % [fixture_name, i]
		_same(label, view.signals_json(), step["signals"])
		_same(label, view.expressions_json(), step["expressions"])
		_same(label, trace, step["trace"])
		_same(label, view.chart_json(), step["chart"])
		i += 1


func _same(label: String, got: Variant, want: Variant) -> void:
	var left := JSON.stringify(_norm(got))
	var right := JSON.stringify(_norm(want))
	assert_str(left).override_failure_message(label).is_equal(right)


func _norm(value: Variant) -> Variant:
	if value == null:
		return null
	match typeof(value):
		TYPE_FLOAT:
			if is_equal_approx(value, floor(value)):
				return int(value)
			return value
		TYPE_ARRAY:
			var out: Array = []
			for item: Variant in value:
				out.append(_norm(item))
			return out
		TYPE_DICTIONARY:
			var out := {}
			for key: Variant in value:
				out[key] = _norm(value[key])
			return out
		_:
			return value
