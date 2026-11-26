extends GdUnitTestSuite

const COUNTER := "{\"kind\":\"graph\",\"ir\":\"1\",\"id\":\"counter\",\"nodes\":[{\"id\":\"count\",\"kind\":\"source\",\"init\":1},{\"id\":\"doubled\",\"kind\":\"computed\",\"eager\":true,\"expr\":{\"op\":\"mul\",\"args\":[{\"ref\":\"count\"},{\"lit\":2}]}},{\"id\":\"log\",\"kind\":\"effect\",\"body\":{\"do\":\"eval\",\"expr\":{\"ref\":\"doubled\"}}}]}"
const COUNTER_EDIT := "{\"kind\":\"edit\",\"ir\":\"1\",\"ops\":[{\"op\":\"replace\",\"node\":{\"id\":\"doubled\",\"kind\":\"computed\",\"expr\":{\"op\":\"add\",\"args\":[{\"ref\":\"count\"},{\"lit\":10}]}}},{\"op\":\"add\",\"node\":{\"id\":\"label\",\"kind\":\"source\",\"init\":\"n\"}},{\"op\":\"add\",\"node\":{\"id\":\"shown\",\"kind\":\"computed\",\"expr\":{\"op\":\"concat\",\"args\":[{\"ref\":\"label\"},{\"lit\":\":\"}]}}},{\"op\":\"remove\",\"id\":\"log\"}]}"
const COUNTER_SOURCE := "graph counter ir 1\nsource count = 1\ncomputed doubled eager = mul(ref(count), lit(2))\neffect log = eval(ref(doubled))\n"
const COUNTER_EDITED := "graph counter ir 1\nsource count = 1\ncomputed doubled = add(ref(count), lit(10))\nsource label = \"n\"\ncomputed shown = concat(ref(label), lit(\":\"))\n"


func test_counter_lowers_then_an_edit_replaces_the_graph() -> void:
	var doc := LazilyGraphIr.from_json_str(COUNTER)
	assert_str(doc.fault).is_empty()
	assert_str(doc.id).is_equal("counter")
	assert_bool(doc.node_eager("doubled")).is_true()
	assert_str(doc.node_expr_op("doubled")).is_equal("mul")
	var edges := doc.static_edges()
	assert_int(edges.size()).is_equal(2)
	assert_str(edges[0]["from"]).is_equal("doubled")
	assert_str(edges[0]["to"]).is_equal("count")
	assert_str(edges[1]["from"]).is_equal("log")
	assert_str(doc.emit_source()).is_equal(COUNTER_SOURCE)
	var again := LazilyGraphIr.from_json_str(doc.to_json_text())
	assert_str(again.emit_source()).is_equal(COUNTER_SOURCE)

	var rt := LazilyGraphIr.Runtime.lower(doc)
	assert_int(rt.get_value("doubled")).is_equal(2)
	var trace := rt.effect_trace()
	assert_int(trace.size()).is_equal(1)
	assert_str(trace[0]["id"]).is_equal("log")
	assert_int(trace[0]["result"]).is_equal(2)
	assert_array(rt.observed_reads("doubled")).is_equal(["count"])
	assert_bool(rt.is_eager("doubled")).is_true()
	assert_str(rt.source_policy("count")).is_equal("keep-latest")
	var before := rt.emit_source()
	rt.write_source("count", 4)
	assert_int(rt.get_value("doubled")).is_equal(8)
	trace = rt.effect_trace()
	assert_int(trace.size()).is_equal(2)
	assert_int(trace[1]["result"]).is_equal(8)
	assert_str(rt.emit_source()).is_equal(before)

	rt.apply(LazilyGraphIr.Edit.from_json_str(COUNTER_EDIT))
	assert_str(rt.fault).is_empty()
	assert_int(rt.get_value("doubled")).is_equal(14)
	assert_str(rt.get_value("shown")).is_equal("n:")
	assert_bool(rt.has_node("log")).is_false()
	assert_bool(rt.is_eager("doubled")).is_false()
	var trace_len := rt.effect_trace().size()
	rt.write_source("count", 5)
	assert_int(rt.get_value("doubled")).is_equal(15)
	assert_int(rt.effect_trace().size()).is_equal(trace_len)
	assert_str(rt.emit_source()).is_equal(COUNTER_EDITED)


