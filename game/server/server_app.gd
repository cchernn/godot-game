extends Node
## Dedicated server application: WebSocket transport, identity, lobby, and the real-time pacing of
## the authoritative Battle (planning timeout, beat cadence, disconnect grace period).
## It owns no gameplay rules; those live in Battle.

const MAX_NAME := 24
const MAX_TOKEN := 64
const AUTH_TIMEOUT_MS := 10_000
const RESTART_DELAY_MS := 10_000

class PlayerRec:
	var token: String
	var player_id: String
	var display_name: String
	var peer_id: int = -1
	var combatant_id: String = ""
	var sent_seq: int = 0
	var character: Dictionary = {} # API mode: the persisted character this seat plays

var cfg: GameConfig
var skills: SkillDb
var port: int = 9080
var env: String = "production" # guests are only honoured when this is "local"
var allow_guests: bool = false
var players_required: int = 2
var fixed_seed: int = -1
## Set when --api-url is given: identity comes from verified Supabase tokens and results are persisted.
var persistence: Persistence = null
var _verifying: Dictionary = {}
var _battle_key: String = ""
## Optional: the activity instance this server runs. Only its roster may join.
var _instance_id: String = ""
var _roster: Dictionary = {} # character id -> true

var _players: Dictionary = {} # token -> PlayerRec
var _by_peer: Dictionary = {} # peer_id -> token
var _pending: Dictionary = {} # peer_id -> connect time (ms)
var _battle: Battle = null
var _planning_deadline: int = 0
var _beat_due: int = 0
var _paused_since: int = 0
var _grace_deadline: int = 0
var _restart_at: int = 0


func _ready() -> void:
	cfg = GameConfig.load_file()
	skills = SkillDb.load_file()
	_parse_args()
	players_required = cfg.get_value("lobby", "players_required")
	if _api_url != "":
		var key := OS.get_environment("GAME_API_SERVER_KEY") # secrets come from the environment, not argv
		if key == "" or _world_id == "":
			push_error("--api-url requires GAME_API_SERVER_KEY and --world-id")
			get_tree().quit(1)
			return
		persistence = HttpPersistence.new(self, _api_url, key, _world_id)
		allow_guests = false # identity must come from the API
		if _instance_id != "":
			var inst := await persistence.get_instance(_instance_id)
			if not inst["ok"] or inst["instance"]["status"] != "active":
				push_error("Instance %s is not available (%s)" % [_instance_id, inst.get("error", inst.get("instance", {}).get("status", ""))])
				get_tree().quit(1)
				return
			for c: Dictionary in inst["instance"]["roster"]:
				_roster[c["id"]] = true
	var peer := WebSocketMultiplayerPeer.new()
	var tls: TLSOptions = null
	if _tls_cert != "":
		tls = TLSOptions.server(load(_tls_key), load(_tls_cert))
	var err := peer.create_server(port, "*", tls)
	if err != OK:
		push_error("Cannot listen on port %d (error %d)" % [port, err])
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(func(id: int) -> void: _pending[id] = Time.get_ticks_msec())
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	Gateway.hello_received.connect(_on_hello)
	Gateway.plan_received.connect(_on_plan)
	Gateway.ready_received.connect(_on_ready)
	print("[server] listening on %s port %d (env=%s, guests=%s, persistence=%s, players_required=%d)" % [
		"wss" if tls else "ws", port, env, allow_guests, "api" if persistence else "off", players_required])


var _api_url: String = ""
var _world_id: String = ""
var _tls_cert: String = ""
var _tls_key: String = ""


