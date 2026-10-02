class_name GMornTrace
extends RefCounted
## Finite main-thread event journal. Frames describe provenance, not event order.
## Use handles for delayed completion; clear/reset invalidates every old handle.

const SCHEMA_VERSION: int = 1
const MAX_CAPACITY: int = 65536
const MAX_PAYLOAD_DEPTH: int = 8
const MAX_PAYLOAD_NODES: int = 512
const REDACTED: String = "<redacted>"
const SENSITIVE_WORDS: Array[String] = [
	"password", "secret", "token", "credential", "authorization",
	"email", "username", "user_id", "account", "private_path", "api_key",
]

var _events: Array[Dictionary] = []
var _capacity: int = 0
var _generation: int = 0
var _sequence: int = 0
var _session: String = ""
var _last_observed_frame: int = -1
var _overflow: int = 0
var _rejected: int = 0
var _redactions: int = 0
var _error: String = "not_started"
var _allow_fields: Array[String] = []
var _payload_nodes: int = 0
var _payload_error: bool = false
var _pending_redactions: int = 0


func begin(session: String, capacity: int = 1024, allowed_fields: Array[String] = []) -> bool:
	if not _safe_symbol(session) or _sensitive_value(session) or capacity < 1 or capacity > MAX_CAPACITY:
		_error = "invalid_configuration"
		return false
	for field: String in allowed_fields:
		if not _safe_symbol(field):
			_error = "invalid_configuration"
			return false
	_session = session
	_capacity = capacity
	_allow_fields = allowed_fields.duplicate()
	reset()
	return true


func clear() -> void:
	_events.clear()
	_generation += 1
	_last_observed_frame = -1
	_overflow = 0
	_rejected = 0
	_redactions = 0
	_error = "" if _capacity > 0 else "not_started"


func reset() -> void:
	clear()
	_sequence = 0


func record(kind: String, producer_frame: int, fields: Dictionary = {},
		producer_time_usec: int = -1, observed_frame: int = -1) -> Dictionary:
	var receipt_start: int = Time.get_ticks_usec()
	if observed_frame == -1:
		observed_frame = producer_frame
	if not _validate_frame(kind, producer_frame, observed_frame):
		return {}
	var safe_fields: Dictionary = _prepare_fields(fields)
	if _payload_error:
		return _reject("unsupported_payload")
	return _append(kind, producer_frame, observed_frame, producer_time_usec,
		0, safe_fields, receipt_start)


func complete(handle: Dictionary, completion_frame: int, fields: Dictionary = {}) -> Dictionary:
	var receipt_start: int = Time.get_ticks_usec()
	if typeof(handle.get("generation")) != TYPE_INT or typeof(handle.get("id")) != TYPE_INT:
		return _reject("invalid_handle")
	if int(handle.generation) != _generation:
		return _reject("stale_handle")
	var parent: Dictionary = {}
	for event: Dictionary in _events:
		if event.id == handle.id:
			parent = event
			break
	if parent.is_empty() or parent.parent_id != 0:
		return _reject("invalid_parent")
	if not _validate_frame("complete", parent.producer_frame, completion_frame):
		return {}
	var safe_fields: Dictionary = _prepare_fields(fields)
	if _payload_error:
		return _reject("unsupported_payload")
	return _append("complete", parent.producer_frame, completion_frame,
		parent.producer_time_usec, parent.id, safe_fields, receipt_start)


func snapshot() -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION, "session": _session,
		"generation": _generation, "capacity": _capacity,
		"count": _events.size(), "overflow": _overflow,
		"rejected": _rejected, "redactions": _redactions,
		"valid": _capacity > 0 and _overflow == 0 and _rejected == 0,
		"last_error": _error, "events": _events.duplicate(true),
	}


func export_json(indent: String = "") -> String:
	# Every integer is tagged decimal text, avoiding JSON's floating numeric conversion.
	# Finite floats carry canonical big-endian IEEE754 bits as well as their value.
	return JSON.stringify(_encode(snapshot()), indent, true, true)


func write_json(path: String, indent: String = "") -> Error:
	# Explicit artifact path only. No directory creation, save discovery or networking.
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(export_json(indent))
	var result: Error = file.get_error()
	file.close()
	return result


func _validate_frame(kind: String, producer_frame: int, observed_frame: int) -> bool:
	if _capacity == 0:
		_reject("not_started")
		return false
	if not _safe_symbol(kind):
		_reject("invalid_kind")
		return false
	if producer_frame < 0 or observed_frame < producer_frame or observed_frame < _last_observed_frame:
		_reject("invalid_frame")
		return false
	if _events.size() >= _capacity:
		_overflow += 1
		_error = "capacity_reached"
		return false
	return true


