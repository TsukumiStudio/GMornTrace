extends RefCounted
## Synthetic consumer. No OS input, game assets, audio or identifiers.

static func run(trace_script: Script) -> Dictionary:
	var trace: RefCounted = trace_script.new()
	var fields: Array[String] = ["action", "result", "offset_usec"]
	trace.begin("input_demo", 8, fields)
	var input: Dictionary = trace.record("input.press", 12, {"action": "confirm"}, 200000)
	trace.record("action.performed", 12, {"action": "confirm"}, 200100)
	trace.complete(input, 13, {"result": "accepted", "offset_usec": 100})
	return trace.snapshot()
