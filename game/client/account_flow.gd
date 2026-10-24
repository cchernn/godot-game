class_name AccountFlow
extends PanelContainer
## The coordinator for everything before a battle: sign-in, world, joining, character, lobby.
## Each screen is its own scene (game/client/screens/*.tscn) and only announces events through signals; this
## script owns what they share: the Supabase session, the calls to the API, and which screen is showing.
##   signals up (a screen reports what the player did) -> this script -> calls down (it tells a screen what to show)
## client_env.json holds only public values (project URL, publishable key). Passwords are never stored; the
## rotating refresh token is kept in user:// so the next launch signs in silently.

signal entered(server_url: String, access_token: String, display_name: String, world_id: String)
signal token_refreshed(access_token: String)
signal backed_out

const ENV_PATH := "res://game/client/client_env.json"
const SESSION_PATH := "user://account.cfg"
const REFRESH_MARGIN_S := 120

var env: Dictionary = {}
var access_token: String = ""
var user_email: String = ""

@onready var status: Label = %StatusLabel
@onready var _refresh_timer: Timer = %RefreshTimer
@onready var _sign_in: SignInScreen = %SignInScreen
@onready var _worlds_screen: WorldPickerScreen = %WorldPickerScreen
@onready var _join: JoinScreen = %JoinScreen
@onready var _character_screen: CharacterScreen = %CharacterScreen
@onready var _host: HostRequestsScreen = %HostRequestsScreen
@onready var _creator: CharacterCreator = %CharacterCreator
@onready var _lobby: LobbyScreen = %LobbyScreen
## Every screen; exactly one is visible at a time.
@onready var _screens: Array[Control] = [_sign_in, _worlds_screen, _join, _character_screen, _host, _creator, _lobby]

var _refresh_token: String = ""
var _world: Dictionary = {}
var _character: Dictionary = {}
## The user's standing in the current world: {world: {id, name}, status, is_host}.
var _membership: Dictionary = {}


## Empty when the file is missing or incomplete, which selects the guest/dev connect screen.
static func load_env() -> Dictionary:
	if not FileAccess.file_exists(ENV_PATH):
		return {}
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(ENV_PATH))
	if not d is Dictionary:
		return {}
	var cfg: Dictionary = d
	if str(cfg.get("supabase_url", "")) == "" or str(cfg.get("supabase_publishable_key", "")) == "":
		return {}
	return cfg


func _ready() -> void:
	_refresh_timer.timeout.connect(_on_refresh_due)
	_sign_in.sign_in_pressed.connect(_on_sign_in_requested.bind(false))
	_sign_in.create_account_pressed.connect(_on_sign_in_requested.bind(true))
	_worlds_screen.open_world_requested.connect(_step_character)
	_worlds_screen.create_world_requested.connect(_on_create_world_requested)
	_worlds_screen.refresh_requested.connect(_step_worlds)
	_worlds_screen.sign_out_requested.connect(sign_out_and_show)
	_worlds_screen.message.connect(_say)
	_join.request_join_pressed.connect(_on_request_join_pressed)
	_join.check_pressed.connect(_check_membership)
	_join.back_pressed.connect(_step_worlds)
	_join.sign_out_pressed.connect(sign_out_and_show)
	_character_screen.enter_pressed.connect(func() -> void: _enter(str(_character.get("name", ""))))
	_character_screen.manage_requests_pressed.connect(_step_host)
	_character_screen.back_pressed.connect(_step_worlds)
	_host.decision_made.connect(_decide)
	_host.back_pressed.connect(func() -> void: _show_character())
	_creator.create_requested.connect(_on_create_character_requested)
	_creator.back_pressed.connect(_step_worlds)
	_creator.message.connect(_say)
	_lobby.leave_pressed.connect(_on_leave_pressed)
	_show(_sign_in)


## Starts the flow with the client config; call once after the scene is ready.
func setup(p_env: Dictionary) -> void:
	env = p_env
	if not is_node_ready():
		await ready # the screens are found in _ready, so wait for it if we were called early
	_restore_session()


func _show(screen: Control) -> void:
	for s in _screens:
		s.visible = s == screen


func _say(text: String) -> void:
	status.text = text


# ---------- HTTP ----------

## Returns {status: int (0 = unreachable), data: Variant, error: String}.
func _request(method: int, url: String, headers: PackedStringArray, body: Variant = null) -> Dictionary:
	var http := HTTPRequest.new()
	add_child(http)
	var payload := "" if body == null else JSON.stringify(body)
	if http.request(url, headers, method, payload) != OK:
		http.queue_free()
		return {"status": 0, "data": {}, "error": "Could not reach the server"}
	var res: Array = await http.request_completed
	http.queue_free()
	if res[0] != HTTPRequest.RESULT_SUCCESS:
		return {"status": 0, "data": {}, "error": "Could not reach the server"}
	var text := (res[3] as PackedByteArray).get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(text) if text != "" else {}
	var out := {"status": res[1], "data": parsed if parsed != null else {}, "error": ""}
	if (res[1] as int) >= 400:
		out["error"] = _error_text(out)
	return out


