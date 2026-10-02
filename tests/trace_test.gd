extends SceneTree

const Trace = preload("res://gmorn_trace.gd")
const InputExample = preload("res://examples/input_to_judgement.gd")
const FrameExample = preload("res://examples/delayed_frame.gd")
var checks: int = 0

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		push_error("GMornTrace check failed: " + label)
		quit(1)
		assert(condition, label)

func _run() -> void:
	_test_configuration()
	_test_capacity_order()
	_test_clear_reset()
	_test_frames()
	_test_snapshots()
	_test_payload_limits()
	_test_export_redaction()
	_test_examples()
	_test_file_export()
	var summary: FileAccess = FileAccess.open("res://test-summary.json", FileAccess.WRITE)
	summary.store_string(JSON.stringify({"checks": checks, "status": "passed", "audio_driver": "Dummy", "headless": true, "engine": Engine.get_version_info().string}))
	summary.close()
	print("GMornTrace checks=", checks)
	print("TEST: PASS")
	quit(0)

func _test_configuration() -> void:
	var t: RefCounted = Trace.new()
	check(t.record("x", 0).is_empty(), "not started")
	check(not t.begin("demo", 0), "zero capacity")
	check(not t.begin("demo", Trace.MAX_CAPACITY + 1), "large capacity")
	check(not t.begin("bad label", 4), "unsafe session")
	check(t.begin("demo", 4), "begin")
	check(t.snapshot().valid, "fresh valid")
	check(t.record("bad kind", 0).is_empty(), "unsafe kind")
	check(not t.snapshot().valid, "rejection invalidates result")

func _test_capacity_order() -> void:
	var t: RefCounted = Trace.new()
	t.begin("capacity", 2)
	var first: Dictionary = t.record("first", 4)
	var second: Dictionary = t.record("second", 4)
	check(first.id == 1 and second.id == 2, "same-frame order")
	check(t.record("third", 5).is_empty(), "full rejected")
	check(t.complete(first, 5).is_empty(), "completion also consumes capacity")
	var s: Dictionary = t.snapshot()
	check(s.count == 2 and s.overflow == 2 and not s.valid, "finite no overwrite")
	check(s.events[0].kind == "first" and s.events[1].kind == "second", "history preserved")

func _test_clear_reset() -> void:
	var t: RefCounted = Trace.new()
	t.begin("reset", 8)
	var old: Dictionary = t.record("old", 10)
	t.clear()
	var after_clear: Dictionary = t.record("new", 0)
	check(after_clear.id == 2 and after_clear.generation != old.generation, "clear identity")
	check(t.complete(old, 1).is_empty(), "clear stale handle")
	t.reset()
	var after_reset: Dictionary = t.record("new", 0)
	check(after_reset.id == 1 and after_reset.generation != after_clear.generation, "reset epoch")
	check(t.complete(after_clear, 1).is_empty(), "reset stale handle")
	check(t.snapshot().events.size() == 1, "old data removed")

func _test_frames() -> void:
	var t: RefCounted = Trace.new()
	t.begin("frames", 12)
	var a: Dictionary = t.record("submit", 100, {}, 1234)
	t.record("submit", 101)
	var completion: Dictionary = t.complete(a, 104, {"ready": true})
	var s: Dictionary = t.snapshot()
	check(completion.id == 3, "async ordered event")
	check(s.events[2].parent_id == a.id, "async parent")
	check(s.events[2].producer_frame == 100 and s.events[2].observed_frame == 104, "source/completion split")
	check(s.events[2].producer_time_usec == 1234, "producer clock retained")
	check(s.events[2].receipt_end_usec >= s.events[2].receipt_start_usec, "receipt bracket")
	check(t.record("past", 102).is_empty(), "observed frame regression")
	check(t.record("impossible", 106, {}, -1, 105).is_empty(), "source later than receipt")
	check(t.record("negative", -1).is_empty(), "negative source frame")
	check(not t.complete(a, 104).is_empty(), "same-frame boundary allowed")
	check(t.complete(completion, 105).is_empty(), "completion cannot parent completion")
	check(t.complete({"id": "1", "generation": 1}, 106).is_empty(), "forged type rejected")

