class_name LazilyView
extends RefCounted

var _ctx: LazilyContext
var _scope: LazilyScope
var _root: String
var _nodes: Dictionary = {}
var _signals: Dictionary = {}
var _exprs: Dictionary = {}
var _effects: Dictionary = {}
var _chart: Dictionary = {}
var _has_chart := false
var _leaf := ""
var _payload: Dictionary = {}
var _in_effect := false
var _bad := false


static func install(doc: Dictionary) -> LazilyView:
	var view := LazilyView.new()
	view._populate(doc)
	return view


func signals_json() -> Dictionary:
	var out := {}
	for id: String in _signals:
		out[id] = _unwrap((_signals[id] as LazilySource).peek())
	return out


func expressions_json() -> Dictionary:
	var out := {}
	for id: String in _exprs:
		out[id] = _unwrap((_exprs[id] as LazilyComputed).peek())
	return out


func layout_json() -> Array:
	var out: Array = []
	_walk(out, _root)
	return out


func chart_json():
	if not _has_chart:
		return null
	return [_leaf]


func dispatch(node: String, event: String, value: Variant) -> Array:
	if not _events.has(event):
		_fail("unknown event %s" % event)
		return []
	if not _nodes.has(node):
		_fail("unknown node %s" % node)
		return []
	var stored: Dictionary = _effects.get(node, {})
	if not stored.has(event):
		return []
	_payload = _literal(value)
	_in_effect = true
	var trace: Array = []
	_exec(stored[event], trace)
	_in_effect = false
	return trace


func _populate(doc: Dictionary) -> void:
	_allow(doc, ["id", "root", "signals", "nodes", "chart"], "view")
	if str(doc.get("id", "")) == "":
		_fail("empty id")
		return
	_root = str(doc.get("root", ""))
	if _root == "":
		_fail("empty root")
		return
	var signals_doc: Dictionary = doc.get("signals", {})
	var nodes_doc: Dictionary = doc.get("nodes", {})
	if nodes_doc.is_empty():
		_fail("empty nodes")
		return
	_has_chart = doc.has("chart")
	if _has_chart and typeof(doc["chart"]) != TYPE_DICTIONARY:
		_fail("chart must be an object")
		return
	var initials := {}
	for sid: String in signals_doc:
		var sig: Dictionary = signals_doc[sid]
		_allow(sig, ["initial"], "signal")
		initials[sid] = _literal(sig["initial"])
	var expr_docs: Array = []
	for nid: String in nodes_doc:
		var node: Dictionary = nodes_doc[nid]
		_allow(node, ["role", "children", "layout", "text", "bind", "hidden", "disabled", "effects"], nid)
		var role := str(node.get("role", ""))
		if not _roles.has(role):
			_fail("unknown role %s" % role)
			return
		var children: Array = []
		if node.has("children"):
			children = _children(nid, node["children"])
		var flow = null
		if node.has("layout"):
			flow = _layout(nid, node["layout"])
		if node.has("bind"):
			var bind := str(node["bind"])
			if bind == "" or not initials.has(bind):
				_fail("bad bind %s" % bind)
				return
		if node.has("text"):
			_standing("text", nid, node["text"], expr_docs, initials, true)
		if node.has("hidden"):
			_standing("hidden", nid, node["hidden"], expr_docs, initials, false)
		if node.has("disabled"):
			_standing("disabled", nid, node["disabled"], expr_docs, initials, false)
		if node.has("effects"):
			var effects: Dictionary = node["effects"]
			_allow(effects, ["activate", "change", "submit"], "effects")
			for event: String in effects:
				_validate_effect(effects[event], initials, _has_chart)
			if not effects.is_empty():
				_effects[nid] = effects
		_nodes[nid] = {"role": role, "children": children, "flow": flow}
	if not _nodes.has(_root):
		_fail("missing root")
		return
	var reached := {}
	_check_tree(_root, {}, reached)
	if reached.size() != _nodes.size():
		_fail("orphan")
	if _bad:
		return
	_ctx = LazilyContext.new()
	_scope = _ctx.scope()
	for sid: String in initials:
		_signals[sid] = _ctx.source(initials[sid])
	for doc_expr: Dictionary in expr_docs:
		_eval(doc_expr["expr"], null, false)
	for doc_expr: Dictionary in expr_docs:
		var expr: Dictionary = doc_expr["expr"]
		var key: String = doc_expr["key"]
		_exprs[key] = _ctx.computed(func(compute: LazilyCompute) -> Dictionary:
			return _eval(expr, compute, false)
		)
	if _has_chart:
		_chart = doc["chart"]
		_leaf = _enter(str(_chart.get("initial", "")))
	_scope.effect(func(compute: LazilyCompute) -> void:
		if not _exprs.is_empty():
			for key: String in _exprs:
				compute.read(_exprs[key])
		else:
			for key: String in _signals:
				compute.read(_signals[key])
	)


