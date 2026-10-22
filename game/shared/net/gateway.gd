extends Node
## Autoload shared by client and server so RPC node paths match. It only carries messages;
## the server app and the client decide what they mean. Client->server methods run on the server only.

signal hello_received(peer_id: int, display_name: String, token: String)
signal plan_received(peer_id: int, actions: Variant)
signal ready_received(peer_id: int, flag: bool)

signal welcomed(info: Dictionary)
signal snapshot_received(snap: Dictionary)
signal events_received(events: Array)
signal plan_result_received(ok: bool, error: String)
signal notice_received(text: String)
signal rejected(text: String)


# ---- client -> server ----

@rpc("any_peer", "call_remote", "reliable")
func c_hello(display_name: String, token: String) -> void:
	if multiplayer.is_server():
		hello_received.emit(multiplayer.get_remote_sender_id(), display_name, token)


@rpc("any_peer", "call_remote", "reliable")
func c_plan(actions: Variant) -> void:
	if multiplayer.is_server():
		plan_received.emit(multiplayer.get_remote_sender_id(), actions)


@rpc("any_peer", "call_remote", "reliable")
func c_ready(flag: bool) -> void:
	if multiplayer.is_server():
		ready_received.emit(multiplayer.get_remote_sender_id(), flag)


# ---- server -> client ----

@rpc("authority", "call_remote", "reliable")
func s_welcome(info: Dictionary) -> void:
	welcomed.emit(info)


@rpc("authority", "call_remote", "reliable")
func s_snapshot(snap: Dictionary) -> void:
	snapshot_received.emit(snap)


@rpc("authority", "call_remote", "reliable")
func s_events(events: Array) -> void:
	events_received.emit(events)


@rpc("authority", "call_remote", "reliable")
func s_plan_result(ok: bool, error: String) -> void:
	plan_result_received.emit(ok, error)


@rpc("authority", "call_remote", "reliable")
func s_notice(text: String) -> void:
	notice_received.emit(text)


@rpc("authority", "call_remote", "reliable")
func s_reject(text: String) -> void:
	rejected.emit(text)
