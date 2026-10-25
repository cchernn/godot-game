extends Node
## Dedicated server application: WebSocket transport, identity, lobbies, and the real-time pacing of the
## authoritative Battle (planning timeout, beat cadence, disconnect grace period).
## It owns no gameplay rules; those live in Battle.
##
## One server hosts many rooms, one per party (an activity instance): every player names the world and the
## party they are entering, the API confirms their character is on that party's roster, and the room runs the
## battle of the party's activity. Rooms never see each other. Guest play (local development only) has a single
## anonymous room that starts when enough guests have connected.

const MAX_NAME := 24
const MAX_TOKEN := 64
const AUTH_TIMEOUT_MS := 10_000
## How long a finished battle keeps its players on the result screen before the server resets for the next party.
const RESULT_HOLD_MS := 120_000

class PlayerRec:
	var token: String
	var player_id: String
	var display_name: String
	var peer_id: int = -1
	var room_key: String = "" # the room this player is in (the party's id; "" for guest play)
	var combatant_id: String = ""
	var sent_seq: int = 0
	var character: Dictionary = {} # API mode: the persisted character this seat plays

## One party's gathering and battle, with its own clocks.
class Room:
	var key: String
	var world_id: String = ""
	var instance_id: String = "" # the party (API mode); empty for guest play
	var def: EncounterDef = null # the activity's encounter; null means the default one (guest play)
	var roster: Array = [] # [{id, user_id, name, class}] in seat order (API mode)
	var gather_deadline: int = 0 # when to start with whoever has arrived
	var battle: Battle = null
	var battle_key: String = ""
	var planning_deadline: int = 0
	var beat_due: int = 0
	var paused_since: int = 0
	var grace_deadline: int = 0
	var reset_at: int = 0
	var result_info: Dictionary = {} # last battle's result, resent to a player who reconnects to the result screen

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
## Optional: serve only this world (set by --world-id). Empty = any world.
var _world_filter: String = ""

var _players: Dictionary = {} # token -> PlayerRec
var _by_peer: Dictionary = {} # peer_id -> token
var _pending: Dictionary = {} # peer_id -> connect time (ms)
var _rooms: Dictionary = {} # party id (guest play: "") -> Room


func _ready() -> void:
	cfg = GameConfig.load_file()
	skills = SkillDb.load_file()
	_parse_args()
	players_required = cfg.get_value("lobby", "players_required")
	if _api_url != "":
		var key := OS.get_environment("GAME_API_SERVER_KEY") # secrets come from the environment, not argv
		if key == "":
			push_error("--api-url requires GAME_API_SERVER_KEY")
			get_tree().quit(1)
			return
		persistence = HttpPersistence.new(self, _api_url, key)
		allow_guests = false # identity must come from the API
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
	Gateway.escape_received.connect(_on_escape)
	print("[server] listening on %s port %d (env=%s, guests=%s, persistence=%s, players_required=%d, worlds=%s)" % [
		"wss" if tls else "ws", port, env, allow_guests, "api" if persistence else "off", players_required,
		_world_filter if _world_filter != "" else "any"])


var _api_url: String = ""
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
		elif arg.begins_with("--world-id="):
			_world_filter = arg.substr(11)
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


# ---------- Rooms ----------

func _room(key: String) -> Room:
	if not _rooms.has(key):
		var r := Room.new()
		r.key = key
		_rooms[key] = r
	return _rooms[key]


func _members(room: Room) -> Array[PlayerRec]:
	var out: Array[PlayerRec] = []
	for rec: PlayerRec in _players.values():
		if rec.room_key == room.key:
			out.append(rec)
	return out


## Forgets a room nobody is in and no battle is running.
func _drop_if_idle(room: Room) -> void:
	if room.battle == null and _members(room).is_empty():
		_rooms.erase(room.key)


func _valid_uuid(id: String) -> bool:
	if id.length() != 36:
		return false
	for ch in id:
		if not (ch in "0123456789abcdefABCDEF-"):
			return false
	return true


# ---------- Connections ----------

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	for id: int in _pending.keys():
		if now - (_pending[id] as int) > AUTH_TIMEOUT_MS:
			_drop(id, "Authentication timeout")
	for room: Room in _rooms.values():
		if room.battle != null:
			_tick_battle(room, now)
		elif room.gather_deadline != 0 and now >= room.gather_deadline:
			room.gather_deadline = 0
			if not _members(room).is_empty():
				print("[server] gather time is up; starting party %s with whoever is here" % room.key)
				_start_battle(room)


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
	var room := _rooms.get(rec.room_key) as Room
	if room == null:
		return
	if room.battle == null:
		_players.erase(token) # lobby: free the seat
		_broadcast_lobby(room)
		_drop_if_idle(room)
	elif room.battle.state.phase == Enums.RoundPhase.FINISHED:
		_players.erase(token) # left the result screen: free the seat; the last one out resets the room
		if _members(room).is_empty():
			_reset_room(room)


