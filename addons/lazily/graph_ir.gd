## Graph IR interpreter. A document parses into sources, computeds, and effects.
## Canonical source is emitted from the document, not from live values.
class_name LazilyGraphIr
extends RefCounted

const VERSION := "1"
const DRAIN_BUDGET := 100000

var id := ""
var has_id := false
var nodes: Array = []
var index := {}
var fault := ""


static func from_json_str(text: String) -> LazilyGraphIr:
	var doc := LazilyGraphIr.new()
	doc._ingest(_parse_json(doc, text, "graph document"))
	return doc


func node(node_id: String):
	if not index.has(node_id):
		return null
	return nodes[index[node_id]]


func node_eager(node_id: String) -> bool:
	var found = node(node_id)
	if found == null or str(found.get("kind", "")) != "computed":
		return false
	return bool(found.get("eager", false))


func node_expr_op(node_id: String) -> String:
	var found = node(node_id)
	if found == null or not found.has("expr"):
		return ""
	return str(found["expr"].get("op", ""))


func static_edges() -> Array:
	var edges: Array = []
	for item in nodes:
		var sets := _edge_sets(item)
		for to in sets[0]:
			edges.append({"from": str(item["id"]), "kind": "read", "to": to})
		for to in sets[1]:
			edges.append({"from": str(item["id"]), "kind": "write", "to": to})
	edges.sort_custom(func(a, b):
		if a["from"] != b["from"]:
			return a["from"] < b["from"]
		if a["kind"] != b["kind"]:
			return a["kind"] < b["kind"]
		return a["to"] < b["to"]
	)
	return edges


func emit_source() -> String:
	var out := "graph %s ir 1\n" % id if has_id else "graph ir 1\n"
	for item in nodes:
		out += _emit_node(item) + "\n"
	return out


func to_json_text() -> String:
	var obj := {"kind": "graph", "ir": VERSION, "nodes": _copy(nodes)}
	if has_id:
		obj["id"] = id
	return _canon(obj)


func clone() -> LazilyGraphIr:
	var copy := LazilyGraphIr.new()
	copy.id = id
	copy.has_id = has_id
	copy.nodes = _copy(nodes)
	copy._reindex()
	return copy


func _ingest(value) -> void:
	if fault != "":
		return
	if not _object(value, "graph document"):
		return
	if not _allow(value, "graph document", ["kind", "ir", "id", "nodes"]):
		return
	var kind := _string(_require(value, "kind", "graph document"), "graph document `kind`")
	if fault != "":
		return
	if kind != "graph":
		_fail("graph document kind must be \"graph\", got `%s`" % kind)
		return
	var version := _string(_require(value, "ir", "graph document"), "graph document `ir`")
	if fault != "":
		return
	if version != "1":
		_fail("unsupported graph IR version `%s`" % version)
		return
	if value.has("id"):
		id = _parse_id(_string(value["id"], "graph id"), "graph id")
		has_id = fault == ""
	var list = _require(value, "nodes", "graph document")
	if fault != "":
		return
	if typeof(list) != TYPE_ARRAY:
		_fail("graph nodes must be an array")
		return
	var seen := {}
	for item in list:
		_parse_node(item)
		if fault != "":
			return
		var node_id := str(item["id"])
		if seen.has(node_id):
			_fail("duplicate node id `%s`" % node_id)
			return
		seen[node_id] = true
		nodes.append(item)
	_reindex()
	_check()


func _reindex() -> void:
	index = {}
	for slot in range(nodes.size()):
		var node_id := str(nodes[slot]["id"])
		if index.has(node_id):
			_fail("duplicate node id `%s`" % node_id)
			return
		index[node_id] = slot


func _check() -> void:
	if fault != "":
		return
	for item in nodes:
		var sets := _edge_sets(item)
		var node_id := str(item["id"])
		for to in sets[0]:
			var target = node(to)
			if target == null:
				_fail("node `%s` reads unknown node `%s`" % [node_id, to])
				return
			if str(target["kind"]) == "effect":
				_fail("node `%s` reads effect `%s`, which has no value" % [node_id, to])
				return
		for to in sets[1]:
			var target = node(to)
			if target == null:
				_fail("node `%s` writes unknown node `%s`" % [node_id, to])
				return
			if str(target["kind"]) != "source":
				_fail("node `%s` writes non-source `%s`" % [node_id, to])
				return
	var color := {}
	var stack: Array = []
	for item in nodes:
		if not _visit(str(item["id"]), color, stack):
			return


func _visit(node_id: String, color: Dictionary, stack: Array) -> bool:
	var state = int(color.get(node_id, 0))
	if state == 1:
		var path := ""
		var started := false
		for item in stack:
			if not started and item != node_id:
				continue
			started = true
			path += "" if path == "" else " -> "
			path += item
		path += "" if path == "" else " -> "
		path += node_id
		_fail("cycle in read edges: " + path)
		return false
	if state == 2:
		return true
	color[node_id] = 1
	stack.append(node_id)
	var target = node(node_id)
	if target != null:
		for dep in _edge_sets(target)[0]:
			if node(dep) != null and not _visit(dep, color, stack):
				return false
	stack.pop_back()
	color[node_id] = 2
	return true