func _standing(field: String, nid: String, raw: Variant, docs: Array, signals: Dictionary, text: bool) -> void:
	var expr: Dictionary = {}
	if text and typeof(raw) == TYPE_STRING:
		expr = {"op": "lit", "args": [raw]}
	elif not text and typeof(raw) == TYPE_BOOL:
		expr = {"op": "lit", "args": [raw]}
	elif typeof(raw) == TYPE_DICTIONARY:
		_validate_expr(raw, signals, false)
		expr = raw
	else:
		_fail("%s must be a literal or expression" % field)
		return
	docs.append({"key": "%s.%s" % [nid, field], "expr": expr})


func _eval(expr: Dictionary, compute: LazilyCompute, in_effect: bool) -> Dictionary:
	var op := str(expr.get("op", ""))
	var args: Array = expr.get("args", [])
	match op:
		"lit":
			return _literal(args[0])
		"ref":
			return _read(str(args[0]), compute)
		"call":
			return _call(args, compute, in_effect)
		"if":
			var cond := _arg(args[0], compute, in_effect)
			if cond["k"] != "bool":
				_fail("if cond")
				return _box_null()
			return _arg(args[1] if cond["v"] else args[2], compute, in_effect)
		"eq":
			var left := _arg(args[0], compute, in_effect)
			var right := _arg(args[1], compute, in_effect)
			return _box_bool(left["k"] == right["k"] and left.get("v", null) == right.get("v", null))
		"concat":
			var out := ""
			for arg: Variant in args:
				out += _stringify(_arg(arg, compute, in_effect))
			return _box_str(out)
		"trim":
			return _box_str(_stringify(_arg(args[0], compute, in_effect)).strip_edges())
		_:
			_fail("unknown expr %s" % op)
			return _box_null()


func _call(args: Array, compute: LazilyCompute, in_effect: bool) -> Dictionary:
	var name := str(args[0])
	match name:
		"event":
			if not in_effect:
				_fail("event outside effect")
				return _box_null()
			return _payload
		"not":
			var value := _arg(args[1], compute, in_effect)
			return _box_bool(not bool(value["v"]))
		"add":
			var sum := 0
			for i in range(1, args.size()):
				sum += int(_arg(args[i], compute, in_effect)["v"])
			return _box_int(sum)
		"len":
			return _box_int(str(_arg(args[1], compute, in_effect)["v"]).length())
		_:
			_fail("unknown call %s" % name)
			return _box_null()


func _arg(value: Variant, compute: LazilyCompute, in_effect: bool) -> Dictionary:
	if typeof(value) == TYPE_DICTIONARY:
		return _eval(value, compute, in_effect)
	return _literal(value)


func _read(sid: String, compute: LazilyCompute) -> Dictionary:
	var src: LazilySource = _signals[sid]
	if compute == null:
		return src.peek()
	return compute.read(src)


func _exec(effect: Dictionary, trace: Array) -> void:
	var op := str(effect.get("op", ""))
	var args: Array = effect.get("args", [])
	if op == "set":
		var sid := str(args[0])
		var value := _arg(args[1], null, true)
		(_signals[sid] as LazilySource).set_value(value)
		trace.append({"op": "set", "signal": sid, "value": _unwrap(value)})
	elif op == "send":
		var record := {"op": "send", "event": str(args[0])}
		if args.size() == 2:
			record["payload"] = _unwrap(_arg(args[1], null, true))
		_send(str(args[0]))
		trace.append(record)
	elif op == "batch":
		for nested: Variant in args:
			_exec(nested, trace)


func _send(event: String) -> void:
	if not _has_chart:
		return
	var id := _leaf
	while id != "":
		var node: Dictionary = _chart["states"][id]
		var on: Dictionary = node.get("on", {})
		if on.has(event):
			var target: Variant = on[event]
			if typeof(target) == TYPE_DICTIONARY:
				target = target.get("target", "")
			_leaf = _enter(str(target))
			return
		id = str(node.get("parent", ""))


func _enter(id: String) -> String:
	var node: Dictionary = _chart["states"].get(id, {})
	if node.has("initial"):
		return _enter(str(node["initial"]))
	return id


func _walk(out: Array, id: String) -> void:
	var node: Dictionary = _nodes[id]
	var children: Array = node["children"]
	out.append({
		"id": id,
		"role": node["role"],
		"children": children,
		"flow": node["flow"],
	})
	for child: Variant in children:
		_walk(out, str(child))


func _children(nid: String, raw: Variant) -> Array:
	var out: Array = []
	for child: Variant in raw:
		var text := str(child)
		if text == "" or text in out:
			_fail("bad child of %s" % nid)
		out.append(text)
	return out


