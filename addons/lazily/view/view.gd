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
var _chart_leaf: LazilySource
var _payload: Dictionary = {}
var _bad := false


static func install(doc: Dictionary) -> LazilyView:
	var view := LazilyView.new()
	view._populate(doc)
	return view


## True after the whole View document validated and installed.
func is_installed() -> bool:
	return _ctx != null


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
	if _chart_leaf == null:
		return null
	return [_chart_leaf.peek()]


func dispatch(node: String, event: String, value: Variant = null) -> Array:
	if not is_installed():
		return []
	_bad = false
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
	var trace: Array = []
	if not _bad:
		_exec(stored[event], trace)
	_payload = {}
	return trace


func _populate(doc: Dictionary) -> void:
	_allow(doc, ["id", "root", "signals", "nodes", "chart"], "view")
	if not _nonempty_string(doc.get("id")):
		_fail("view id must be a non-empty string")
		return
	if not _nonempty_string(doc.get("root")):
		_fail("view root must be a non-empty string")
		return
	_root = doc["root"]
	if not doc.get("signals") is Dictionary or not doc.get("nodes") is Dictionary:
		_fail("view signals and nodes must be objects")
		return
	var signals_doc: Dictionary = doc["signals"]
	var nodes_doc: Dictionary = doc["nodes"]
	if nodes_doc.is_empty():
		_fail("empty nodes")
		return
	_has_chart = doc.has("chart")
	if _has_chart:
		if not doc["chart"] is Dictionary:
			_fail("chart must be an object")
			return
		_validate_chart(doc["chart"])
	var initials := {}
	for sid: Variant in signals_doc:
		if not _nonempty_string(sid) or not signals_doc[sid] is Dictionary:
			_fail("signal id must be a non-empty string and its definition an object")
			return
		var sig: Dictionary = signals_doc[sid]
		_allow(sig, ["initial"], "signal")
		if not sig.has("initial"):
			_fail("signal %s initial is required" % sid)
			return
		initials[sid] = _literal(sig["initial"])
	var expr_docs: Array = []
	for nid: Variant in nodes_doc:
		if not _nonempty_string(nid) or not nodes_doc[nid] is Dictionary:
			_fail("node id must be a non-empty string and its definition an object")
			return
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
			var bind: Variant = node["bind"]
			if not _nonempty_string(bind) or not initials.has(bind):
				_fail("bad bind %s" % bind)
				return
		if node.has("text"):
			_standing("text", nid, node["text"], expr_docs, initials, true)
		if node.has("hidden"):
			_standing("hidden", nid, node["hidden"], expr_docs, initials, false)
		if node.has("disabled"):
			_standing("disabled", nid, node["disabled"], expr_docs, initials, false)
		if node.has("effects"):
			if not node["effects"] is Dictionary:
				_fail("node %s effects must be an object" % nid)
				return
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
	if _bad:
		_scope.dispose()
		_scope = null
		_ctx = null
		return
	for doc_expr: Dictionary in expr_docs:
		var expr: Dictionary = doc_expr["expr"]
		var key: String = doc_expr["key"]
		_exprs[key] = _ctx.computed(func(compute: LazilyCompute) -> Dictionary:
			return _eval(expr, compute, false)
		)
	if _has_chart:
		_chart = doc["chart"].duplicate(true)
		_chart_leaf = _ctx.source(_enter(_chart["initial"]))
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
			if value["k"] != "bool":
				_fail("not expects a boolean")
				return _box_null()
			return _box_bool(not value["v"])
		"add":
			var sum := 0
			for i in range(1, args.size()):
				var value := _arg(args[i], compute, in_effect)
				if value["k"] != "int":
					_fail("add expects integers")
					return _box_null()
				sum += int(value["v"])
			return _box_int(sum)
		"len":
			var value := _arg(args[1], compute, in_effect)
			if value["k"] != "str":
				_fail("len expects a string")
				return _box_null()
			return _box_int(value["v"].length())
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
		if _bad:
			return
		(_signals[sid] as LazilySource).set_value(value)
		trace.append({"op": "set", "signal": sid, "value": _unwrap(value)})
	elif op == "send":
		var record := {"op": "send", "event": str(args[0])}
		if args.size() == 2:
			record["payload"] = _unwrap(_arg(args[1], null, true))
		if _bad:
			return
		_send(str(args[0]))
		trace.append(record)
	elif op == "batch":
		for nested: Variant in args:
			_exec(nested, trace)
			if _bad:
				return


# Godot currently supplies the portable single-region chart subset. The
# state-chart spec permits bindings to reject additional chart capabilities.
func _validate_chart(chart: Dictionary) -> void:
	_allow(chart, ["initial", "context", "states"], "chart")
	var states: Variant = chart.get("states")
	if not states is Dictionary or not states.has(chart.get("initial")):
		_fail("chart initial must name a declared state")
		return
	if chart.has("context") and not chart["context"] is Dictionary:
		_fail("chart context must be an object")
		return
	var roots := 0
	var children := {}
	for id: Variant in states:
		if not _nonempty_string(id) or not states[id] is Dictionary:
			_fail("chart state id and definition are required")
			return
		var state: Dictionary = states[id]
		if state.has("parent"):
			var parent: Variant = state["parent"]
			if not _nonempty_string(parent) or not states.has(parent):
				_fail("chart parent must name a declared state")
				return
			children[parent] = true
		else:
			roots += 1
	if roots != 1:
		_fail("chart must have one root")
		return
	for id: String in states:
		var seen := {}
		var cursor := id
		while cursor != "":
			if seen.has(cursor):
				_fail("chart parent cycle at %s" % cursor)
				return
			seen[cursor] = true
			cursor = states[cursor].get("parent", "")
		_validate_chart_state(states, id, children.has(id))