func test_dynamic_if_observes_only_the_taken_branch() -> void:
	var rt := LazilyGraphIr.Runtime.load_json("{\"kind\":\"graph\",\"ir\":\"1\",\"nodes\":[{\"id\":\"flag\",\"kind\":\"source\",\"init\":false},{\"id\":\"left\",\"kind\":\"source\",\"init\":\"L\"},{\"id\":\"right\",\"kind\":\"source\",\"init\":\"R\"},{\"id\":\"picked\",\"kind\":\"computed\",\"expr\":{\"op\":\"if\",\"args\":[{\"ref\":\"flag\"},{\"ref\":\"left\"},{\"ref\":\"right\"}]}}]}")
	assert_int(rt.static_edges().size()).is_equal(3)
	assert_str(rt.get_value("picked")).is_equal("R")
	assert_array(rt.observed_reads("picked")).is_equal(["flag", "right"])
	rt.write_source("flag", true)
	assert_str(rt.get_value("picked")).is_equal("L")
	assert_array(rt.observed_reads("picked")).is_equal(["flag", "left"])


func test_sum_policy_folds_and_skips_an_equal_write() -> void:
	var rt := LazilyGraphIr.Runtime.load_json("{\"kind\":\"graph\",\"ir\":\"1\",\"nodes\":[{\"id\":\"tick\",\"kind\":\"source\",\"init\":0},{\"id\":\"total\",\"kind\":\"source\",\"init\":0,\"policy\":\"sum\"},{\"id\":\"bump\",\"kind\":\"effect\",\"body\":{\"do\":\"seq\",\"steps\":[{\"do\":\"eval\",\"expr\":{\"ref\":\"tick\"}},{\"do\":\"merge\",\"target\":\"total\",\"expr\":{\"lit\":1}}]}}]}")
	var source := rt.emit_source()
	assert_str(source).contains("policy sum")
	assert_str(source).contains("merge(total, lit(1))")
	assert_int(rt.get_value("total")).is_equal(1)
	var result: Array = rt.effect_trace()[0]["result"]
	assert_int(result[0]).is_equal(0)
	assert_int(result[1]).is_equal(1)
	rt.write_source("tick", 1)
	assert_int(rt.get_value("total")).is_equal(2)
	assert_int(rt.effect_trace().size()).is_equal(2)
	rt.write_source("tick", 1)
	assert_int(rt.effect_trace().size()).is_equal(2)


func test_structures() -> void:
	var rt := LazilyGraphIr.Runtime.load_json("{\"kind\":\"graph\",\"ir\":\"1\",\"nodes\":[{\"id\":\"row\",\"kind\":\"source\",\"init\":{\"name\":\"ada\",\"n\":2}},{\"id\":\"name\",\"kind\":\"computed\",\"expr\":{\"op\":\"get\",\"args\":[{\"ref\":\"row\"},{\"lit\":\"name\"}]}},{\"id\":\"n\",\"kind\":\"computed\",\"expr\":{\"op\":\"get\",\"args\":[{\"ref\":\"row\"},{\"lit\":\"n\"}]}},{\"id\":\"tag\",\"kind\":\"computed\",\"expr\":{\"op\":\"concat\",\"args\":[{\"ref\":\"name\"},{\"lit\":\"#\"}]}},{\"id\":\"width\",\"kind\":\"computed\",\"expr\":{\"op\":\"len\",\"args\":[{\"ref\":\"name\"}]}},{\"id\":\"pair\",\"kind\":\"computed\",\"expr\":{\"op\":\"array\",\"args\":[{\"ref\":\"name\"},{\"ref\":\"n\"}]}},{\"id\":\"wrapped\",\"kind\":\"computed\",\"expr\":{\"object\":[{\"key\":\"name\",\"value\":{\"ref\":\"name\"}}]}}]}")
	assert_str(rt.get_value("name")).is_equal("ada")
	assert_int(rt.get_value("n")).is_equal(2)
	assert_str(rt.get_value("tag")).is_equal("ada#")
	assert_int(rt.get_value("width")).is_equal(3)
	var pair: Array = rt.get_value("pair")
	assert_str(pair[0]).is_equal("ada")
	assert_int(pair[1]).is_equal(2)
	var wrapped: Dictionary = rt.get_value("wrapped")
	assert_int(wrapped.size()).is_equal(1)
	assert_str(wrapped["name"]).is_equal("ada")


func test_cycle_and_snapshot_are_rejected() -> void:
	var cycle := LazilyGraphIr.from_json_str("{\"kind\":\"graph\",\"ir\":\"1\",\"nodes\":[{\"id\":\"a\",\"kind\":\"computed\",\"expr\":{\"ref\":\"b\"}},{\"id\":\"b\",\"kind\":\"computed\",\"expr\":{\"ref\":\"a\"}}]}")
	assert_str(cycle.fault).contains("cycle in read edges")
	var snap := LazilyGraphIr.from_json_str("{\"Snapshot\":{\"epoch\":0,\"nodes\":[],\"edges\":[],\"roots\":[]}}")
	assert_str(snap.fault).contains("graph")