func _layout(nid: String, raw: Dictionary):
	_allow(raw, ["flow", "align", "grow"], nid)
	var flow = null
	if raw.has("flow"):
		flow = str(raw["flow"])
		if not _flows.has(flow):
			_fail("unknown flow")
	if raw.has("align") and not _aligns.has(str(raw["align"])):
		_fail("unknown align")
	if raw.has("grow"):
		var grow := _literal(raw["grow"])
		if grow["k"] != "int" or int(grow["v"]) < 0:
			_fail("bad grow %s" % nid)
	return flow


func _check_tree(id: String, stack: Dictionary, done: Dictionary) -> void:
	if stack.has(id) or done.has(id):
		_fail("bad tree %s" % id)
		return
	stack[id] = true
	for child: Variant in _nodes[id]["children"]:
		if not _nodes.has(str(child)):
			_fail("dangling %s" % str(child))
			return
		_check_tree(str(child), stack, done)
	stack.erase(id)
	done[id] = true


func _validate_effect(effect: Dictionary, signals: Dictionary, has_chart: bool) -> void:
	var op := str(effect.get("op", ""))
	if not _effect_ops.has(op):
		_fail("unknown effect %s" % op)
		return
	var args: Array = effect.get("args", [])
	if op == "set":
		if not signals.has(str(args[0])):
			_fail("unknown signal")
		_validate_arg(args[1], signals, true)
	elif op == "send":
		if not has_chart:
			_fail("send without chart")
		if args.size() == 2:
			_validate_arg(args[1], signals, true)
	else:
		for nested: Variant in args:
			_validate_effect(nested, signals, has_chart)


func _validate_expr(expr: Dictionary, signals: Dictionary, in_effect: bool) -> void:
	var op := str(expr.get("op", ""))
	if not _expr_ops.has(op):
		_fail("unknown expr %s" % op)
		return
	var args: Array = expr.get("args", [])
	if op == "lit" or op == "ref" or op == "trim":
		if args.size() != 1:
			_fail("%s arity" % op)
			return
	elif op == "eq":
		if args.size() != 2:
			_fail("eq arity")
			return
	elif op == "if":
		if args.size() != 3:
			_fail("if arity")
			return
	if op == "ref":
		if not signals.has(str(args[0])):
			_fail("unknown signal")
		return
	if op == "call":
		var name := str(args[0])
		if not _calls.has(name):
			_fail("unknown call %s" % name)
		if name == "event" and not in_effect:
			_fail("event outside effect")
		for i in range(1, args.size()):
			_validate_arg(args[i], signals, in_effect)
		return
	if op == "lit":
		_literal(args[0])
		return
	for arg: Variant in args:
		_validate_arg(arg, signals, in_effect)


func _validate_arg(value: Variant, signals: Dictionary, in_effect: bool) -> void:
	if typeof(value) == TYPE_DICTIONARY:
		_validate_expr(value, signals, in_effect)
	else:
		_literal(value)


func _literal(value: Variant) -> Dictionary:
	if value == null:
		return _box_null()
	match typeof(value):
		TYPE_BOOL:
			return _box_bool(value)
		TYPE_INT:
			return _box_int(value)
		TYPE_FLOAT:
			return _box_int(int(value))
		TYPE_STRING:
			return _box_str(value)
		_:
			_fail("bad literal")
			return _box_null()


func _unwrap(value: Dictionary) -> Variant:
	if value["k"] == "null":
		return null
	return value["v"]


func _stringify(value: Dictionary) -> String:
	match value["k"]:
		"bool":
			return "true" if value["v"] else "false"
		"int":
			return str(value["v"])
		"str":
			return str(value["v"])
		_:
			return ""


func _fail(message: String) -> void:
	_bad = true
	push_error(message)


func _box_null() -> Dictionary:
	return {"k": "null"}


func _box_bool(value: bool) -> Dictionary:
	return {"k": "bool", "v": value}


func _box_int(value: int) -> Dictionary:
	return {"k": "int", "v": value}


func _box_str(value: String) -> Dictionary:
	return {"k": "str", "v": value}


func _allow(obj: Dictionary, keys: Array, what: String) -> void:
	for key: Variant in obj:
		if str(key) not in keys:
			_fail("%s unknown field %s" % [what, str(key)])


const _roles := {"text": true, "button": true, "field": true, "list": true, "region": true}
const _flows := {"row": true, "column": true, "stack": true}
const _aligns := {"start": true, "center": true, "end": true, "stretch": true}
const _events := {"activate": true, "change": true, "submit": true}
const _expr_ops := {"lit": true, "ref": true, "call": true, "if": true, "eq": true, "concat": true, "trim": true}
const _effect_ops := {"set": true, "batch": true, "send": true}
const _calls := {"event": true, "not": true, "add": true, "len": true}