func _validate_chart_state(states: Dictionary, id: String, compound: bool) -> void:
	var state: Dictionary = states[id]
	for feature: String in ["parallel", "history", "entry", "exit", "run", "default"]:
		if state.has(feature):
			_fail("Godot View does not support chart %s" % feature)
			return
	_allow(state, ["parent", "kind", "initial", "on"], "chart state")
	var kind: String = "compound" if compound else "atomic"
	if state.get("kind", kind) != kind:
		_fail("chart state %s must be %s in the Godot single-region subset" % [id, kind])
		return
	if compound:
		var initial: Variant = state.get("initial")
		if not _nonempty_string(initial) or not states.has(initial) or states[initial].get("parent") != id:
			_fail("compound chart state %s must name an initial child" % id)
			return
	elif state.has("initial"):
		_fail("atomic chart state %s cannot have an initial child" % id)
		return
	var transitions: Variant = state.get("on", {})
	if not transitions is Dictionary:
		_fail("chart transitions must be an object")
		return
	for event: Variant in transitions:
		var transition: Variant = transitions[event]
		var target: Variant = transition
		if transition is Dictionary:
			if transition.has("action"):
				_fail("Godot View does not support chart transition actions")
				return
			_allow(transition, ["target", "guard", "internal"], "chart transition")
			if transition.has("guard") and not _nonempty_string(transition["guard"]):
				_fail("Godot View supports named chart guards only")
				return
			if transition.has("internal") and not transition["internal"] is bool:
				_fail("chart transition internal must be a boolean")
				return
			target = transition.get("target")
		if not _nonempty_string(event) or not _nonempty_string(target) or not states.has(target):
			_fail("chart transition event and declared target are required")
			return


func _send(event: String) -> void:
	var id: String = _chart_leaf.peek()
	while id != "":
		var node: Dictionary = _chart["states"][id]
		var transition: Variant = node.get("on", {}).get(event)
		if transition is String:
			_chart_leaf.set_value(_enter(transition))
			return
		# View dispatch supplies an empty named-guard map.
		if transition is Dictionary and not transition.has("guard"):
			_chart_leaf.set_value(_enter(transition["target"]))
			return
		id = node.get("parent", "")


func _enter(id: String) -> String:
	var node: Dictionary = _chart["states"][id]
	while node.has("initial"):
		id = node["initial"]
		node = _chart["states"][id]
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
	if not raw is Array:
		_fail("children of %s must be an array" % nid)
		return out
	for child: Variant in raw:
		if not _nonempty_string(child) or child in out:
			_fail("bad child of %s" % nid)
			return []
		out.append(child)
	return out


func _layout(nid: String, raw: Variant):
	if not raw is Dictionary:
		_fail("layout of %s must be an object" % nid)
		return null
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


func _validate_effect(effect: Variant, signals: Dictionary, has_chart: bool) -> void:
	if not effect is Dictionary or not effect.get("args") is Array:
		_fail("effect requires an object with an argument array")
		return
	_allow(effect, ["op", "args"], "effect")
	var op: Variant = effect.get("op")
	var args: Array = effect["args"]
	match op:
		"set":
			if args.size() != 2 or not _nonempty_string(args[0]) or not signals.has(args[0]):
				_fail("set requires a declared signal and a value")
				return
			_validate_arg(args[1], signals, true)
		"send":
			if not has_chart:
				_fail("send without chart")
				return
			if args.size() < 1 or args.size() > 2 or not _nonempty_string(args[0]):
				_fail("send requires an event name and an optional payload")
				return
			if args.size() == 2:
				_validate_arg(args[1], signals, true)
		"batch":
			if args.is_empty():
				_fail("batch requires at least one effect")
				return
			for nested: Variant in args:
				_validate_effect(nested, signals, has_chart)
		_:
			_fail("unknown effect %s" % op)


func _validate_expr(expr: Dictionary, signals: Dictionary, in_effect: bool) -> void:
	_allow(expr, ["op", "args"], "expression")
	var op: Variant = expr.get("op")
	if not _expr_ops.has(op) or not expr.get("args") is Array:
		_fail("expression requires a known op and an argument array")
		return
	var args: Array = expr["args"]
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
		if not _nonempty_string(args[0]) or not signals.has(args[0]):
			_fail("unknown signal")
		return
	if op == "call":
		if args.is_empty() or not _calls.has(args[0]):
			_fail("unknown call")
			return
		var name: String = args[0]
		var arity: int = _calls[name]
		if (name == "add" and args.size() < arity) or (name != "add" and args.size() != arity):
			_fail("%s arity" % name)
			return
		if name == "event" and not in_effect:
			_fail("event outside effect")
			return
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
			if is_finite(value) and value == floor(value) and value >= -9223372036854775808.0 and value < 9223372036854775808.0:
				return _box_int(int(value))
		TYPE_STRING:
			return _box_str(value)
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


func _nonempty_string(value: Variant) -> bool:
	return value is String and not value.is_empty()


func _allow(obj: Dictionary, keys: Array, what: String) -> void:
	for key: Variant in obj:
		if str(key) not in keys:
			_fail("%s unknown field %s" % [what, str(key)])


const _roles := {"text": true, "button": true, "field": true, "list": true, "region": true}
const _flows := {"row": true, "column": true, "stack": true}
const _aligns := {"start": true, "center": true, "end": true, "stretch": true}
const _events := {"activate": true, "change": true, "submit": true}
const _expr_ops := {"lit": true, "ref": true, "call": true, "if": true, "eq": true, "concat": true, "trim": true}
# Argument count includes the call name. For add this is the minimum.
const _calls := {"event": 1, "not": 2, "add": 3, "len": 2}
