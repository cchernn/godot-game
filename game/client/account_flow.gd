class_name AccountFlow
extends PanelContainer
## Supabase sign-in and the steps before a battle: pick or create a world, create a character.
## The screens are containers in account_flow.tscn (one per step, named below): restyle or rearrange
## them in the editor, keep the node names. This script only fills them in and handles the buttons.
## client_env.json holds only public values (project URL, publishable key). Passwords are never
## stored; the rotating refresh token is kept in user:// so the next launch signs in silently.

signal entered(server_url: String, access_token: String, display_name: String, world_id: String)
signal token_refreshed(access_token: String)
signal backed_out

const ENV_PATH := "res://game/client/client_env.json"
const SESSION_PATH := "user://account.cfg"
const REFRESH_MARGIN_S := 120
## Mirrors services/api/app/rules.py (provisional); the API rejects anything else.
const ORIGINS: Array[String] = ["outcast", "soldier", "scholar"]
const CLASSES: Array[String] = ["warrior", "ranger", "cleric", "rogue"]

## One row per pending join request on the host screen (game/content/ui/join_request_row.tscn).
@export var join_request_row_scene: PackedScene

var env: Dictionary = {}
var access_token: String = ""
var user_email: String = ""

@onready var status: Label = %StatusLabel
@onready var _refresh_timer: Timer = %RefreshTimer
@onready var _steps: Array[Control] = [%SignInStep, %WorldsStep, %JoinStep, %CharacterStep, %HostStep, %CreateCharacterStep, %WaitStep]
@onready var _email: LineEdit = %EmailEdit
@onready var _password: LineEdit = %PasswordEdit
@onready var _signed_in_label: Label = %SignedInLabel
@onready var _world_list: ItemList = %WorldList
@onready var _new_world: LineEdit = %NewWorldEdit
@onready var _world_label: Label = %WorldLabel
@onready var _character_label: Label = %CharacterLabel
@onready var _enter_button: Button = %EnterButton
@onready var _character_name: LineEdit = %CharacterNameEdit
@onready var _origin: OptionButton = %OriginOption
@onready var _class: OptionButton = %ClassOption
@onready var _join_label: Label = %JoinLabel
@onready var _join_poll: Timer = %JoinPollTimer
@onready var _request_join_button: Button = %RequestJoinButton
@onready var _manage_requests: Button = %ManageRequestsButton
@onready var _request_rows: VBoxContainer = %RequestRows
@onready var _host_label: Label = %HostLabel
@onready var _wait_label: Label = %WaitLabel
@onready var _lobby_list: ItemList = %LobbyList

var _refresh_token: String = ""
var _worlds: Array = []
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
	for o in ORIGINS:
		_origin.add_item(o.capitalize())
	for c in CLASSES:
		_class.add_item(c.capitalize())
	_refresh_timer.timeout.connect(_on_refresh_due)
	%SignInButton.pressed.connect(_on_sign_in_pressed.bind(false))
	%CreateAccountButton.pressed.connect(_on_sign_in_pressed.bind(true))
	_password.text_submitted.connect(func(_t: String) -> void: _on_sign_in_pressed(false))
	%PlayButton.pressed.connect(_on_play_pressed)
	_world_list.item_activated.connect(func(_i: int) -> void: _on_play_pressed())
	%JoinBackButton.pressed.connect(_step_worlds)
	%CreateWorldButton.pressed.connect(_on_create_world_pressed)
	%RefreshWorldsButton.pressed.connect(_step_worlds)
	%WorldsSignOutButton.pressed.connect(sign_out_and_show)
	_enter_button.pressed.connect(func() -> void: _enter(str(_character.get("name", ""))))
	%CharacterBackButton.pressed.connect(_on_back)
	%CreateCharacterButton.pressed.connect(_on_create_character_pressed)
	%CreateBackButton.pressed.connect(_on_back)
	%CancelButton.pressed.connect(_on_cancel_pressed)
	_request_join_button.pressed.connect(_on_request_join_pressed)
	%JoinCheckButton.pressed.connect(_check_membership)
	%JoinSignOutButton.pressed.connect(sign_out_and_show)
	_manage_requests.pressed.connect(_step_host)
	%HostBackButton.pressed.connect(func() -> void: _show_character())
	_join_poll.timeout.connect(_check_membership)
	_show_step(%SignInStep)


## Starts the flow with the client config; call once after the scene is ready.
func setup(p_env: Dictionary) -> void:
	env = p_env
	_restore_session()