func apply_op(op: Dictionary) -> void:
	var name := str(op["op"])
	if name == "add" or name == "replace":
		var item = op["node"]
		var node_id := str(item["id"])
		if name == "add":
			if index.has(node_id):
				_fail("add requires a new id, `%s` already exists" % node_id)
				return
			nodes.append(item)
		else:
			if not index.has(node_id):
				_fail("replace requires an existing node `%s`" % node_id)
				return
			nodes[index[node_id]] = item
	else:
		var node_id := str(op["id"])
		if not index.has(node_id):
			_fail("remove requires an existing node `%s`" % node_id)
			return
		nodes.remove_at(int(index[node_id]))
	_reindex()
	_check()


func _parse_node(value) -> void:
	if not _object(value, "node"):
		return
	var kind := _string(_require(value, "kind", "node"), "node `kind`")
	if fault != "":
		return
	var node_id := _parse_id(_string(_require(value, "id", "node"), "node `id`"), "node id")
	if fault != "":
		return
	if kind == "source":
		if not _allow(value, "source", ["id", "kind", "init", "policy"]):
			return
		var init = _require(value, "init", "source `%s`" % node_id)
		if fault != "":
			return
		_check_policy(_policy_name(value, node_id), init)
	elif kind == "computed":
		if not _allow(value, "computed", ["id", "kind", "expr", "eager"]):
			return
		if value.has("eager") and typeof(value["eager"]) != TYPE_BOOL:
			_fail("computed `%s` eager must be a boolean" % node_id)
			return
		_parse_expr(_require(value, "expr", "computed"))
	elif kind == "effect":
		if not _allow(value, "effect", ["id", "kind", "body"]):
			return
		_parse_stmt(_require(value, "body", "effect"))
	else:
		_fail("unknown node kind `%s`" % kind)


func _parse_expr(value) -> void:
	if fault != "":
		return
	if not _object(value, "expression"):
		return
	if not _allow(value, "expression", ["lit", "ref", "op", "args", "object"]):
		return
	var forms := 0
	for key in ["lit", "ref", "op", "object"]:
		if value.has(key):
			forms += 1
	if forms != 1:
		_fail("expression must be exactly one of lit, ref, op, or object")
		return
	if value.has("args") and not value.has("op"):
		_fail("args is only valid on an op expression")
		return
	if value.has("lit"):
		return
	if value.has("ref"):
		_parse_id(_string(value["ref"], "expression `ref`"), "ref")
		return
	if value.has("object"):
		if typeof(value["object"]) != TYPE_ARRAY:
			_fail("object expression must be an array")
			return
		var seen := {}
		for item in value["object"]:
			if not _object(item, "object field"):
				return
			if not _allow(item, "object field", ["key", "value"]):
				return
			var key := _string(_require(item, "key", "object field"), "object field `key`")
			if fault != "":
				return
			if seen.has(key):
				_fail("duplicate object key `%s`" % key)
				return
			seen[key] = true
			_parse_expr(_require(item, "value", "object field"))
			if fault != "":
				return
		return
	var op := _string(_require(value, "op", "expression"), "expression `op`")
	if fault != "":
		return
	if not _is_unary(op) and not _is_binary(op) and op != "if" and op != "array":
		_fail("unknown op `%s`" % op)
		return
	var args = _require(value, "args", "op expression")
	if fault != "":
		return
	if typeof(args) != TYPE_ARRAY:
		_fail("op args must be an array")
		return
	var ok: bool = args.size() == 1 if _is_unary(op) else args.size() == 3 if op == "if" else true if op == "array" else args.size() == 2
	if not ok:
		_fail("op `%s` has the wrong number of arguments" % op)
		return
	for arg in args:
		_parse_expr(arg)
		if fault != "":
			return


func _parse_stmt(value) -> void:
	if fault != "":
		return
	if not _object(value, "statement"):
		return
	var verb := _string(_require(value, "do", "statement"), "statement `do`")
	if fault != "":
		return
	if verb == "eval":
		if _allow(value, "eval", ["do", "expr"]):
			_parse_expr(_require(value, "expr", "eval"))
	elif verb == "set" or verb == "merge":
		if not _allow(value, verb, ["do", "target", "expr"]):
			return
		_parse_id(_string(_require(value, "target", verb), verb + " `target`"), "write target")
		if fault == "":
			_parse_expr(_require(value, "expr", verb))
	elif verb == "seq":
		if not _allow(value, "seq", ["do", "steps"]):
			return
		var steps = _require(value, "steps", "seq")
		if fault != "":
			return
		if typeof(steps) != TYPE_ARRAY:
			_fail("seq steps must be an array")
			return
		if steps.is_empty():
			_fail("seq steps must not be empty")
			return
		for step in steps:
			_parse_stmt(step)
	elif verb == "when":
		if not _allow(value, "when", ["do", "cond", "then", "else"]):
			return
		_parse_expr(_require(value, "cond", "when"))
		if fault == "":
			_parse_stmt(_require(value, "then", "when"))
		if fault == "" and value.has("else"):
			_parse_stmt(value["else"])
	else:
		_fail("unknown statement `%s`" % verb)


func _fail(message: String) -> void:
	if fault == "":
		fault = message