func _parse_args() -> void:
	env = OS.get_environment("GAME_ENV") if OS.get_environment("GAME_ENV") != "" else "production"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--port="):
			port = int(arg.get_slice("=", 1))
		elif arg.begins_with("--env="):
			env = arg.get_slice("=", 1)
		elif arg == "--allow-guests":
			allow_guests = true
		elif arg.begins_with("--seed="):
			fixed_seed = int(arg.get_slice("=", 1))
		elif arg.begins_with("--api-url="):
			_api_url = arg.substr(10)
		elif arg.begins_with("--instance-id="):
			_instance_id = arg.substr(14)
		elif arg.begins_with("--world-id="):
			_world_id = arg.substr(11)
		elif arg.begins_with("--tls-cert="):
			_tls_cert = arg.get_slice("=", 1)
		elif arg.begins_with("--tls-key="):
			_tls_key = arg.get_slice("=", 1)
		elif arg.begins_with("--set="): # --set=section.key=value overrides a config value
			var spec := arg.substr(6)
			var path := spec.get_slice("=", 0)
			var val: Variant = JSON.parse_string(spec.get_slice("=", 1))
			cfg.data[path.get_slice(".", 0)][path.get_slice(".", 1)] = val
		elif arg.begins_with("--players="):
			cfg.data["lobby"]["players_required"] = int(arg.get_slice("=", 1))
	# Guest mode is a server-side switch: it can only ever be active in a local environment.
	if env != "local":
		allow_guests = false


# ---------- Connections ----------

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	for id: int in _pending.keys():
		if now - (_pending[id] as int) > AUTH_TIMEOUT_MS:
			_drop(id, "Authentication timeout")
	if _battle == null:
		return
	_tick_battle(now)


func _drop(peer_id: int, why: String) -> void:
	_pending.erase(peer_id)
	if multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		Gateway.s_reject.rpc_id(peer_id, why)
		# Give the reason a moment to flush before closing the socket.
		get_tree().create_timer(0.3).timeout.connect(func() -> void:
			if multiplayer.get_peers().has(peer_id):
				(multiplayer.multiplayer_peer as WebSocketMultiplayerPeer).disconnect_peer(peer_id))


func _on_peer_disconnected(peer_id: int) -> void:
	_pending.erase(peer_id)
	var token: String = _by_peer.get(peer_id, "")
	_by_peer.erase(peer_id)
	if token == "" or not _players.has(token):
		return
	var rec: PlayerRec = _players[token]
	rec.peer_id = -1
	print("[server] %s disconnected" % rec.display_name)
	if _battle == null:
		_players.erase(token) # lobby: free the seat
		_broadcast_lobby()


func _on_hello(peer_id: int, display_name: String, token: String) -> void:
	if _by_peer.has(peer_id) or _verifying.has(peer_id):
		return
	display_name = display_name.strip_edges().left(MAX_NAME)
	if display_name == "":
		display_name = "Player"
	var key := token
	var character := {}
	var player_id := ""
	if persistence != null:
		# The token is a Supabase access token; the API verifies it. The client never supplies an id.
		if token.length() > 4096:
			_drop(peer_id, "Invalid token")
			return
		_verifying[peer_id] = true
		var r := await persistence.verify_session(token)
		_verifying.erase(peer_id)
		if not _pending.has(peer_id) and not multiplayer.get_peers().has(peer_id):
			return # the client left while we were verifying
		if not r["ok"]:
			_drop(peer_id, r["error"])
			return
		if r["character"] == null:
			_drop(peer_id, "Create a character in this world first")
			return
		player_id = r["user_id"]
		key = player_id
		character = r["character"]
		if _instance_id != "" and not _roster.has(character["id"]):
			_drop(peer_id, "You are not on this activity's roster")
			return
	_pending.erase(peer_id)
	var rec: PlayerRec = null
	if key != "" and key.length() <= 4096 and _players.has(key):
		rec = _players[key]
		if rec.peer_id != -1 and rec.peer_id != peer_id: # same identity reconnecting: replace the old socket
			_by_peer.erase(rec.peer_id)
			Gateway.s_reject.rpc_id(rec.peer_id, "Signed in from another location")
			(multiplayer.multiplayer_peer as WebSocketMultiplayerPeer).disconnect_peer(rec.peer_id)
		print("[server] %s reconnected" % rec.display_name)
	else:
		# New seat. Guests are only possible in local development with persistence off.
		if persistence == null and not allow_guests:
			_drop(peer_id, "Guest access is disabled on this server")
			return
		if _battle != null:
			_drop(peer_id, "A battle is already in progress")
			return
		if _players.size() >= Encounter.PLAYER_SLOTS.size():
			_drop(peer_id, "The party is full")
			return
		rec = PlayerRec.new()
		if persistence != null:
			rec.token = key
			rec.player_id = player_id
			rec.character = character
		else:
			rec.token = Crypto.new().generate_random_bytes(16).hex_encode()
			rec.player_id = "guest-" + Crypto.new().generate_random_bytes(4).hex_encode()
		_players[rec.token] = rec
		print("[server] new player %s (%s)" % [display_name, rec.player_id])
	if persistence != null and not rec.character.is_empty():
		display_name = rec.character["name"]
	rec.display_name = display_name
	rec.peer_id = peer_id
	rec.sent_seq = 0
	_by_peer[peer_id] = rec.token
	if _paused_since != 0: # first reconnect after everyone left: shift timers by the pause
		var gap := Time.get_ticks_msec() - _paused_since
		_planning_deadline += gap
		_beat_due += gap
		_paused_since = 0
	_grace_deadline = 0
	Gateway.s_welcome.rpc_id(peer_id, _welcome_info(rec))
	if _battle == null:
		_broadcast_lobby()
		if _players.size() >= players_required:
			_start_battle()
	else:
		_push(rec)