func _error_text(r: Dictionary) -> String:
	if r["data"] is Dictionary:
		for key in ["msg", "error_description", "message", "detail"]:
			var v: Variant = (r["data"] as Dictionary).get(key)
			if v is String and v != "":
				return v
			if v is Array:
				return "Invalid input"
	return "Request failed (%d)" % r["status"]


func _auth_call(path: String, body: Dictionary) -> Dictionary:
	var base := str(env["supabase_url"]).trim_suffix("/")
	return await _request(HTTPClient.METHOD_POST, "%s/auth/v1/%s" % [base, path],
		["apikey: %s" % env["supabase_publishable_key"], "Content-Type: application/json"], body)


## "same-origin" (used by the web build) means: the page's own address, under /api and /ws, which the
## reverse proxy routes to the API and the battle server.
func _api_base() -> String:
	var v := str(env.get("api_url", "http://127.0.0.1:8000")).trim_suffix("/")
	if v == "same-origin" and OS.has_feature("web"):
		return str(JavaScriptBridge.eval("window.location.origin")) + "/api"
	return v


func _server_url() -> String:
	var v := str(env.get("server_url", "ws://127.0.0.1:9080"))
	if v == "same-origin" and OS.has_feature("web"):
		var secure: bool = JavaScriptBridge.eval("window.location.protocol") == "https:"
		return "%s://%s/ws" % ["wss" if secure else "ws", str(JavaScriptBridge.eval("window.location.host"))]
	return v


func api(method: int, path: String, body: Variant = null) -> Dictionary:
	return await _request(method, _api_base() + path,
		["Authorization: Bearer %s" % access_token, "Content-Type: application/json"], body)


# ---------- Session ----------

## Returns an error message, or "" on success.
func sign_in(email: String, password: String) -> String:
	if email == "" or password == "":
		return "Enter your email and password"
	var r := await _auth_call("token?grant_type=password", {"email": email, "password": password})
	if r["status"] != 200:
		return r["error"]
	_adopt_session(r["data"])
	return ""


## Returns an error message, "" when signed in, or a notice starting with "Check" when the
## project requires email confirmation first.
func sign_up(email: String, password: String) -> String:
	if email == "" or password.length() < 6:
		return "Enter an email and a password of at least 6 characters"
	var r := await _auth_call("signup", {"email": email, "password": password})
	if r["status"] != 200:
		return r["error"]
	var d: Dictionary = r["data"]
	if d.has("access_token"):
		_adopt_session(d)
		return ""
	return "Check your email to confirm the account, then sign in."


func sign_out() -> void:
	access_token = ""
	_refresh_token = ""
	user_email = ""
	_refresh_timer.stop()
	var cf := ConfigFile.new()
	cf.save(SESSION_PATH)
	backed_out.emit()


func _adopt_session(d: Dictionary) -> void:
	access_token = d["access_token"]
	_refresh_token = d.get("refresh_token", "")
	var u: Variant = d.get("user")
	if u is Dictionary:
		user_email = str((u as Dictionary).get("email", user_email))
	var ttl: int = int(d.get("expires_in", 3600))
	_refresh_timer.start(maxf(float(ttl - REFRESH_MARGIN_S), 30.0))
	var cf := ConfigFile.new()
	cf.set_value("session", "refresh_token", _refresh_token)
	cf.set_value("session", "email", user_email)
	cf.save(SESSION_PATH)
	token_refreshed.emit(access_token)


func _restore_session() -> void:
	var cf := ConfigFile.new()
	if cf.load(SESSION_PATH) != OK or str(cf.get_value("session", "refresh_token", "")) == "":
		_step_sign_in()
		return
	_refresh_token = cf.get_value("session", "refresh_token")
	user_email = cf.get_value("session", "email", "")
	status.text = "Restoring your session…"
	if await _refresh():
		_step_worlds()
	else:
		_step_sign_in()


func _refresh() -> bool:
	if _refresh_token == "":
		return false
	var r := await _auth_call("token?grant_type=refresh_token", {"refresh_token": _refresh_token})
	if r["status"] != 200:
		status.text = ""
		return false
	_adopt_session(r["data"])
	return true


func _on_refresh_due() -> void:
	if not await _refresh():
		access_token = ""
		status.text = "Your session expired. Sign in again."
		_step_sign_in()


func sign_out_and_show() -> void:
	sign_out()
	status.text = ""
	_step_sign_in()


# ---------- Flow ----------

func _step_sign_in() -> void:
	_sign_in.prefill_email(user_email)
	_sign_in.clear_password()
	_show(_sign_in)


func _on_sign_in_requested(email: String, password: String, create: bool) -> void:
	status.text = "Working…"
	var err: String
	if create:
		err = await sign_up(email, password)
	else:
		err = await sign_in(email, password)
	_sign_in.clear_password()
	if err == "":
		status.text = ""
		_step_worlds()
	else:
		status.text = err