func _on_hello(peer_id: int, display_name: String, token: String, world_id: String, instance_id: String) -> void:
	if _by_peer.has(peer_id) or _verifying.has(peer_id):
		return
	display_name = display_name.strip_edges().left(MAX_NAME)
	if display_name == "":
		display_name = "Player"
	var key := token
	var character := {}
	var player_id := ""
	var room_key := ""
	var party := {}
	if persistence != null:
		# The token is a Supabase access token; the API verifies it. The client never supplies an id.
		if token.length() > 4096:
			_drop(peer_id, "Invalid token")
			return
		if not _valid_uuid(world_id):
			_drop(peer_id, "Choose a world first")
			return
		if not _valid_uuid(instance_id):
			_drop(peer_id, "Choose a party first")
			return
		if _world_filter != "" and world_id.to_lower() != _world_filter.to_lower():
			_drop(peer_id, "This server does not run that world")
			return
		room_key = instance_id.to_lower()
		_verifying[peer_id] = true
		var r := await persistence.verify_session(token, world_id.to_lower(), room_key)
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
		party = r["instance"]
	_pending.erase(peer_id)
	var rec: PlayerRec = null
	if key != "" and key.length() <= 4096 and _players.has(key):
		rec = _players[key]
		if rec.room_key != room_key:
			# Same identity entering a different party: allowed only if the old room is not mid-battle.
			var old := _rooms.get(rec.room_key) as Room
			if old != null and old.battle != null and old.battle.state.phase != Enums.RoundPhase.FINISHED:
				_drop(peer_id, "You are in a battle in another party")
				return
			if rec.peer_id != -1:
				_by_peer.erase(rec.peer_id)
				Gateway.s_reject.rpc_id(rec.peer_id, "You entered another party")
				(multiplayer.multiplayer_peer as WebSocketMultiplayerPeer).disconnect_peer(rec.peer_id)
			_players.erase(key)
			if old != null:
				_broadcast_lobby(old)
				_drop_if_idle(old)
			rec = null
	var room := _room(room_key)
	if persistence != null and room.instance_id == "":
		var problem := _setup_party_room(room, world_id.to_lower(), party)
		if problem != "":
			_drop(peer_id, problem)
			_drop_if_idle(room)
			return
	if rec != null:
		if rec.peer_id != -1 and rec.peer_id != peer_id: # same identity reconnecting: replace the old socket
			_by_peer.erase(rec.peer_id)
			Gateway.s_reject.rpc_id(rec.peer_id, "Signed in from another location")
			(multiplayer.multiplayer_peer as WebSocketMultiplayerPeer).disconnect_peer(rec.peer_id)
		print("[server] %s reconnected" % rec.display_name)
	else:
		# New seat. Guests are only possible in local development with persistence off.
		if persistence == null and not allow_guests:
			_drop(peer_id, "Guest access is disabled on this server")
			_drop_if_idle(room)
			return
		if room.battle != null:
			var finished := room.battle.state.phase == Enums.RoundPhase.FINISHED
			_drop(peer_id, "The previous battle is wrapping up. Try again in a moment." if finished else "A battle is already in progress")
			return
		if _members(room).size() >= _seats(room):
			_drop(peer_id, "The party is full")
			return
		rec = PlayerRec.new()
		rec.room_key = room_key
		if persistence != null:
			rec.token = key
			rec.player_id = player_id
			rec.character = character
		else:
			rec.token = Crypto.new().generate_random_bytes(16).hex_encode()
			rec.player_id = "guest-" + Crypto.new().generate_random_bytes(4).hex_encode()
		_players[rec.token] = rec
		print("[server] new player %s (%s) in party %s" % [display_name, rec.player_id, room_key if room_key != "" else "-"])
	if persistence != null and not rec.character.is_empty():
		display_name = rec.character["name"]
	rec.display_name = display_name
	rec.peer_id = peer_id
	rec.sent_seq = 0
	_by_peer[peer_id] = rec.token
	if room.paused_since != 0: # first reconnect after everyone left: shift timers by the pause
		var gap := Time.get_ticks_msec() - room.paused_since
		room.planning_deadline += gap
		room.beat_due += gap
		room.paused_since = 0
	room.grace_deadline = 0
	Gateway.s_welcome.rpc_id(peer_id, _welcome_info(rec, room))
	if room.battle == null:
		_broadcast_lobby(room)
		if _members(room).size() >= _seats(room):
			_start_battle(room)
		elif room.gather_deadline == 0 and persistence != null:
			room.gather_deadline = Time.get_ticks_msec() + int(cfg.get_value("lobby", "gather_seconds")) * 1000
	else:
		_push(rec)
		if room.battle.state.phase == Enums.RoundPhase.FINISHED and not room.result_info.is_empty():
			Gateway.s_result.rpc_id(peer_id, _result_for(room, rec))