func _welcome_info(rec: PlayerRec) -> Dictionary:
	return {"token": "" if persistence != null else rec.token, "player_id": rec.player_id,
		"combatant_id": rec.combatant_id, "players_required": players_required, "in_battle": _battle != null}


func _broadcast_lobby() -> void:
	for rec: PlayerRec in _players.values():
		if rec.peer_id != -1:
			Gateway.s_notice.rpc_id(rec.peer_id, "Waiting for players (%d/%d)" % [_players.size(), players_required])


func _rec_for(peer_id: int) -> PlayerRec:
	var token: String = _by_peer.get(peer_id, "")
	return _players.get(token) as PlayerRec


# ---------- Battle lifecycle ----------

func _start_battle() -> void:
	var seed := fixed_seed if fixed_seed >= 0 else randi()
	var classes: Array = []
	for rec: PlayerRec in _players.values():
		classes.append(rec.character.get("class", ""))
	_battle = Encounter.build(cfg, skills, _players.size(), seed, classes)
	_battle_key = "battle-" + Crypto.new().generate_random_bytes(12).hex_encode()
	var i := 0
	for rec: PlayerRec in _players.values():
		rec.combatant_id = "pc%d" % i
		rec.sent_seq = 0
		var c := _battle.state.get_c(rec.combatant_id)
		c.controller = rec.player_id
		c.display_name = rec.display_name if persistence != null else "%s (%s)" % [c.display_name, rec.display_name]
		i += 1
	_planning_deadline = Time.get_ticks_msec() + int(cfg.get_value("combat", "planning_timeout_seconds")) * 1000
	_restart_at = 0
	print("[server] battle started with %d players (seed %d)" % [_players.size(), seed])
	for rec: PlayerRec in _players.values():
		if rec.peer_id != -1:
			Gateway.s_welcome.rpc_id(rec.peer_id, _welcome_info(rec))
	_push_all()


func _tick_battle(now: int) -> void:
	var connected := 0
	for rec: PlayerRec in _players.values():
		if rec.peer_id != -1:
			connected += 1
	if connected == 0:
		# Nobody is here: freeze the clock and run the grace period (monotonic).
		if _grace_deadline == 0:
			_grace_deadline = now + int(cfg.get_value("instance", "disconnect_grace_seconds")) * 1000
			_paused_since = now
			print("[server] all players left; grace period started")
		elif now >= _grace_deadline:
			print("[server] grace period expired; instance destroyed")
			_battle = null
			_players.clear()
			_by_peer.clear()
			_grace_deadline = 0
			_paused_since = 0
		return
	var delay: int = cfg.get_value("combat", "beat_delay_ms")
	match _battle.state.phase:
		Enums.RoundPhase.PLANNING:
			if _battle.all_required_ready() or now >= _planning_deadline:
				_battle.begin_resolution()
				_beat_due = now + delay
				_push_all()
		Enums.RoundPhase.RESOLVING:
			if now >= _beat_due:
				_battle.resolve_next_beat()
				_beat_due = now + delay
				if _battle.state.phase == Enums.RoundPhase.PLANNING:
					_planning_deadline = now + int(cfg.get_value("combat", "planning_timeout_seconds")) * 1000
				if _battle.state.phase == Enums.RoundPhase.FINISHED:
					if _instance_id == "": # an activity instance is single-use; prototype lobbies replay
						_restart_at = now + RESTART_DELAY_MS
					print("[server] battle finished: outcome %d" % _battle.outcome)
					_commit_results(_battle, _battle_key)
				_push_all()
		Enums.RoundPhase.FINISHED:
			if _restart_at != 0 and now >= _restart_at:
				_start_battle()