func _object(value, what: String) -> bool:
	if typeof(value) != TYPE_DICTIONARY:
		_fail("%s must be an object" % what)
		return false
	return true


func _allow(obj: Dictionary, what: String, keys: Array) -> bool:
	for key in obj.keys():
		if not keys.has(str(key)):
			_fail("%s: unknown field `%s`" % [what, str(key)])
			return false
	return true


func _require(obj: Dictionary, field: String, what: String):
	if fault != "":
		return null
	if not obj.has(field):
		_fail("%s requires `%s`" % [what, field])
		return null
	return obj[field]


func _string(value, what: String) -> String:
	if fault != "":
		return ""
	if typeof(value) != TYPE_STRING:
		_fail("%s must be a string, got %s" % [what, _canon(value)])
		return ""
	return value


func _parse_id(text: String, what: String) -> String:
	if fault != "":
		return ""
	if not _valid_id(text):
		_fail("%s `%s` is not a graph IR id" % [what, text])
		return ""
	return text


static func _parse_json(owner, text: String, what: String):
	var parser := JSON.new()
	if parser.parse(text) != OK:
		owner._fail("%s is not JSON: %s" % [what, parser.get_error_message()])
		return null
	return _normalize(parser.data)


static func _normalize(value):
	match typeof(value):
		TYPE_FLOAT:
			if is_finite(value) and value == floor(value) and value >= -9223372036854775808.0 and value < 9223372036854775808.0:
				return int(value)
			return value
		TYPE_ARRAY:
			var out: Array = []
			for item in value:
				out.append(_normalize(item))
			return out
		TYPE_DICTIONARY:
			var out := {}
			for key in value.keys():
				out[str(key)] = _normalize(value[key])
			return out
		_:
			return value


static func _copy(value):
	match typeof(value):
		TYPE_ARRAY:
			var out: Array = []
			for item in value:
				out.append(_copy(item))
			return out
		TYPE_DICTIONARY:
			var out := {}
			for key in value.keys():
				out[key] = _copy(value[key])
			return out
		_:
			return value


static func _valid_id(text: String) -> bool:
	if text.is_empty() or text.length() > 128:
		return false
	if not _id_char(text[0], true):
		return false
	for ch in text:
		if not _id_char(ch, false):
			return false
	return true


static func _id_char(ch: String, head: bool) -> bool:
	var code := ch.unicode_at(0)
	if code == 95:
		return true
	if code >= 65 and code <= 90:
		return true
	if code >= 97 and code <= 122:
		return true
	return (not head) and code >= 48 and code <= 57


static func _is_unary(op: String) -> bool:
	return op == "neg" or op == "not" or op == "len"


static func _is_binary(op: String) -> bool:
	return ["add", "sub", "mul", "div", "mod", "min", "max", "eq", "ne", "lt", "le", "gt", "ge", "concat", "get", "and", "or"].has(op)


static func _policy_name(obj: Dictionary, node_id: String) -> String:
	if not obj.has("policy"):
		return "keep-latest"
	return str(obj["policy"])


static func _edge_sets(node: Dictionary) -> Array:
	var reads := {}
	var writes := {}
	var kind := str(node.get("kind", ""))
	if kind == "computed":
		_collect_expr(node["expr"], reads)
	elif kind == "effect":
		_collect_stmt(node["body"], reads, writes)
	return [_sorted_keys(reads), _sorted_keys(writes)]


static func _collect_expr(expr: Dictionary, reads: Dictionary) -> void:
	if expr.has("ref"):
		reads[str(expr["ref"])] = true
	if expr.has("args"):
		for arg in expr["args"]:
			_collect_expr(arg, reads)
	if expr.has("object"):
		for item in expr["object"]:
			_collect_expr(item["value"], reads)


static func _collect_stmt(stmt: Dictionary, reads: Dictionary, writes: Dictionary) -> void:
	var verb := str(stmt["do"])
	if verb == "eval":
		_collect_expr(stmt["expr"], reads)
	elif verb == "set" or verb == "merge":
		writes[str(stmt["target"])] = true
		_collect_expr(stmt["expr"], reads)
	elif verb == "seq":
		for step in stmt["steps"]:
			_collect_stmt(step, reads, writes)
	elif verb == "when":
		_collect_expr(stmt["cond"], reads)
		_collect_stmt(stmt["then"], reads, writes)
		if stmt.has("else"):
			_collect_stmt(stmt["else"], reads, writes)


static func _sorted_keys(map: Dictionary) -> Array:
	var keys: Array = map.keys()
	keys.sort()
	return keys


static func _canon(value) -> String:
	match typeof(value):
		TYPE_NIL:
			return "null"
		TYPE_BOOL:
			return "true" if value else "false"
		TYPE_INT:
			return str(value)
		TYPE_FLOAT:
			return str(value)
		TYPE_STRING:
			return _quote(value)
		TYPE_ARRAY:
			var parts: PackedStringArray = []
			for item in value:
				parts.append(_canon(item))
			return "[" + ",".join(parts) + "]"
		TYPE_DICTIONARY:
			var keys: Array = value.keys()
			keys.sort()
			var parts: PackedStringArray = []
			for key in keys:
				parts.append(_quote(str(key)) + ":" + _canon(value[key]))
			return "{" + ",".join(parts) + "}"
		_:
			return "null"


