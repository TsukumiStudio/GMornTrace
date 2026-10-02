extends RefCounted
## Synthetic async completion. Data belongs to frame40 even after frame41 exists.

static func run(trace_script: Script) -> Dictionary:
	var trace: RefCounted = trace_script.new()
	trace.begin("frame_demo", 8)
	var source: Dictionary = trace.record("render.submitted", 40, {"resource": "texture_a"}, 400000)
	trace.record("render.submitted", 41, {"resource": "texture_b"}, 410000)
	trace.complete(source, 43, {"checksum": "dummy_digest"})
	return trace.snapshot()
