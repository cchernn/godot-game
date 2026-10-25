extends Node
## Autoload shared by client and server so RPC node paths match. It only carries messages;
## the server app and the client decide what they mean. Client->server methods run on the server only.

signal hello_received(peer_id: int, display_name: String, token: String, world_id: String, instance_id: String)
signal plan_received(peer_id: int, actions: Variant)
signal ready_received(peer_id: int, flag: bool)
signal escape_received(peer_id: int)

signal welcomed(info: Dictionary)
signal snapshot_received(snap: Dictionary)
signal events_received(events: Array)
signal plan_result_received(ok: bool, error: String)
signal notice_received(text: String)
signal lobby_received(info: Dictionary)
signal result_received(info: Dictionary)
signal rejected(text: String)


# ---- client -> server ----

@rpc("any_peer", "call_remote", "reliable")
func c_hello(display_name: String, token: String, world_id: String, instance_id: String) -> void:
	if multiplayer.is_server():
		hello_received.emit(multiplayer.get_remote_sender_id(), display_name, token, world_id, instance_id)


@rpc("any_peer", "call_remote", "reliable")
func c_plan(actions: Variant) -> void:
	if multiplayer.is_server():
		plan_received.emit(multiplayer.get_remote_sender_id(), actions)


@rpc("any_peer", "call_remote", "reliable")
func c_ready(flag: bool) -> void:
	if multiplayer.is_server():
		ready_received.emit(multiplayer.get_remote_sender_id(), flag)


## The sender's character leaves the battle (always succeeds for now) and spectates.
@rpc("any_peer", "call_remote", "reliable")
func c_escape() -> void:
	if multiplayer.is_server():
		escape_received.emit(multiplayer.get_remote_sender_id())


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


## {players: [display names], needed: int}: who is waiting and how many are required to start.
@rpc("authority", "call_remote", "reliable")
func s_lobby(info: Dictionary) -> void:
	lobby_received.emit(info)


## End of a battle: {outcome: "players_win"|"players_lose"|"draw"|"escaped", rounds, xp, you: "survived"|"downed"|"eliminated"|"escaped", saved: bool}.
## Sent when the battle finishes (saved = false) and again once the result is stored (saved = true).
@rpc("authority", "call_remote", "reliable")
func s_result(info: Dictionary) -> void:
	result_received.emit(info)