static func _quote(text: String) -> String:
	var out := "\""
	for ch in text:
		match ch:
			"\"":
				out += "\\\""
			"\\":
				out += "\\\\"
			"\n":
				out += "\\n"
			"\r":
				out += "\\r"
			"\t":
				out += "\\t"
			_:
				out += ch
	return out + "\""


static func _emit_node(node: Dictionary) -> String:
	var kind := str(node["kind"])
	var node_id := str(node["id"])
	if kind == "source":
		var out := "source %s = %s" % [node_id, _canon(node["init"])]
		if node.has("policy") and str(node["policy"]) != "keep-latest":
			out += " policy " + str(node["policy"])
		return out
	if kind == "computed":
		var out := "computed " + node_id
		if bool(node.get("eager", false)):
			out += " eager"
		return out + " = " + _emit_expr(node["expr"])
	return "effect %s = %s" % [node_id, _emit_stmt(node["body"])]


static func _emit_expr(expr: Dictionary) -> String:
	if expr.has("lit"):
		return "lit(%s)" % _canon(expr["lit"])
	if expr.has("ref"):
		return "ref(%s)" % str(expr["ref"])
	if expr.has("object"):
		var parts: PackedStringArray = []
		for item in expr["object"]:
			parts.append("%s: %s" % [_canon(item["key"]), _emit_expr(item["value"])])
		return "object(" + ", ".join(parts) + ")"
	var parts: PackedStringArray = []
	for arg in expr["args"]:
		parts.append(_emit_expr(arg))
	return "%s(%s)" % [str(expr["op"]), ", ".join(parts)]


static func _emit_stmt(stmt: Dictionary) -> String:
	var verb := str(stmt["do"])
	if verb == "eval":
		return "eval(%s)" % _emit_expr(stmt["expr"])
	if verb == "set" or verb == "merge":
		return "%s(%s, %s)" % [verb, str(stmt["target"]), _emit_expr(stmt["expr"])]
	if verb == "seq":
		var parts: PackedStringArray = []
		for step in stmt["steps"]:
			parts.append(_emit_stmt(step))
		return "seq(%s)" % ", ".join(parts)
	var out := "when(%s, %s" % [_emit_expr(stmt["cond"]), _emit_stmt(stmt["then"])]
	if stmt.has("else"):
		out += ", " + _emit_stmt(stmt["else"])
	return out + ")"


static func _eq(left, right) -> bool:
	if typeof(left) != typeof(right):
		return false
	match typeof(left):
		TYPE_NIL:
			return true
		TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return left == right
		TYPE_ARRAY:
			if left.size() != right.size():
				return false
			for i in range(left.size()):
				if not _eq(left[i], right[i]):
					return false
			return true
		TYPE_DICTIONARY:
			if left.size() != right.size():
				return false
			for key in left.keys():
				if not right.has(key) or not _eq(left[key], right[key]):
					return false
			return true
		_:
			return false


static func _as_num(value) -> Dictionary:
	if typeof(value) == TYPE_INT:
		return {"integer": true, "int": value, "real": 0.0}
	if typeof(value) == TYPE_FLOAT and is_finite(value):
		return {"integer": false, "int": 0, "real": value}
	return {}


static func _expect_bool(value) -> Variant:
	if typeof(value) == TYPE_BOOL:
		return value
	return null


class Edit extends RefCounted:
	var ops: Array = []
	var fault := ""

	static func from_json_str(text: String) -> Edit:
		var edit := Edit.new()
		var root = LazilyGraphIr._parse_json(edit, text, "graph edit")
		if edit.fault != "":
			return edit
		if typeof(root) != TYPE_DICTIONARY:
			edit.fault = "graph edit must be an object"
			return edit
		edit._load(root)
		return edit

	func _fail(message: String) -> void:
		if fault == "":
			fault = message

	func _load(root: Dictionary) -> void:
		for key in root.keys():
			if not ["kind", "ir", "ops"].has(str(key)):
				_fail("graph edit: unknown field `%s`" % str(key))
				return
		if not root.has("kind") or typeof(root["kind"]) != TYPE_STRING:
			_fail("graph edit requires `kind`")
			return
		if str(root["kind"]) != "edit":
			_fail("graph edit kind must be \"edit\", got `%s`" % str(root["kind"]))
			return
		if not root.has("ir") or str(root["ir"]) != "1":
			_fail("unsupported graph IR version `%s`" % str(root.get("ir", "")))
			return
		if typeof(root.get("ops")) != TYPE_ARRAY:
			_fail("graph edit ops must be an array")
			return
		if root["ops"].is_empty():
			_fail("graph edit ops must not be empty")
			return
		var probe := LazilyGraphIr.new()
		for item in root["ops"]:
			if typeof(item) != TYPE_DICTIONARY or typeof(item.get("op")) != TYPE_STRING:
				_fail("unknown edit op")
				return
			var name := str(item["op"])
			probe.fault = ""
			if name == "add" or name == "replace":
				probe._parse_node(item.get("node"))
			elif name == "remove":
				probe._parse_id(probe._string(item.get("id"), "remove `id`"), "remove id")
			else:
				_fail("unknown edit op `%s`" % name)
				return
			if probe.fault != "":
				_fail(probe.fault)
				return
			ops.append(item)


