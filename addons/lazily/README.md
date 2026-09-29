# Lazily for Godot

Lazily is a pure-GDScript reactive kernel for Godot 4.4 and newer. It provides
sources, computed values, scoped effects, batching, and the transport-free
latest-durable projection API without native binaries or platform-specific
dependencies.

The addon is a runtime script library, not an editor plugin. After installing
this directory as `res://addons/lazily/`, use the globally named classes
directly; there is no plugin to enable in Project Settings.

```gdscript
var ctx := LazilyContext.new()
var count := ctx.source(0)
var doubled := ctx.computed(func(k: LazilyCompute) -> int:
	return int(k.read(count)) * 2)

var scope := ctx.scope()
scope.effect(func(k: LazilyCompute) -> void:
	print(k.read(doubled)))

count.set_value(21)
scope.dispose()
```

Version: 0.2.0. Full documentation, tests, and source history are available at
https://github.com/lazily-hub/lazily-gd.