func _welcome_info(rec: PlayerRec, room: Room) -> Dictionary:
	return {"token": "" if persistence != null else rec.token, "player_id": rec.player_id,
		"combatant_id": rec.combatant_id, "players_required": _seats(room), "in_battle": room.battle != null}


func _broadcast_lobby(room: Room) -> void:
	var members := _members(room)
	var names: Array = []
	for rec in members:
		names.append(rec.display_name)
	var info := {"players": names, "needed": _seats(room)}
	for rec in members:
		if rec.peer_id != -1:
			Gateway.s_lobby.rpc_id(rec.peer_id, info)


func _rec_for(peer_id: int) -> PlayerRec:
	var token: String = _by_peer.get(peer_id, "")
	return _players.get(token) as PlayerRec


func _room_of(rec: PlayerRec) -> Room:
	return _rooms.get(rec.room_key) as Room


## How many seats the room fills before the battle starts: the whole roster, or the guest lobby size.
func _seats(room: Room) -> int:
	return room.roster.size() if room.instance_id != "" else players_required


## Fills in a party room from the API's description of the party. Returns a reason if it cannot run.
func _setup_party_room(room: Room, world_id: String, party: Dictionary) -> String:
	var def := Encounter.load_definition(str(party.get("encounter", "")))
	if def == null:
		return "This activity's encounter is missing"
	if (party["roster"] as Array).size() > def.max_players():
		return "This activity's encounter has fewer seats than the party"
	room.world_id = world_id
	room.instance_id = room.key
	room.def = def
	room.roster = party["roster"]
	return ""


# ---------- Battle lifecycle ----------

func _start_battle(room: Room) -> void:
	var seed := fixed_seed if fixed_seed >= 0 else randi()
	room.gather_deadline = 0
	_seat_the_roster(room)
	var members := _members(room)
	var classes: Array = []
	for rec in members:
		classes.append(rec.character.get("class", ""))
	room.battle = Encounter.build(cfg, skills, members.size(), seed, classes, room.def)
	room.battle_key = "battle-" + Crypto.new().generate_random_bytes(12).hex_encode()
	var i := 0
	for rec in members:
		rec.combatant_id = "pc%d" % i
		rec.sent_seq = 0
		var c := room.battle.state.get_c(rec.combatant_id)
		c.controller = rec.player_id
		c.display_name = rec.display_name if persistence != null else "%s (%s)" % [c.display_name, rec.display_name]
		i += 1
	room.planning_deadline = Time.get_ticks_msec() + int(cfg.get_value("combat", "planning_timeout_seconds")) * 1000
	room.reset_at = 0
	room.result_info = {}
	print("[server] battle started with %d players (seed %d, party %s)" % [members.size(), seed, room.key if room.key != "" else "-"])
	for rec in members:
		if rec.peer_id != -1:
			Gateway.s_welcome.rpc_id(rec.peer_id, _welcome_info(rec, room))
	_push_all(room)


## A party's battle has a seat for every roster member, in roster order, whether or not they have arrived;
## someone who is late (or never comes) is treated like a disconnected player and can still join in.
func _seat_the_roster(room: Room) -> void:
	for c: Dictionary in room.roster:
		if _players.has(c["user_id"]):
			continue
		var rec := PlayerRec.new()
		rec.token = c["user_id"]
		rec.player_id = c["user_id"]
		rec.room_key = room.key
		rec.display_name = c["name"]
		rec.character = c
		_players[rec.token] = rec