func _append(kind: String, producer_frame: int, observed_frame: int,
		producer_time_usec: int, parent_id: int, fields: Dictionary, receipt_start: int) -> Dictionary:
	_sequence += 1
	_events.append({
		"id": _sequence, "generation": _generation, "kind": kind,
		"producer_frame": producer_frame, "observed_frame": observed_frame,
		"producer_time_usec": producer_time_usec, "parent_id": parent_id,
		"receipt_start_usec": receipt_start, "receipt_end_usec": Time.get_ticks_usec(),
		"fields": fields,
	})
	_last_observed_frame = observed_frame
	_redactions += _pending_redactions
	_error = ""
	return {"generation": _generation, "id": _sequence}


func _reject(reason: String) -> Dictionary:
	_rejected += 1
	_error = reason
	return {}


func _prepare_fields(fields: Dictionary) -> Dictionary:
	_payload_nodes = 0
	_payload_error = false
	_pending_redactions = 0
	var safe: Dictionary = {}
	for key: Variant in fields:
		_payload_nodes += 1
		if _payload_nodes > MAX_PAYLOAD_NODES:
			_payload_error = true
			return {}
		if typeof(key) != TYPE_STRING or not _safe_symbol(key):
			_payload_error = true
			return {}
		if _sensitive_key(key) or (not _allow_fields.is_empty() and not _allow_fields.has(key)):
			safe[key] = REDACTED
			_pending_redactions += 1
		else:
			safe[key] = _sanitize(fields[key], 0)
			if _payload_error:
				return {}
	return safe


func _sanitize(value: Variant, depth: int) -> Variant:
	_payload_nodes += 1
	if depth > MAX_PAYLOAD_DEPTH or _payload_nodes > MAX_PAYLOAD_NODES:
		_payload_error = true
		return null
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT:
			return value
		TYPE_FLOAT:
			if not is_finite(value):
				_payload_error = true
				return null
			return value
		TYPE_STRING:
			if not _safe_symbol(value) or _sensitive_value(value):
				_pending_redactions += 1
				return REDACTED
			return value
		TYPE_ARRAY:
			var result: Array = []
			for item: Variant in value:
				result.append(_sanitize(item, depth + 1))
				if _payload_error:
					return []
			return result
		TYPE_DICTIONARY:
			var result: Dictionary = {}
			for key: Variant in value:
				_payload_nodes += 1
				if _payload_nodes > MAX_PAYLOAD_NODES:
					_payload_error = true
					return {}
				if typeof(key) != TYPE_STRING or not _safe_symbol(key):
					_payload_error = true
					return {}
				if _sensitive_key(key):
					result[key] = REDACTED
					_pending_redactions += 1
				else:
					result[key] = _sanitize(value[key], depth + 1)
					if _payload_error:
						return {}
			return result
		_:
			_payload_error = true
			return null


func _safe_symbol(value: String) -> bool:
	if value.is_empty() or value.length() > 80:
		return false
	for index: int in range(value.length()):
		var code: int = value.unicode_at(index)
		if not (code >= 65 and code <= 90 or code >= 97 and code <= 122 or
				code >= 48 and code <= 57 or code in [45, 46, 58, 95]):
			return false
	return true


func _sensitive_key(key: String) -> bool:
	var lower: String = key.to_lower()
	for word: String in SENSITIVE_WORDS:
		if lower.contains(word):
			return true
	return false


func _sensitive_value(value: String) -> bool:
	var lower: String = value.to_lower()
	return lower.begins_with("sk-") or lower.begins_with("ghp_") or lower.begins_with("github_pat_")


func _encode(value: Variant) -> Variant:
	match typeof(value):
		TYPE_INT:
			return {"type": "int64", "decimal": str(value)}
		TYPE_FLOAT:
			var stream: StreamPeerBuffer = StreamPeerBuffer.new()
			stream.big_endian = true
			stream.put_double(value)
			return {"type": "float64", "value": value, "bits_be": stream.data_array.hex_encode()}
		TYPE_ARRAY:
			var result: Array = []
			for item: Variant in value:
				result.append(_encode(item))
			return result
		TYPE_DICTIONARY:
			var result: Dictionary = {}
			for key: Variant in value:
				result[key] = _encode(value[key])
			return result
		_:
			return value
