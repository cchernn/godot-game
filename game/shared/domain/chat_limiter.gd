class_name ChatLimiter
extends RefCounted
## At most `messages` per `window_ms` for one player; a message over the limit is refused, not queued.

var messages: int
var window_ms: int
var _sent: Array[int] = []


func _init(p_messages: int, p_window_ms: int) -> void:
	messages = p_messages
	window_ms = p_window_ms


## True (and counted) if a message sent at `now_ms` is within the limit.
func allow(now_ms: int) -> bool:
	while not _sent.is_empty() and now_ms - _sent[0] >= window_ms:
		_sent.pop_front()
	if _sent.size() >= messages:
		return false
	_sent.append(now_ms)
	return true