# ---------- Player commands ----------

func _on_plan(peer_id: int, actions: Variant) -> void:
	var rec := _rec_for(peer_id)
	if rec == null or _battle == null:
		return
	var r := _battle.submit_plan(rec.combatant_id, actions)
	Gateway.s_plan_result.rpc_id(peer_id, r["ok"], r["error"])
	_push(rec)


func _on_ready(peer_id: int, flag: bool) -> void:
	var rec := _rec_for(peer_id)
	if rec == null or _battle == null:
		return
	var r := _battle.set_ready(rec.combatant_id, flag)
	if not r["ok"]:
		Gateway.s_plan_result.rpc_id(peer_id, false, r["error"])
	_push_all()


# ---------- Outbound state ----------

func _push_all() -> void:
	for rec: PlayerRec in _players.values():
		_push(rec)


func _push(rec: PlayerRec) -> void:
	if rec.peer_id == -1 or _battle == null:
		return
	var snap := _battle.snapshot_for(rec.combatant_id)
	snap["timer_ms"] = maxi(0, _planning_deadline - Time.get_ticks_msec()) \
		if _battle.state.phase == Enums.RoundPhase.PLANNING else -1
	var online := {}
	for r: PlayerRec in _players.values():
		online[r.combatant_id] = r.peer_id != -1
	for u: Dictionary in snap["units"]:
		if online.has(u["id"]):
			u["online"] = online[u["id"]]
	Gateway.s_snapshot.rpc_id(rec.peer_id, snap)
	var evs := _battle.public_events_since(rec.sent_seq)
	rec.sent_seq = _battle.last_seq()
	if not evs.is_empty():
		Gateway.s_events.rpc_id(rec.peer_id, evs)


# ---------- Persistence ----------

## Commits the finished encounter once. Retried with the same idempotency key, so a retry after a
## lost response can never apply rewards twice.
func _commit_results(battle: Battle, key: String) -> void:
	if persistence == null:
		return
	if _instance_id != "":
		_finish_instance(battle.outcome == Enums.Outcome.PLAYERS_WIN)
	var win := battle.outcome == Enums.Outcome.PLAYERS_WIN
	var xp: int = cfg.get_value("rewards", "xp_participation") + (cfg.get_value("rewards", "xp_victory_bonus") as int if win else 0)
	var participants: Array = []
	for rec: PlayerRec in _players.values():
		var c := battle.state.get_c(rec.combatant_id)
		var outcome := "survived"
		if c.life_state == Enums.LifeState.DOWNED:
			outcome = "downed"
		elif c.life_state == Enums.LifeState.ELIMINATED:
			outcome = "eliminated"
		participants.append({"character_id": rec.character["id"], "outcome": outcome, "xp": xp})
	var outcome_name := {Enums.Outcome.PLAYERS_WIN: "players_win", Enums.Outcome.PLAYERS_LOSE: "players_lose",
		Enums.Outcome.DRAW: "draw"}[battle.outcome] as String
	for attempt in 5:
		var r := await persistence.commit_result(key, outcome_name, battle.state.round_number, participants)
		if r["ok"]:
			print("[server] result committed (%s%s)" % [key, ", duplicate" if r["duplicate"] else ""])
			return
		push_warning("[server] result commit failed (%s); retrying" % r["error"])
		await get_tree().create_timer(1.0 * (attempt + 1)).timeout
	push_error("[server] could not persist result %s" % key)


func _finish_instance(success: bool) -> void:
	for attempt in 5:
		var r := await persistence.finish_instance(_instance_id, success)
		if r["ok"]:
			print("[server] instance %s: world_changed=%s" % ["completed" if success else "cancelled", r["world_changed"]])
			return
		push_warning("[server] instance update failed (%s); retrying" % r["error"])
		await get_tree().create_timer(1.0 * (attempt + 1)).timeout
	push_error("[server] could not update instance %s" % _instance_id)