func _tick_battle(room: Room, now: int) -> void:
	var battle := room.battle
	if battle.state.phase == Enums.RoundPhase.FINISHED:
		# The result screen: no clock to run. Reset once everyone has left, or after a hold time.
		if room.reset_at != 0 and now >= room.reset_at:
			print("[server] result hold expired; resetting")
			_reset_room(room, true)
		return
	var members := _members(room)
	var connected := 0
	for rec in members:
		if rec.peer_id != -1:
			connected += 1
	if connected == 0:
		# Nobody is here: freeze the clock and run the grace period (monotonic).
		if room.grace_deadline == 0:
			room.grace_deadline = now + int(cfg.get_value("instance", "disconnect_grace_seconds")) * 1000
			room.paused_since = now
			print("[server] all players left; grace period started")
		elif now >= room.grace_deadline:
			print("[server] grace period expired; party battle abandoned")
			for rec in members:
				_players.erase(rec.token)
			if room.instance_id != "":
				_finish_instance(room.instance_id, false)
			room.battle = null
			room.grace_deadline = 0
			room.paused_since = 0
			_drop_if_idle(room)
		return
	var delay: int = cfg.get_value("combat", "beat_delay_ms")
	match battle.state.phase:
		Enums.RoundPhase.PLANNING:
			if battle.all_required_ready() or now >= room.planning_deadline:
				battle.begin_resolution()
				room.beat_due = now + delay
				_push_all(room)
		Enums.RoundPhase.RESOLVING:
			if now >= room.beat_due:
				battle.resolve_next_beat()
				room.beat_due = now + delay
				if battle.state.phase == Enums.RoundPhase.PLANNING:
					room.planning_deadline = now + int(cfg.get_value("combat", "planning_timeout_seconds")) * 1000
				_push_all(room)
				_conclude_if_finished(room, now)


## Once a battle has just ended (by a beat or by the last escape), start the result hold and store the result.
func _conclude_if_finished(room: Room, now: int) -> void:
	var battle := room.battle
	if battle.state.phase != Enums.RoundPhase.FINISHED or room.reset_at != 0:
		return
	room.reset_at = now + RESULT_HOLD_MS
	print("[server] battle finished: outcome %d (party %s)" % [battle.outcome, room.key if room.key != "" else "-"])
	_finish_battle(room, battle, room.battle_key)


## Back to an empty lobby for the next party; `kick` disconnects anyone still on the result screen.
func _reset_room(room: Room, kick: bool = false) -> void:
	for rec in _members(room):
		if kick and rec.peer_id != -1:
			_drop(rec.peer_id, "The battle has ended")
		_by_peer.erase(rec.peer_id)
		_players.erase(rec.token)
	room.battle = null
	room.reset_at = 0
	room.result_info = {}
	room.grace_deadline = 0
	room.paused_since = 0
	print("[server] room reset (party %s)" % (room.key if room.key != "" else "-"))
	_drop_if_idle(room)


# ---------- Player commands ----------

func _on_plan(peer_id: int, actions: Variant) -> void:
	var rec := _rec_for(peer_id)
	var room := _room_of(rec) if rec != null else null
	if room == null or room.battle == null:
		return
	var r := room.battle.submit_plan(rec.combatant_id, actions)
	Gateway.s_plan_result.rpc_id(peer_id, r["ok"], r["error"])
	_push(rec)


func _on_ready(peer_id: int, flag: bool) -> void:
	var rec := _rec_for(peer_id)
	var room := _room_of(rec) if rec != null else null
	if room == null or room.battle == null:
		return
	var r := room.battle.set_ready(rec.combatant_id, flag)
	if not r["ok"]:
		Gateway.s_plan_result.rpc_id(peer_id, false, r["error"])
	_push_all(room)


func _on_escape(peer_id: int) -> void:
	var rec := _rec_for(peer_id)
	var room := _room_of(rec) if rec != null else null
	if room == null or room.battle == null:
		return
	var r := room.battle.escape(rec.combatant_id)
	if not r["ok"]:
		Gateway.s_plan_result.rpc_id(peer_id, false, r["error"])
	_push_all(room)
	_conclude_if_finished(room, Time.get_ticks_msec())


# ---------- Outbound state ----------

func _push_all(room: Room) -> void:
	for rec in _members(room):
		_push(rec)