## The world picker, shown after every sign-in (even with one world).
func _step_worlds() -> void:
	_show(_worlds_screen)
	_worlds_screen.begin_loading(user_email)
	var r := await api(HTTPClient.METHOD_GET, "/worlds/available")
	if r["status"] != 200:
		status.text = r["error"]
		return
	status.text = ""
	_worlds_screen.show_worlds(r["data"], user_email)


func _on_create_world_requested(world_name: String) -> void:
	var c := await api(HTTPClient.METHOD_POST, "/worlds", {"name": world_name})
	if c["status"] == 201:
		status.text = ""
		_worlds_screen.clear_new_world()
		_step_character(c["data"])
	else:
		status.text = c["error"]


## Entering a world: first find out whether the user is a member, then show the character or the join screen.
func _step_character(world: Dictionary) -> void:
	_world = world
	_character = {}
	_show(_character_screen)
	_character_screen.show_checking(world["name"])
	var m := await api(HTTPClient.METHOD_GET, "/worlds/%s/membership" % world["id"])
	if m["status"] != 200:
		_character_screen.show_unavailable()
		status.text = m["error"]
		return
	_membership = m["data"]
	_world = _membership["world"]
	if _membership["status"] == "member":
		_show_character()
	else:
		_show_join()


func _show_character() -> void:
	_show(_character_screen)
	_character_screen.show_checking(_world["name"])
	_character_screen.show_loading()
	_character_screen.set_host(_membership.get("is_host", false))
	var r := await api(HTTPClient.METHOD_GET, "/worlds/%s/characters/me" % _world["id"])
	if r["status"] == 200:
		_character = r["data"]
		_character_screen.show_character(_character)
	elif r["status"] == 404 or r["status"] == 403:
		_step_create_character()
		return
	else:
		_character_screen.show_unavailable()
		status.text = r["error"]
	if _membership.get("is_host", false):
		var pending := await api(HTTPClient.METHOD_GET, "/worlds/%s/requests" % _world["id"])
		if pending["status"] == 200:
			_character_screen.set_pending_count((pending["data"] as Array).size())


func _step_create_character() -> void:
	_creator.reset()
	_show(_creator)


func _on_create_character_requested(character_name: String, origin: String, class_id: String) -> void:
	var c := await api(HTTPClient.METHOD_POST, "/worlds/%s/characters" % _world["id"],
		{"name": character_name, "origin": origin, "class": class_id})
	if c["status"] == 201:
		status.text = ""
		_step_character(_world)
	else:
		status.text = c["error"]


# ---------- Joining a world ----------

func _show_join() -> void:
	_show(_join)
	_join.show_state(_world["name"], _membership["status"])


func _on_request_join_pressed() -> void:
	status.text = ""
	var r := await api(HTTPClient.METHOD_POST, "/worlds/%s/requests" % _world["id"])
	if r["status"] == 201 or r["status"] == 409: # 409: a request is already pending
		_membership["status"] = "pending"
		_show_join()
	else:
		status.text = r["error"]


## Re-reads the user's standing (also asked for by the join screen's timer while a request is pending).
func _check_membership() -> void:
	var m := await api(HTTPClient.METHOD_GET, "/worlds/%s/membership" % _world["id"])
	if m["status"] != 200 or not _join.is_visible_in_tree():
		return
	_membership = m["data"]
	if _membership["status"] == "member":
		status.text = ""
		_show_character()
	else:
		_show_join()


# ---------- Host: approving requests ----------

func _step_host() -> void:
	_show(_host)
	_host.show_loading()
	var r := await api(HTTPClient.METHOD_GET, "/worlds/%s/requests" % _world["id"])
	if r["status"] != 200:
		status.text = r["error"]
		return
	_host.show_requests(r["data"])


func _decide(request_id: String, approve: bool, row: JoinRequestRow) -> void:
	row.set_busy(true)
	var r := await api(HTTPClient.METHOD_POST, "/worlds/%s/requests/%s/%s" % [_world["id"], request_id, "approve" if approve else "reject"])
	if r["status"] == 200:
		status.text = ""
		_host.finish_decision(row)
	else:
		status.text = r["error"]
		_host.row_failed(row)


# ---------- Lobby and battle ----------

func _enter(display_name: String) -> void:
	_lobby.show_connecting()
	_show(_lobby)
	entered.emit(_server_url(), access_token, display_name, str(_world["id"]))


## The waiting room: who is here and how many the battle needs. Called when the server sends the lobby.
func show_lobby(info: Dictionary) -> void:
	_show(_lobby)
	_lobby.show_lobby(info)


func _on_leave_pressed() -> void:
	backed_out.emit()
	status.text = ""
	_back_to_world()


## After a battle: back to the character screen of the world just played (fresh XP).
func return_to_menu() -> void:
	status.text = ""
	_back_to_world()


func _back_to_world() -> void:
	if _world.has("id"):
		_step_character(_world)
	else:
		_step_worlds()