func _show_step(step: Control) -> void:
	for s in _steps:
		s.visible = s == step
	if step != %JoinStep:
		_join_poll.stop()


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
		_step_after_sign_in()
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


# ---------- Steps ----------

func _step_sign_in() -> void:
	if _email.text == "":
		_email.text = user_email
	_password.text = ""
	_show_step(%SignInStep)


func _on_sign_in_pressed(create: bool) -> void:
	status.text = "Working…"
	var email := _email.text.strip_edges()
	var err: String
	if create:
		err = await sign_up(email, _password.text)
	else:
		err = await sign_in(email, _password.text)
	_password.text = ""
	if err == "":
		status.text = ""
		_step_after_sign_in()
	else:
		status.text = err


func _step_after_sign_in() -> void:
	_step_worlds()


const STANDING_TEXT := {"member": "joined", "pending": "request pending", "rejected": "request declined",
	"removed": "removed", "none": "not joined"}


## The world picker, shown after every sign-in (even with one world). Lists every world with your standing in it.
func _step_worlds() -> void:
	_show_step(%WorldsStep)
	_signed_in_label.text = "Signed in as %s. Choose a world." % user_email
	var r := await api(HTTPClient.METHOD_GET, "/worlds/available")
	if r["status"] != 200:
		status.text = r["error"]
		return
	status.text = ""
	_show_worlds(r["data"])


func _show_worlds(worlds: Array) -> void:
	_worlds = worlds
	_world_list.clear()
	for w: Dictionary in _worlds:
		var standing: String = "host" if w.get("is_host", false) else STANDING_TEXT.get(w["status"], w["status"])
		_world_list.add_item("%s  -  %s  (%d player%s)" % [w["name"], standing, w["members"], "" if w["members"] == 1 else "s"])
	if _worlds.is_empty():
		_signed_in_label.text = "Signed in as %s. There are no worlds yet; create one below." % user_email


func _on_play_pressed() -> void:
	var sel := _world_list.get_selected_items()
	if sel.is_empty():
		status.text = "Select a world first"
		return
	status.text = ""
	_step_character(_worlds[sel[0]])


func _on_create_world_pressed() -> void:
	var n := _new_world.text.strip_edges()
	if n == "":
		status.text = "Enter a world name"
		return
	var c := await api(HTTPClient.METHOD_POST, "/worlds", {"name": n})
	if c["status"] == 201:
		status.text = ""
		_new_world.text = ""
		_step_character(c["data"])
	else:
		status.text = c["error"]


func sign_out_and_show() -> void:
	sign_out()
	status.text = ""
	_step_sign_in()


## Entering a world: first find out whether the user is a member, then show the character or the join screen.
func _step_character(world: Dictionary) -> void:
	_world = world
	_character = {}
	_show_step(%CharacterStep)
	_world_label.text = "World: %s" % world["name"]
	_character_label.text = "Checking your access…"
	_enter_button.disabled = true
	_manage_requests.hide()
	var m := await api(HTTPClient.METHOD_GET, "/worlds/%s/membership" % world["id"])
	if m["status"] != 200:
		_character_label.text = ""
		status.text = m["error"]
		return
	_membership = m["data"]
	_world = _membership["world"]
	if _membership["status"] == "member":
		_show_character()
	else:
		_show_join()


func _show_character() -> void:
	_show_step(%CharacterStep)
	_world_label.text = "World: %s" % _world["name"]
	_character_label.text = "Loading your character…"
	_enter_button.disabled = true
	_manage_requests.visible = _membership.get("is_host", false)
	var r := await api(HTTPClient.METHOD_GET, "/worlds/%s/characters/me" % _world["id"])
	if r["status"] == 200:
		_character = r["data"]
		_character_label.text = "%s — level %d %s (%s), %d XP" % [_character["name"], _character["level"],
			_character["class"], _character["origin"], _character["xp"]]
		_enter_button.disabled = false
	elif r["status"] == 404 or r["status"] == 403:
		_step_create_character()
		return
	else:
		_character_label.text = ""
		status.text = r["error"]
	if _manage_requests.visible:
		var pending := await api(HTTPClient.METHOD_GET, "/worlds/%s/requests" % _world["id"])
		if pending["status"] == 200:
			_manage_requests.text = "Join requests (%d)" % (pending["data"] as Array).size()


# ---------- Joining a world ----------

