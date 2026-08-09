## Load-graph invariant: loading the cell kernel must load NO other family.
##
## Runs as its own headless Godot invocation, not as a gdUnit4 test, and the
## isolation is the point. Inside the suite process the kernel and everything
## else is already resident — `has_cached` would answer about the harness rather
## than about the kernel, and the check would pass no matter what the kernel
## pulled in.
##
## It measures rather than reads. `ResourceLoader.get_dependencies()` returns []
## for GDScript (it models .import-style resource deps, not `class_name` /
## `extends` / `preload` edges), and scanning source text for `preload(` proves
## only what is written, not what loads. This observes what the engine actually
## resolved, which is the same standard the conformance guards hold: presence in
## a grep is not proof, observing the load is.
##
## This exists in Phase 1 on purpose. `preload()` is eager and transitive, so
## retrofitting layering after six families exist is the expensive order.
extends SceneTree

const KERNEL_ENTRY := "res://addons/lazily/cell/context.gd"

## Everything the kernel is ALLOWED to pull in — the cell family and nothing else.
const KERNEL_CLOSURE: Array[String] = [
	"res://addons/lazily/cell/context.gd",
	"res://addons/lazily/cell/cell.gd",
	"res://addons/lazily/cell/compute.gd",
	"res://addons/lazily/cell/source.gd",
	# The merge algebra is part of the CELL kernel, not a family above it: a
	# source cell folds under a policy, and KeepLatest is the default rather than
	# an opt-in, so every Source drags this in by construction.
	"res://addons/lazily/cell/merge_policy.gd",
	"res://addons/lazily/cell/computed.gd",
	"res://addons/lazily/cell/effect.gd",
	"res://addons/lazily/cell/scope.gd",
]


func _init() -> void:
	var failures: Array[String] = []

	# Everything shipped, minus the kernel closure, is what must stay unloaded.
	# Derived from the tree rather than listed, so a new family is covered the
	# day it lands instead of the day someone remembers to add it here.
	var shipped := _all_addon_scripts("res://addons/lazily")
	var forbidden: Array[String] = []
	for path: String in shipped:
		if not KERNEL_CLOSURE.has(path):
			forbidden.append(path)

	if forbidden.is_empty():
		# A check with nothing to catch is not a passing check.
		print("FAIL: nothing outside the kernel closure exists to assert against;")
		print("      this check would pass vacuously. Add the file back or update")
		print("      KERNEL_CLOSURE deliberately.")
		quit(1)
		return

	for path: String in forbidden:
		if ResourceLoader.has_cached(path):
			failures.append("%s was already resident before the kernel loaded" % path)

	var loaded := load(KERNEL_ENTRY)
	if loaded == null:
		print("FAIL: could not load the kernel entry %s" % KERNEL_ENTRY)
		quit(1)
		return

	for path: String in forbidden:
		if ResourceLoader.has_cached(path):
			failures.append(
				"loading the cell kernel also loaded %s — that is a cross-family load edge" % path
			)

	if failures.is_empty():
		print("load-graph OK: kernel closure is %d file(s); %d non-kernel file(s) stayed unloaded"
			% [KERNEL_CLOSURE.size(), forbidden.size()])
		quit(0)
		return

	for f: String in failures:
		print("FAIL: %s" % f)
	print("The kernel must not preload, extend, or statically type against another family.")
	quit(1)


func _all_addon_scripts(root: String) -> Array[String]:
	var out: Array[String] = []
	var dirs: Array[String] = [root]
	while not dirs.is_empty():
		var dir_path: String = dirs.pop_back()
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		dir.list_dir_begin()
		var name := dir.get_next()
		while name != "":
			var full := dir_path.path_join(name)
			if dir.current_is_dir():
				dirs.append(full)
			elif name.ends_with(".gd"):
				out.append(full)
			name = dir.get_next()
		dir.list_dir_end()
	return out