func test_policies_and_null_init() -> void:
	var rt := LazilyGraphIr.Runtime.load_json("{\"kind\":\"graph\",\"ir\":\"1\",\"nodes\":[{\"id\":\"empty\",\"kind\":\"source\",\"init\":null},{\"id\":\"hi\",\"kind\":\"source\",\"init\":3,\"policy\":\"max\"},{\"id\":\"lo\",\"kind\":\"source\",\"init\":3,\"policy\":\"min\"},{\"id\":\"both\",\"kind\":\"source\",\"init\":true,\"policy\":\"and\"},{\"id\":\"either\",\"kind\":\"source\",\"init\":false,\"policy\":\"or\"},{\"id\":\"fold\",\"kind\":\"effect\",\"body\":{\"do\":\"seq\",\"steps\":[{\"do\":\"merge\",\"target\":\"hi\",\"expr\":{\"lit\":1}},{\"do\":\"merge\",\"target\":\"hi\",\"expr\":{\"lit\":5}},{\"do\":\"merge\",\"target\":\"hi\",\"expr\":{\"lit\":5}},{\"do\":\"merge\",\"target\":\"lo\",\"expr\":{\"lit\":1}},{\"do\":\"merge\",\"target\":\"both\",\"expr\":{\"lit\":false}},{\"do\":\"merge\",\"target\":\"either\",\"expr\":{\"lit\":true}}]}}]}")
	assert_bool(rt.get_value("empty") == null).is_true()
	assert_int(rt.get_value("hi")).is_equal(5)
	assert_int(rt.get_value("lo")).is_equal(1)
	assert_bool(rt.get_value("both")).is_false()
	assert_bool(rt.get_value("either")).is_true()


func test_and_short_circuits_and_div_by_zero_faults() -> void:
	var rt := LazilyGraphIr.Runtime.load_json("{\"kind\":\"graph\",\"ir\":\"1\",\"nodes\":[{\"id\":\"flag\",\"kind\":\"source\",\"init\":false},{\"id\":\"n\",\"kind\":\"source\",\"init\":1},{\"id\":\"bad\",\"kind\":\"computed\",\"expr\":{\"op\":\"div\",\"args\":[{\"ref\":\"n\"},{\"lit\":0}]}},{\"id\":\"gate\",\"kind\":\"computed\",\"expr\":{\"op\":\"and\",\"args\":[{\"ref\":\"flag\"},{\"ref\":\"bad\"}]}}]}")
	assert_bool(rt.get_value("gate")).is_false()
	assert_array(rt.observed_reads("gate")).is_equal(["flag"])
	assert_bool(rt.get_value("bad") == null).is_true()
	assert_str(rt.fault).contains("division by zero")


func test_failed_edits_leave_the_previous_graph() -> void:
	var rt := LazilyGraphIr.Runtime.load_json("{\"kind\":\"graph\",\"ir\":\"1\",\"nodes\":[{\"id\":\"a\",\"kind\":\"source\",\"init\":1},{\"id\":\"b\",\"kind\":\"computed\",\"expr\":{\"ref\":\"a\"}}]}")
	rt.apply(LazilyGraphIr.Edit.from_json_str("{\"kind\":\"edit\",\"ir\":\"1\",\"ops\":[{\"op\":\"remove\",\"id\":\"a\"}]}"))
	assert_str(rt.fault).contains("edit op 0")
	assert_bool(rt.has_node("a")).is_true()
	assert_bool(rt.has_node("b")).is_true()
	assert_int(rt.get_value("b")).is_equal(1)
	var empty := LazilyGraphIr.Runtime.load_json("{\"kind\":\"graph\",\"ir\":\"1\",\"nodes\":[]}")
	empty.apply(LazilyGraphIr.Edit.from_json_str("{\"kind\":\"edit\",\"ir\":\"1\",\"ops\":[{\"op\":\"add\",\"node\":{\"id\":\"a\",\"kind\":\"computed\",\"expr\":{\"ref\":\"b\"}}},{\"op\":\"add\",\"node\":{\"id\":\"b\",\"kind\":\"source\",\"init\":1}}]}"))
	assert_bool(empty.has_node("a")).is_false()
	assert_bool(empty.has_node("b")).is_false()
	assert_str(empty.emit_source()).is_equal("graph ir 1\n")