func _show_join() -> void:
	_show_step(%JoinStep)
	var wname: String = _world["name"]
	var state: String = _membership["status"]
	_join_poll.stop() # only a pending request is worth re-checking
	match state:
		"pending":
			_join_label.text = "Your request to join \"%s\" is waiting for the host's approval. This page checks automatically." % wname
			_join_poll.start()
		"rejected":
			_join_label.text = "The host declined your request to join \"%s\"." % wname
		"removed":
			_join_label.text = "You were removed from \"%s\". You can ask to join again." % wname
		_:
			_join_label.text = "You are not a member of \"%s\" yet. Ask the host to let you in." % wname
	_request_join_button.visible = state != "pending"
	_request_join_button.text = "Ask to join again" if state in ["rejected", "removed"] else "Request to join"


func _on_request_join_pressed() -> void:
	status.text = ""
	var r := await api(HTTPClient.METHOD_POST, "/worlds/%s/requests" % _world["id"])
	if r["status"] == 201 or r["status"] == 409: # 409: a request is already pending
		_membership["status"] = "pending"
		_show_join()
	else:
		status.text = r["error"]


## Re-reads the user's standing (also called by the poll timer while a request is pending).
func _check_membership() -> void:
	var m := await api(HTTPClient.METHOD_GET, "/worlds/%s/membership" % _world["id"])
	if m["status"] != 200 or not %JoinStep.visible:
		return
	_membership = m["data"]
	if _membership["status"] == "member":
		status.text = ""
		_show_character()
	else:
		_show_join()


# ---------- Host: approving requests ----------

func _step_host() -> void:
	_show_step(%HostStep)
	for row in _request_rows.get_children():
		row.queue_free()
	_host_label.text = "Loading requests…"
	var r := await api(HTTPClient.METHOD_GET, "/worlds/%s/requests" % _world["id"])
	if r["status"] != 200:
		_host_label.text = ""
		status.text = r["error"]
		return
	var requests: Array = r["data"]
	_host_label.text = "Join requests" if not requests.is_empty() else "No pending join requests."
	for req: Dictionary in requests:
		var row := join_request_row_scene.instantiate() as JoinRequestRow
		_request_rows.add_child(row)
		var label: Variant = req.get("requester_label")
		row.setup(str(label) if label != null and str(label) != "" else "Player %s" % str(req["user_id"]).left(8))
		row.approved.connect(_decide.bind(str(req["id"]), true, row))
		row.rejected.connect(_decide.bind(str(req["id"]), false, row))


func _decide(request_id: String, approve: bool, row: JoinRequestRow) -> void:
	row.set_busy(true)
	var r := await api(HTTPClient.METHOD_POST, "/worlds/%s/requests/%s/%s" % [_world["id"], request_id, "approve" if approve else "reject"])
	if r["status"] == 200:
		status.text = ""
		row.queue_free()
		await get_tree().process_frame
		if _request_rows.get_child_count() == 0:
			_host_label.text = "No pending join requests."
	else:
		status.text = r["error"]
		row.set_busy(false)


func _step_create_character() -> void:
	_character_name.text = ""
	_show_step(%CreateCharacterStep)


func _on_create_character_pressed() -> void:
	var n := _character_name.text.strip_edges()
	if n == "":
		status.text = "Enter a name"
		return
	var c := await api(HTTPClient.METHOD_POST, "/worlds/%s/characters" % _world["id"],
		{"name": n, "origin": ORIGINS[_origin.selected], "class": CLASSES[_class.selected]})
	if c["status"] == 201:
		status.text = ""
		_step_character(_world)
	else:
		status.text = c["error"]


func _on_back() -> void:
	status.text = ""
	_step_worlds()


func _enter(display_name: String) -> void:
	_wait_label.text = "Connecting to the battle server…"
	_lobby_list.clear()
	_show_step(%WaitStep)
	entered.emit(_server_url(), access_token, display_name, str(_world["id"]))


## The waiting room: who is here and how many the battle needs. Called when the server sends the lobby.
func show_lobby(info: Dictionary) -> void:
	_show_step(%WaitStep)
	var names: Array = info["players"]
	_wait_label.text = "Waiting for players (%d/%d). The battle starts when the party is full." % [names.size(), info["needed"]]
	_lobby_list.clear()
	for n in names:
		_lobby_list.add_item(str(n))


## After a battle: back to the character screen of the world just played (fresh XP).
func return_to_menu() -> void:
	status.text = ""
	_back_to_world()


func _back_to_world() -> void:
	if _world.has("id"):
		_step_character(_world)
	else:
		_step_worlds()


func _on_cancel_pressed() -> void:
	backed_out.emit()
	status.text = ""
	_back_to_world()