class Runtime extends RefCounted:
	var doc: LazilyGraphIr
	var drain_budget := DRAIN_BUDGET
	var last_drain_exhaustion = null
	var sources := {}
	var computeds := {}
	var effects := {}
	var deps := {}
	var subs := {}
	var observed := {}
	var trace: Array = []
	var frames: Array = []
	var stack: Array = []
	var computing := {}
	var scheduled: Array = []
	var scheduled_set := {}
	var current := ""
	var draining := false
	var fault := ""

	static func load_json(text: String, budget := 0) -> Runtime:
		return lower(LazilyGraphIr.from_json_str(text), budget)

	static func lower(source: LazilyGraphIr, budget := 0) -> Runtime:
		var rt := Runtime.new()
		rt.doc = source.clone()
		rt.drain_budget = budget if budget > 0 else DRAIN_BUDGET
		if source.fault != "":
			rt.fault = source.fault
			return rt
		rt._install_document()
		return rt

	func has_node(node_id: String) -> bool:
		return doc.node(node_id) != null

	func is_eager(node_id: String) -> bool:
		var found = doc.node(node_id)
		if found == null:
			_fail("unknown node `%s`" % node_id)
			return false
		if str(found["kind"]) != "computed":
			_fail("`%s` is not a computed" % node_id)
			return false
		return bool(found.get("eager", false))

	func source_policy(node_id: String) -> String:
		var found = doc.node(node_id)
		if found == null:
			_fail("unknown node `%s`" % node_id)
			return ""
		if str(found["kind"]) != "source":
			_fail("`%s` is not a source" % node_id)
			return ""
		return str(found.get("policy", "keep-latest"))

	func static_edges() -> Array:
		return doc.static_edges()

	func emit_source() -> String:
		return doc.emit_source()

	func observed_reads(node_id: String) -> Array:
		if not observed.has(node_id):
			return []
		return LazilyGraphIr._sorted_keys(observed[node_id])

	func effect_trace() -> Array:
		return trace.duplicate()

	func get_value(node_id: String):
		fault = ""
		if effects.has(node_id) and not sources.has(node_id) and not computeds.has(node_id):
			_fail("`%s` is an effect and has no value" % node_id)
			return null
		if sources.has(node_id):
			return LazilyGraphIr._copy(sources[node_id]["value"])
		if not computeds.has(node_id):
			_fail("unknown node `%s`" % node_id)
			return null
		var state: Dictionary = computeds[node_id]
		if state["dirty"] or not state["has_value"]:
			_recompute(node_id)
		if fault != "":
			return null
		return LazilyGraphIr._copy(computeds[node_id]["cache"])

	func write_source(node_id: String, value) -> void:
		fault = ""
		_set_source(node_id, LazilyGraphIr._normalize(value))
		_drain()

	func apply(edit: Edit) -> void:
		fault = ""
		if edit.fault != "":
			_fail(edit.fault)
			return
		for index in range(edit.ops.size()):
			var nxt := doc.clone()
			nxt.apply_op(edit.ops[index])
			if nxt.fault != "":
				_fail("edit op %d: %s" % [index, nxt.fault])
				return
			_install_op(edit.ops[index])
			if fault != "":
				_fail("edit op %d: %s" % [index, fault])
				return
			doc = nxt

	func _fail(message: String) -> void:
		if fault == "":
			fault = message

	func _install_document() -> void:
		for item in doc.nodes:
			if str(item["kind"]) == "source":
				_insert_source(item)
		for item in doc.nodes:
			if str(item["kind"]) == "computed":
				_insert_computed(item)
		for item in doc.nodes:
			if str(item["kind"]) == "computed" and bool(item.get("eager", false)):
				_recompute(str(item["id"]))
		for item in doc.nodes:
			if str(item["kind"]) == "effect":
				_insert_effect(item)

	func _install_op(op: Dictionary) -> void:
		var name := str(op["op"])
		if name == "add":
			_add_node(op["node"])
		elif name == "replace":
			_replace_node(op["node"])
		else:
			_remove_node(str(op["id"]))
		if fault == "":
			_drain()

	func _add_node(node: Dictionary) -> void:
		var kind := str(node["kind"])
		var node_id := str(node["id"])
		if kind == "source":
			_insert_source(node)
		elif kind == "computed":
			_insert_computed(node)
			if bool(node.get("eager", false)):
				_recompute(node_id)
				if fault != "":
					_drop(node_id)
		else:
			_insert_effect(node)

	func _replace_node(node: Dictionary) -> void:
		var node_id := str(node["id"])
		var snap = _snapshot(node_id)
		_drop(node_id)
		_add_node(node)
		if fault != "":
			_drop(node_id)
			_restore(node_id, snap)
			return
		_notify(node_id)
		if fault != "":
			_drop(node_id)
			_restore(node_id, snap)

	func _remove_node(node_id: String) -> void:
		if not sources.has(node_id) and not computeds.has(node_id) and not effects.has(node_id):
			_fail("unknown node `%s`" % node_id)
			return
		_drop(node_id)
		subs.erase(node_id)

	func _insert_source(node: Dictionary) -> void:
		var node_id := str(node["id"])
		var policy := str(node.get("policy", "keep-latest"))
		sources[node_id] = {"value": LazilyGraphIr._copy(node["init"]), "policy": policy}

	func _insert_computed(node: Dictionary) -> void:
		computeds[str(node["id"])] = {
			"expr": node["expr"],
			"eager": bool(node.get("eager", false)),
			"cache": null,
			"has_value": false,
			"dirty": true,
		}
		deps[str(node["id"])] = {}

	func _insert_effect(node: Dictionary) -> void:
		var node_id := str(node["id"])
		effects[node_id] = {"body": node["body"]}
		deps[node_id] = {}
		_run_effect(node_id)
		if fault != "":
			_drop(node_id)

	func _snapshot(node_id: String) -> Dictionary:
		if sources.has(node_id):
			return {"kind": "source", "source": LazilyGraphIr._copy(sources[node_id]), "present": true}
		if computeds.has(node_id):
			return {"kind": "computed", "computed": LazilyGraphIr._copy(computeds[node_id]), "deps": LazilyGraphIr._copy(deps.get(node_id, {})), "present": true}
		if effects.has(node_id):
			return {"kind": "effect", "effect": effects[node_id], "deps": LazilyGraphIr._copy(deps.get(node_id, {})), "present": true}
		return {"present": false}

	func _restore(node_id: String, snap: Dictionary) -> void:
		if not snap.get("present", false):
			return
		if snap["kind"] == "source":
			sources[node_id] = snap["source"]
		elif snap["kind"] == "computed":
			computeds[node_id] = snap["computed"]
			deps[node_id] = {}
			for dep in snap["deps"].keys():
				_sub_add(str(dep), node_id)
				deps[node_id][str(dep)] = true
		elif snap["kind"] == "effect":
			effects[node_id] = snap["effect"]
			deps[node_id] = {}
			for dep in snap["deps"].keys():
				_sub_add(str(dep), node_id)
				deps[node_id][str(dep)] = true

	func _drop(node_id: String) -> void:
		sources.erase(node_id)
		computeds.erase(node_id)
		effects.erase(node_id)
		if deps.has(node_id):
			for dep in deps[node_id].keys():
				if subs.has(dep):
					subs[dep].erase(node_id)
			deps.erase(node_id)
		observed.erase(node_id)
		scheduled_set.erase(node_id)

	func _set_source(node_id: String, value):
		if not sources.has(node_id):
			if computeds.has(node_id) or effects.has(node_id):
				_fail("`%s` is not a source" % node_id)
			else:
				_fail("unknown node `%s`" % node_id)
			return null
		var changed := not LazilyGraphIr._eq(sources[node_id]["value"], value)
		sources[node_id]["value"] = LazilyGraphIr._copy(value)
		if changed:
			_notify(node_id)
		return LazilyGraphIr._copy(sources[node_id]["value"])

	func _merge_source(node_id: String, value):
		if not sources.has(node_id):
			if computeds.has(node_id) or effects.has(node_id):
				_fail("`%s` is not a source" % node_id)
			else:
				_fail("unknown node `%s`" % node_id)
			return null
		return _set_source(node_id, _fold(sources[node_id]["policy"], sources[node_id]["value"], value))

	func _notify(node_id: String) -> void:
		if fault != "" or not subs.has(node_id):
			return
		var names := LazilyGraphIr._sorted_keys(subs[node_id])
		for dep in names:
			if computeds.has(dep):
				var down: bool = subs.has(dep) and not subs[dep].is_empty()
				if computeds[dep]["eager"] or down:
					if computing.has(dep):
						computeds[dep]["dirty"] = true
					else:
						_recompute(dep)
				else:
					computeds[dep]["dirty"] = true
			elif effects.has(dep):
				_schedule(dep)

	func _schedule(node_id: String) -> void:
		if effects.has(node_id) and not scheduled_set.has(node_id):
			scheduled_set[node_id] = true
			scheduled.append(node_id)

	func _drain() -> void:
		if draining:
			return
		draining = true
		var iterations := 0
		while not scheduled.is_empty():
			var node_id: String = scheduled.pop_front()
			scheduled_set.erase(node_id)
			iterations += 1
			if iterations >= drain_budget:
				last_drain_exhaustion = iterations
				draining = false
				return
			if effects.has(node_id):
				_run_effect(node_id)
				if fault != "":
					draining = false
					return
		draining = false

	func _run_effect(node_id: String) -> void:
		if fault != "":
			return
		_begin(node_id)
		var result = _eval_stmt(effects[node_id]["body"])
		_end(node_id)
		if fault != "":
			return
		trace.append({"id": node_id, "result": LazilyGraphIr._copy(result)})
		_drain()

	func _recompute(node_id: String) -> void:
		if fault != "":
			return
		if computing.has(node_id):
			_fail("cycle in read edges: %s" % node_id)
			return
		computing[node_id] = true
		var expr = computeds[node_id]["expr"]
		_begin(node_id)
		var value = _eval_expr(expr)
		_end(node_id)
		computing.erase(node_id)
		if fault != "":
			computeds[node_id]["dirty"] = true
			computeds[node_id]["has_value"] = false
			computeds[node_id]["cache"] = null
			return
		var changed: bool = not bool(computeds[node_id]["has_value"]) or not LazilyGraphIr._eq(computeds[node_id]["cache"], value)
		computeds[node_id]["cache"] = LazilyGraphIr._copy(value)
		computeds[node_id]["has_value"] = true
		computeds[node_id]["dirty"] = false
		if changed:
			_notify(node_id)

	func _begin(node_id: String) -> void:
		if deps.has(node_id):
			for dep in deps[node_id].keys():
				if subs.has(dep):
					subs[dep].erase(node_id)
			deps[node_id] = {}
		else:
			deps[node_id] = {}
		frames.append({})
		stack.append(current)
		current = node_id

	func _end(node_id: String) -> void:
		observed[node_id] = frames.pop_back()
		current = stack.pop_back()

	func _note(node_id: String) -> void:
		if frames.is_empty() or current == "":
			_fail("read outside a node evaluation")
			return
		frames[frames.size() - 1][node_id] = true
		_sub_add(node_id, current)
		deps[current][node_id] = true

	func _sub_add(src: String, reader: String) -> void:
		if not subs.has(src):
			subs[src] = {}
		subs[src][reader] = true

	func _read_ref(node_id: String):
		_note(node_id)
		if fault != "":
			return null
		if sources.has(node_id):
			return LazilyGraphIr._copy(sources[node_id]["value"])
		if computeds.has(node_id):
			if computeds[node_id]["dirty"] or not computeds[node_id]["has_value"]:
				_recompute(node_id)
				if fault != "":
					return null
			return LazilyGraphIr._copy(computeds[node_id]["cache"])
		if effects.has(node_id):
			_fail("`%s` is an effect and has no value" % node_id)
			return null
		_fail("unknown node `%s`" % node_id)
		return null

	func _eval_expr(expr):
		if fault != "":
			return null
		if expr.has("lit"):
			return LazilyGraphIr._copy(expr["lit"])
		if expr.has("ref"):
			return _read_ref(str(expr["ref"]))
		if expr.has("object"):
			var result := {}
			var seen := {}
			for item in expr["object"]:
				var key := str(item["key"])
				if seen.has(key):
					_fail("duplicate object key `%s`" % key)
					return null
				seen[key] = true
				result[key] = _eval_expr(item["value"])
				if fault != "":
					return null
			return result
		var op := str(expr["op"])
		var args: Array = expr["args"]
		if op == "and":
			var left = _expect_bool_value(_eval_expr(args[0]))
			if fault != "":
				return null
			if not left:
				return false
			return _expect_bool_value(_eval_expr(args[1]))
		if op == "or":
			var left = _expect_bool_value(_eval_expr(args[0]))
			if fault != "":
				return null
			if left:
				return true
			return _expect_bool_value(_eval_expr(args[1]))
		if op == "if":
			var cond = _expect_bool_value(_eval_expr(args[0]))
			if fault != "":
				return null
			return _eval_expr(args[1] if cond else args[2])
		if op == "array":
			var out: Array = []
			for arg in args:
				out.append(_eval_expr(arg))
				if fault != "":
					return null
			return out
		var values: Array = []
		for arg in args:
			values.append(_eval_expr(arg))
			if fault != "":
				return null
		return _eval_values(op, values)

	func _expect_bool_value(value):
		if fault != "":
			return null
		if typeof(value) != TYPE_BOOL:
			_fail("expected a boolean, got %s" % LazilyGraphIr._canon(value))
			return null
		return value

	func _eval_values(op: String, values: Array):
		if op == "neg":
			var num := _num(values[0])
			if num.is_empty():
				return null
			if num["integer"]:
				return -int(num["int"])
			return _canonical_f64(-float(num["real"]))
		if op == "not":
			var bit = _expect_bool_value(values[0])
			return null if fault != "" else not bit
		if op == "len":
			return _len_value(values[0])
		if op == "add" or op == "sub" or op == "mul" or op == "div":
			return _num_bin(op, values[0], values[1])
		if op == "mod":
			var a := _num(values[0])
			var b := _num(values[1])
			if a.is_empty() or b.is_empty():
				return null
			if not a["integer"] or not b["integer"]:
				_fail("mod requires integers")
				return null
			if int(b["int"]) == 0:
				_fail("division by zero")
				return null
			return int(a["int"]) % int(b["int"])
		if op == "min" or op == "max":
			var order := _ordering(values[0], values[1])
			if fault != "":
				return null
			if op == "max":
				return values[0] if order >= 0 else values[1]
			return values[0] if order <= 0 else values[1]
		if op == "eq" or op == "ne":
			var equal := LazilyGraphIr._eq(values[0], values[1])
			return not equal if op == "ne" else equal
		if op == "lt" or op == "le" or op == "gt" or op == "ge":
			var order := _ordering(values[0], values[1])
			if fault != "":
				return null
			if op == "lt":
				return order < 0
			if op == "le":
				return order <= 0
			if op == "gt":
				return order > 0
			return order >= 0
		if op == "concat":
			if typeof(values[0]) != TYPE_STRING or typeof(values[1]) != TYPE_STRING:
				_fail("concat requires strings, got %s and %s" % [LazilyGraphIr._canon(values[0]), LazilyGraphIr._canon(values[1])])
				return null
			return str(values[0]) + str(values[1])
		if op == "get":
			return _eval_get(values[0], values[1])
		_fail("op `%s` is not an eager operator" % op)
		return null

	func _num(value) -> Dictionary:
		if typeof(value) == TYPE_INT:
			return {"integer": true, "int": value, "real": 0.0}
		if typeof(value) == TYPE_FLOAT and is_finite(value):
			return {"integer": false, "int": 0, "real": value}
		_fail("expected a number, got %s" % LazilyGraphIr._canon(value))
		return {}

	func _canonical_f64(number: float):
		if not is_finite(number):
			_fail("non-finite number")
			return null
		if number == floor(number) and number >= -9223372036854775808.0 and number < 9223372036854775808.0:
			return int(number)
		return number

	func _ordering(left, right) -> int:
		var a := _num(left)
		var b := _num(right)
		if a.is_empty() or b.is_empty():
			return 0
		if a["integer"] and b["integer"]:
			return int(int(a["int"]) > int(b["int"])) - int(int(a["int"]) < int(b["int"]))
		var lf := float(a["int"]) if a["integer"] else float(a["real"])
		var rf := float(b["int"]) if b["integer"] else float(b["real"])
		return int(lf > rf) - int(lf < rf)

	func _num_bin(op: String, left, right):
		var a := _num(left)
		var b := _num(right)
		if a.is_empty() or b.is_empty():
			return null
		if op != "div" and a["integer"] and b["integer"]:
			if op == "add":
				return int(a["int"]) + int(b["int"])
			if op == "sub":
				return int(a["int"]) - int(b["int"])
			if op == "mul":
				return int(a["int"]) * int(b["int"])
		var lf := float(a["int"]) if a["integer"] else float(a["real"])
		var rf := float(b["int"]) if b["integer"] else float(b["real"])
		if op == "div" and rf == 0.0:
			_fail("division by zero")
			return null
		var value := 0.0
		if op == "add":
			value = lf + rf
		elif op == "sub":
			value = lf - rf
		elif op == "mul":
			value = lf * rf
		elif op == "div":
			value = lf / rf
		else:
			_fail("op `%s` is not a numeric operator" % op)
			return null
		return _canonical_f64(value)

	func _len_value(value):
		match typeof(value):
			TYPE_STRING:
				return value.length()
			TYPE_ARRAY, TYPE_DICTIONARY:
				return value.size()
			_:
				_fail("len requires a string, array, or object, got %s" % LazilyGraphIr._canon(value))
				return null

	func _eval_get(target, key):
		if typeof(target) == TYPE_ARRAY:
			var index := _num(key)
			if index.is_empty():
				return null
			if not index["integer"]:
				_fail("array index must be an integer")
				return null
			if int(index["int"]) < 0 or int(index["int"]) >= target.size():
				_fail("index %d out of range" % int(index["int"]))
				return null
			return LazilyGraphIr._copy(target[int(index["int"])])
		if typeof(target) == TYPE_DICTIONARY:
			if typeof(key) != TYPE_STRING:
				_fail("object key must be a string, got %s" % LazilyGraphIr._canon(key))
				return null
			if not target.has(key):
				_fail("missing key `%s`" % key)
				return null
			return LazilyGraphIr._copy(target[key])
		_fail("get requires an array or object, got %s" % LazilyGraphIr._canon(target))
		return null

	func _fold(policy: String, old, op):
		if policy == "keep-latest":
			return LazilyGraphIr._copy(op)
		if policy == "sum":
			return _num_bin("add", old, op)
		if policy == "max":
			var order := _ordering(old, op)
			return old if order >= 0 else op
		if policy == "min":
			var order := _ordering(old, op)
			return old if order <= 0 else op
		if policy == "and":
			return bool(old) and bool(op)
		if policy == "or":
			return bool(old) or bool(op)
		_fail("unknown source policy `%s`" % policy)
		return null

	func _eval_stmt(stmt: Dictionary):
		if fault != "":
			return null
		var verb := str(stmt["do"])
		if verb == "eval":
			return _eval_expr(stmt["expr"])
		if verb == "set":
			return _set_source(str(stmt["target"]), _eval_expr(stmt["expr"]))
		if verb == "merge":
			var value = _eval_expr(stmt["expr"])
			if fault != "":
				return null
			return _merge_source(str(stmt["target"]), value)
		if verb == "seq":
			var out: Array = []
			for step in stmt["steps"]:
				out.append(_eval_stmt(step))
				if fault != "":
					return null
			return out
		if verb == "when":
			var cond = _expect_bool_value(_eval_expr(stmt["cond"]))
			if fault != "":
				return null
			if not cond:
				if stmt.has("else"):
					return _eval_stmt(stmt["else"])
				return null
			return _eval_stmt(stmt["then"])
		_fail("unknown statement `%s`" % verb)
		return null


func _check_policy(policy: String, init) -> void:
	if policy == "sum" or policy == "max" or policy == "min":
		if typeof(init) != TYPE_INT and typeof(init) != TYPE_FLOAT:
			_fail("expected a number, got %s" % _canon(init))
	elif policy == "and" or policy == "or":
		if typeof(init) != TYPE_BOOL:
			_fail("expected a boolean, got %s" % _canon(init))
	elif policy != "keep-latest":
		_fail("unknown source policy `%s`" % policy)