func test_replace_source_resets_and_when_records_null() -> void:
	var rt := LazilyGraphIr.Runtime.load_json("{\"kind\":\"graph\",\"ir\":\"1\",\"id\":\"g\",\"nodes\":[{\"id\":\"count\",\"kind\":\"source\",\"init\":1}]}")
	rt.write_source("count", 9)
	assert_int(rt.get_value("count")).is_equal(9)
	assert_str(rt.emit_source()).is_equal("graph g ir 1\nsource count = 1\n")
	rt.apply(LazilyGraphIr.Edit.from_json_str("{\"kind\":\"edit\",\"ir\":\"1\",\"ops\":[{\"op\":\"replace\",\"node\":{\"id\":\"count\",\"kind\":\"source\",\"init\":0}}]}"))
	assert_int(rt.get_value("count")).is_equal(0)
	var on := LazilyGraphIr.Runtime.load_json("{\"kind\":\"graph\",\"ir\":\"1\",\"nodes\":[{\"id\":\"on\",\"kind\":\"source\",\"init\":true},{\"id\":\"value\",\"kind\":\"source\",\"init\":0},{\"id\":\"apply\",\"kind\":\"effect\",\"body\":{\"do\":\"when\",\"cond\":{\"ref\":\"on\"},\"then\":{\"do\":\"set\",\"target\":\"value\",\"expr\":{\"lit\":7}}}}]}")
	assert_int(on.get_value("value")).is_equal(7)
	var off := LazilyGraphIr.Runtime.load_json("{\"kind\":\"graph\",\"ir\":\"1\",\"nodes\":[{\"id\":\"on\",\"kind\":\"source\",\"init\":false},{\"id\":\"value\",\"kind\":\"source\",\"init\":0},{\"id\":\"apply\",\"kind\":\"effect\",\"body\":{\"do\":\"when\",\"cond\":{\"ref\":\"on\"},\"then\":{\"do\":\"set\",\"target\":\"value\",\"expr\":{\"lit\":7}}}}]}")
	assert_int(off.get_value("value")).is_equal(0)
	assert_bool(off.effect_trace()[0]["result"] == null).is_true()


func test_empty_graph_accepts_add_and_rejections_fail_closed() -> void:
	var rt := LazilyGraphIr.Runtime.load_json("{\"kind\":\"graph\",\"ir\":\"1\",\"nodes\":[]}")
	rt.apply(LazilyGraphIr.Edit.from_json_str("{\"kind\":\"edit\",\"ir\":\"1\",\"ops\":[{\"op\":\"add\",\"node\":{\"id\":\"x\",\"kind\":\"source\",\"init\":1}}]}"))
	assert_str(rt.fault).is_empty()
	assert_int(rt.get_value("x")).is_equal(1)
	var texts := [
		"{\"kind\":\"graph\",\"ir\":\"2\",\"nodes\":[]}",
		"{\"kind\":\"graph\",\"ir\":\"1\",\"nodes\":[{\"id\":\"1count\",\"kind\":\"source\",\"init\":0}]}",
		"{\"kind\":\"graph\",\"ir\":\"1\",\"nodes\":[{\"id\":\"c\",\"kind\":\"computed\",\"expr\":{\"op\":\"pow\",\"args\":[{\"lit\":2},{\"lit\":3}]}}]}",
		"{\"kind\":\"graph\",\"ir\":\"1\",\"nodes\":[{\"id\":\"e\",\"kind\":\"effect\",\"body\":\"log\"}]}",
	]
	for text in texts:
		var bad := LazilyGraphIr.from_json_str(text)
		assert_bool(bad.fault != "").is_true()
	var empty := LazilyGraphIr.Edit.from_json_str("{\"kind\":\"edit\",\"ir\":\"1\",\"ops\":[]}")
	assert_bool(empty.fault != "").is_true()


func test_feedback_stops_at_the_drain_budget() -> void:
	var doc := LazilyGraphIr.from_json_str("{\"kind\":\"graph\",\"ir\":\"1\",\"nodes\":[{\"id\":\"n\",\"kind\":\"source\",\"init\":0},{\"id\":\"loop\",\"kind\":\"effect\",\"body\":{\"do\":\"set\",\"target\":\"n\",\"expr\":{\"op\":\"add\",\"args\":[{\"ref\":\"n\"},{\"lit\":1}]}}}]}")
	var rt := LazilyGraphIr.Runtime.lower(doc, 4)
	assert_int(rt.last_drain_exhaustion).is_equal(4)
	assert_int(rt.get_value("n")).is_equal(4)
