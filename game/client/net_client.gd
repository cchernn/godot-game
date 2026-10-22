class_name NetClient
extends Node
## WebSocket connection to the game server with automatic reconnection. The session token is issued
## by the server; presenting it after a drop restores the same character.

signal connection_changed(connected: bool)
signal welcomed(info: Dictionary)
signal snapshot(snap: Dictionary)
signal events(list: Array)
signal plan_result(ok: bool, error: String)
signal notice(text: String)
signal rejected(text: String)

const RETRY_MS := 2000

var url: String = ""
var display_name: String = "Guest"
var token: String = ""
## Supabase access token (API mode). When set it is sent instead of the guest session token.
var access_token: String = ""
var persist_token: bool = true
var connected: bool = false
var _connecting: bool = false
var _retry_at: int = 0
var _active: bool = false
var _fatal: bool = false


func _ready() -> void:
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_lost)
	multiplayer.server_disconnected.connect(_on_lost)
	Gateway.welcomed.connect(func(i: Dictionary) -> void:
		if access_token == "":
			token = i["token"]
			_save_token()
		welcomed.emit(i))
	Gateway.snapshot_received.connect(func(s: Dictionary) -> void: snapshot.emit(s))
	Gateway.events_received.connect(func(e: Array) -> void: events.emit(e))
	Gateway.plan_result_received.connect(func(ok: bool, err: String) -> void: plan_result.emit(ok, err))
	Gateway.notice_received.connect(func(t: String) -> void: notice.emit(t))
	Gateway.rejected.connect(func(t: String) -> void:
		_fatal = t.begins_with("Guest access") or t.begins_with("A battle") or t.begins_with("The party") \
			or t.begins_with("Sign-in failed") or t.begins_with("Create a character")
		rejected.emit(t))


func start(p_url: String, p_name: String) -> void:
	url = p_url
	display_name = p_name
	_fatal = false
	_active = true
	if persist_token:
		var cf := ConfigFile.new()
		if cf.load("user://session.cfg") == OK:
			token = cf.get_value(_key(), "token", "")
	_connect_now()


func stop() -> void:
	_active = false
	multiplayer.multiplayer_peer = null


## Drops the socket as a network failure would; the client then reconnects on its own.
func simulate_drop() -> void:
	multiplayer.multiplayer_peer = null
	_on_lost()


func _key() -> String:
	return "%s|%s" % [url, display_name]


func _save_token() -> void:
	if not persist_token:
		return
	var cf := ConfigFile.new()
	cf.load("user://session.cfg")
	cf.set_value(_key(), "token", token)
	cf.save("user://session.cfg")


func _connect_now() -> void:
	var peer := WebSocketMultiplayerPeer.new()
	if peer.create_client(url) != OK:
		_retry_at = Time.get_ticks_msec() + RETRY_MS
		return
	multiplayer.multiplayer_peer = peer
	_connecting = true


func _on_connected() -> void:
	_connecting = false
	connected = true
	connection_changed.emit(true)
	Gateway.c_hello.rpc_id(1, display_name, access_token if access_token != "" else token)


func _on_lost() -> void:
	_connecting = false
	if connected:
		connected = false
		connection_changed.emit(false)
	_retry_at = Time.get_ticks_msec() + RETRY_MS


func _process(_delta: float) -> void:
	if not _active or connected or _connecting or _fatal:
		return
	if _retry_at != 0 and Time.get_ticks_msec() >= _retry_at:
		_retry_at = 0
		_connect_now()


func send_plan(actions: Array) -> void:
	if connected:
		Gateway.c_plan.rpc_id(1, actions)


func send_ready(flag: bool) -> void:
	if connected:
		Gateway.c_ready.rpc_id(1, flag)