func _test_snapshots() -> void:
	var t: RefCounted = Trace.new()
	t.begin("copies", 4)
	var payload: Dictionary = {"nested": {"values": [1, 2]}}
	t.record("event", 0, payload)
	payload.nested.values[0] = 99
	var first: Dictionary = t.snapshot()
	check(first.events[0].fields.nested.values[0] == 1, "producer mutation isolated")
	first.events[0].fields.nested.values[1] = 98
	check(t.snapshot().events[0].fields.nested.values[1] == 2, "consumer mutation isolated")

func _test_payload_limits() -> void:
	var t: RefCounted = Trace.new()
	t.begin("payload", 12)
	var object: RefCounted = RefCounted.new()
	check(t.record("object", 0, {"value": object}).is_empty(), "object rejected")
	check(t.record("nonfinite", 0, {"value": NAN}).is_empty(), "NaN rejected")
	check(t.record("nonfinite", 0, {"value": INF}).is_empty(), "infinity rejected")
	check(t.record("key", 0, {1: "value"}).is_empty(), "non-string key rejected")
	var many: Array = []
	many.resize(Trace.MAX_PAYLOAD_NODES + 1)
	many.fill(1)
	check(t.record("large", 0, {"value": many}).is_empty(), "node limit")
	var nested: Array = []
	var cursor: Array = nested
	for index: int in range(Trace.MAX_PAYLOAD_DEPTH + 2):
		var child: Array = []
		cursor.append(child)
		cursor = child
	check(t.record("deep", 0, {"value": nested}).is_empty(), "depth limit")
	var cycle: Array = []
	cycle.append(cycle)
	check(t.record("cycle", 0, {"value": cycle}).is_empty(), "cycle bounded")
	cycle.clear()
	check(t.snapshot().count == 0, "rejected payloads not appended")

func _test_export_redaction() -> void:
	var t: RefCounted = Trace.new()
	var allow: Array[String] = ["score", "nested", "label", "number", "float_value", "nullable"]
	t.begin("export", 8, allow)
	t.record("event", 9007199254740993, {
		"score": 42, "token": "DUMMY_SECRET", "unlisted": "DUMMY_TEXT",
		"nested": {"password": "DUMMY_SECRET", "path": "/" + "demo" + "/file"},
		"label": "reader@example.invalid", "number": 9223372036854775807,
		"float_value": -0.0, "nullable": null,
	})
	var text: String = t.export_json()
	check(not text.contains("DUMMY_SECRET") and not text.contains("DUMMY_TEXT"), "secret/allowlist redaction")
	check(not text.contains("example.invalid") and not text.contains("/demo/file"), "path/email redaction")
	var decoded: Dictionary = JSON.parse_string(text)
	check(decoded.events[0].producer_frame.decimal == "9007199254740993", "large frame precision")
	check(decoded.events[0].fields.number.decimal == "9223372036854775807", "int64 precision")
	check(decoded.events[0].fields.float_value.bits_be == "8000000000000000", "negative-zero bits")
	check(decoded.events[0].fields.nullable == null, "unavailable retained")
	check(t.snapshot().redactions == 5, "redactions counted")
	check(t.snapshot().valid, "redaction is declared, not rejected")

func _test_examples() -> void:
	var input: Dictionary = InputExample.run(Trace)
	check(input.valid and input.count == 3, "input consumer example")
	check(input.events[2].fields.result == "accepted", "input result")
	var frame: Dictionary = FrameExample.run(Trace)
	check(frame.valid and frame.events[2].producer_frame == 40, "delayed consumer example")
	check(frame.events[2].observed_frame == 43, "delayed receipt")

func _test_file_export() -> void:
	var t: RefCounted = Trace.new()
	t.begin("file_demo", 4)
	t.record("event", 0, {"value": 1})
	var path: String = "user://trace_test.json"
	check(t.write_json(path) == OK, "explicit artifact write")
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	check(file != null, "artifact readable")
	var decoded: Dictionary = JSON.parse_string(file.get_as_text())
	file.close()
	check(decoded.count.decimal == "1", "artifact roundtrip")
	check(DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK, "artifact cleanup")