func _push(rec: PlayerRec) -> void:
	var room := _room_of(rec)
	if rec.peer_id == -1 or room == null or room.battle == null:
		return
	var battle := room.battle
	var snap := battle.snapshot_for(rec.combatant_id)
	snap["timer_ms"] = maxi(0, room.planning_deadline - Time.get_ticks_msec()) \
		if battle.state.phase == Enums.RoundPhase.PLANNING else -1
	var online := {}
	for r in _members(room):
		online[r.combatant_id] = r.peer_id != -1
	for u: Dictionary in snap["units"]:
		if online.has(u["id"]):
			u["online"] = online[u["id"]]
	Gateway.s_snapshot.rpc_id(rec.peer_id, snap)
	var evs := battle.public_events_since(rec.sent_seq)
	rec.sent_seq = battle.last_seq()
	if not evs.is_empty():
		Gateway.s_events.rpc_id(rec.peer_id, evs)


# ---------- Persistence ----------

## Tells the players how it ended, stores the result, then tells them it is saved.
func _finish_battle(room: Room, battle: Battle, key: String) -> void:
	var names := {Enums.Outcome.PLAYERS_WIN: "players_win", Enums.Outcome.PLAYERS_LOSE: "players_lose",
		Enums.Outcome.DRAW: "draw", Enums.Outcome.ESCAPED: "escaped"}
	room.result_info = {"outcome": names[battle.outcome], "rounds": battle.state.round_number, "saved": persistence == null}
	_send_results(room, battle)
	if persistence == null:
		return
	await _commit_results(room, battle, key)
	if room.battle == battle: # the room may have reset while we were storing
		room.result_info["saved"] = true
		_send_results(room, battle)


func _send_results(room: Room, battle: Battle) -> void:
	for rec in _members(room):
		if rec.peer_id == -1:
			continue
		Gateway.s_result.rpc_id(rec.peer_id, _result_for(room, rec))


## The result as one player sees it: the room's outcome plus what became of their own character.
func _result_for(room: Room, rec: PlayerRec) -> Dictionary:
	var info := room.result_info.duplicate()
	var c := room.battle.state.get_c(rec.combatant_id)
	info["you"] = _fate(c)
	info["xp"] = _xp_for(room.battle, c) if persistence != null else 0
	return info


func _fate(c: Combatant) -> String:
	match c.life_state:
		Enums.LifeState.DOWNED:
			return "downed"
		Enums.LifeState.ELIMINATED:
			return "eliminated"
		Enums.LifeState.ESCAPED:
			return "escaped"
	return "survived"


## XP for one character: everyone gets the participation share; the victory bonus goes to those still in the fight at the end.
func _xp_for(battle: Battle, c: Combatant) -> int:
	var bonus: int = cfg.get_value("rewards", "xp_victory_bonus")
	var won := battle.outcome == Enums.Outcome.PLAYERS_WIN and c.life_state != Enums.LifeState.ESCAPED
	return (cfg.get_value("rewards", "xp_participation") as int) + (bonus if won else 0)


## Commits the finished encounter once. Retried with the same idempotency key, so a retry after a
## lost response can never apply rewards twice.
func _commit_results(room: Room, battle: Battle, key: String) -> void:
	if room.instance_id != "":
		_finish_instance(room.instance_id, battle.outcome == Enums.Outcome.PLAYERS_WIN)
	var participants: Array = []
	for rec in _members(room):
		var c := battle.state.get_c(rec.combatant_id)
		participants.append({"character_id": rec.character["id"], "outcome": _fate(c), "xp": _xp_for(battle, c)})
	var outcome_name := {Enums.Outcome.PLAYERS_WIN: "players_win", Enums.Outcome.PLAYERS_LOSE: "players_lose",
		Enums.Outcome.DRAW: "draw", Enums.Outcome.ESCAPED: "escaped"}[battle.outcome] as String
	for attempt in 5:
		var r := await persistence.commit_result(room.world_id, key, outcome_name, battle.state.round_number, participants)
		if r["ok"]:
			print("[server] result committed (%s%s)" % [key, ", duplicate" if r["duplicate"] else ""])
			return
		push_warning("[server] result commit failed (%s); retrying" % r["error"])
		await get_tree().create_timer(1.0 * (attempt + 1)).timeout
	push_error("[server] could not persist result %s" % key)


func _finish_instance(instance_id: String, success: bool) -> void:
	for attempt in 5:
		var r := await persistence.finish_instance(instance_id, success)
		if r["ok"]:
			print("[server] instance %s: world_changed=%s" % ["completed" if success else "cancelled", r["world_changed"]])
			return
		push_warning("[server] instance update failed (%s); retrying" % r["error"])
		await get_tree().create_timer(1.0 * (attempt + 1)).timeout
	push_error("[server] could not update instance %s" % instance_id)
