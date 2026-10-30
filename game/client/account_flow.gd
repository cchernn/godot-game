class_name AccountFlow
extends Control
## The coordinator for everything before a battle: sign-in, world, joining, the world hub (parties, character,
## world management, settings), the party lobby and the wait for the battle server.
## Each screen is its own scene (game/client/screens/*.tscn) and only announces events through signals; this
## script owns what they share: the Supabase session, the calls to the API, and which screen is showing.
##   signals up (a screen reports what the player did) -> this script -> calls down (it tells a screen what to show)
## client_env.json holds only public values (project URL, publishable key). Passwords are never stored; the
## rotating refresh token is kept in user:// so the next launch signs in silently.

signal entered(server_url: String, access_token: String, display_name: String, world_id: String, instance_id: String)
signal token_refreshed(access_token: String)
signal backed_out

const ENV_PATH := "res://game/client/client_env.json"
const SESSION_PATH := "user://account.cfg"
const REFRESH_MARGIN_S := 120
const REQUEST_SENT := "Request sent. The party leader decides."

var env: Dictionary = {}
var access_token: String = ""
var user_email: String = ""

## The message line: under the menu screens, or over the map in the game view.
var status := StatusLine.new()
@onready var _menu_panel: PanelContainer = %MenuPanel
@onready var _refresh_timer: Timer = %RefreshTimer
## Tells the server this player is still in the world (every few seconds; set in the scene). The server treats a player as
## away after about 30 seconds without one.
@onready var _presence_timer: Timer = %PresenceTimer
@onready var _sign_in: SignInScreen = %SignInScreen
@onready var _worlds_screen: WorldPickerScreen = %WorldPickerScreen
@onready var _join: JoinScreen = %JoinScreen
@onready var _creator: CharacterCreator = %CharacterCreator
@onready var _overworld: OverworldScreen = %OverworldScreen
@onready var _management: WorldManagementScreen = %WorldManagementScreen
@onready var _settings: SettingsScreen = %SettingsScreen
@onready var _lobby: LobbyScreen = %LobbyScreen
## Every screen; exactly one is visible at a time.
@onready var _screens: Array[Control] = [_sign_in, _worlds_screen, _join, _creator, _overworld, _management, _settings, _lobby]
## The character page lives in the game view's Character window.
@onready var _character_screen: CharacterScreen = _overworld.character_screen

var _refresh_token: String = ""
var _world: Dictionary = {}
var _character: Dictionary = {}
## The player's own party (every character is in one), and the entry id of the battle being entered.
var _party_id: String = ""
## Ids of the join requests currently listed on the overworld, so the list is only rebuilt when it changes.
var _shown_requests: Array = []
## True once the overworld has seen the party idle since it opened. The player is only taken into a battle by
## itself when it starts after that, never into one that was already running (or just ended) when they arrived.
var _idle_seen: bool = false
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
	status.menu = %StatusLabel
	status.toast_box = _overworld.toast_box
	status.toast_label = _overworld.toast_label
	_refresh_timer.timeout.connect(_on_refresh_due)
	_presence_timer.timeout.connect(_send_presence)
	_sign_in.sign_in_pressed.connect(_on_sign_in_requested.bind(false))
	_sign_in.create_account_pressed.connect(_on_sign_in_requested.bind(true))
	_worlds_screen.open_world_requested.connect(_step_world)
	_worlds_screen.create_world_requested.connect(_on_create_world_requested)
	_worlds_screen.refresh_requested.connect(_step_worlds)
	_worlds_screen.sign_out_requested.connect(sign_out_and_show)
	_worlds_screen.message.connect(_say)
	_join.request_join_pressed.connect(_on_request_join_pressed)
	_join.check_pressed.connect(_check_membership)
	_join.back_pressed.connect(_step_worlds)
	_join.sign_out_pressed.connect(sign_out_and_show)
	_overworld.character_requested.connect(_step_character_view)
	_overworld.management_pressed.connect(_step_management)
	_overworld.settings_pressed.connect(_step_settings)
	_overworld.switch_world_pressed.connect(_step_worlds)
	_overworld.sign_out_pressed.connect(sign_out_and_show)
	_settings.back_pressed.connect(_enter_game)
	_settings.sign_out_pressed.connect(sign_out_and_show)
	_settings.change_password_requested.connect(_on_change_password_requested)
	_settings.display_name_requested.connect(_on_display_name_requested)
	_settings.volume_changed.connect(AudioSettings.set_volume)
	_character_screen.retire_requested.connect(_on_retire_requested)
	_character_screen.inventory.equip_requested.connect(func(row: String, place: String) -> void:
		_change_inventory(HTTPClient.METHOD_POST, "gear/%s/equip" % row, {"place": place}))
	_character_screen.inventory.unequip_requested.connect(func(row: String) -> void:
		_change_inventory(HTTPClient.METHOD_POST, "gear/%s/unequip" % row))
	_character_screen.inventory.discard_gear_requested.connect(func(row: String) -> void:
		_change_inventory(HTTPClient.METHOD_POST, "gear/%s/discard" % row))
	_character_screen.inventory.discard_item_requested.connect(func(id: String) -> void:
		_change_inventory(HTTPClient.METHOD_POST, "items/%s/discard" % id, {"quantity": 1}))
	_character_screen.inventory.battle_items_changed.connect(func(kinds: Variant) -> void:
		_change_inventory(HTTPClient.METHOD_PUT, "battle-items", {"items": kinds}))
	_creator.create_requested.connect(_on_create_character_requested)
	_creator.back_pressed.connect(_step_worlds)
	_creator.message.connect(_say)
	_overworld.travel_requested.connect(_on_travel_requested)
	_overworld.start_requested.connect(_on_start_requested)
	_overworld.leave_requested.connect(_on_leave_party_pressed)
	_overworld.make_leader_requested.connect(_on_make_leader_requested)
	_overworld.join_requested.connect(_on_party_join_requested)
	_overworld.cancel_join_requested.connect(_on_party_request_cancelled)
	_overworld.decision_made.connect(_decide_party_request)
	_overworld.resume_pressed.connect(_resume_party)
	_overworld.refresh_requested.connect(_refresh_overworld)
	_overworld.chat_submitted.connect(_say_in_world)
	_overworld.chat_poll_requested.connect(_hear_world)
	_management.decision_made.connect(_decide)
	_management.rename_requested.connect(_on_rename_requested)
	_management.remove_member_requested.connect(_on_remove_member_requested)
	_management.delete_requested.connect(_on_delete_world_requested)
	_management.back_pressed.connect(_enter_game)
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
	_menu_panel.visible = screen != _overworld # the game view is the whole screen; every other screen is a panel


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
	var r := await _request(method, _api_base() + path,
		["Authorization: Bearer %s" % access_token, "Content-Type: application/json"], body)
	if r["status"] == 423 and access_token != "": # another login holds this account; this one is dropped, not the holder's
		_drop_refused_login(r["error"])
	return r


## This login was refused because the account is signed in somewhere else. It forgets its own session without releasing
## the account (that belongs to the login that holds it) and returns to the sign-in screen with the reason.
func _drop_refused_login(reason: String) -> void:
	_forget_session()
	_step_sign_in()
	status.text = reason


# ---------- Session ----------

## Returns an error message, or "" on success.
func sign_in(email: String, password: String) -> String:
	if email == "" or password == "":
		return "Enter your email and password"
	var r := await _auth_call("token?grant_type=password", {"email": email, "password": password})
	if r["status"] != 200:
		return r["error"]
	_adopt_session(r["data"])
	return await _claim_session()


## Claims the account's single login. Returns "" when this login holds it, else the reason it was refused (and forgets the session).
func _claim_session() -> String:
	var r := await _request(HTTPClient.METHOD_POST, _api_base() + "/me/session",
		["Authorization: Bearer %s" % access_token, "Content-Type: application/json"])
	if r["status"] == 423:
		_forget_session()
		return r["error"]
	return "" # any other failure (API down) is left to the next call to report


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
	_forget_session()
	backed_out.emit()


func _forget_session() -> void:
	access_token = ""
	_refresh_token = ""
	user_email = ""
	_refresh_timer.stop()
	var cf := ConfigFile.new()
	cf.save(SESSION_PATH)


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
	if not await _refresh():
		_step_sign_in()
		return
	var refused := await _claim_session()
	if refused != "":
		_step_sign_in()
		status.text = refused
		return
	_step_worlds()


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
	if access_token != "": # free the account at once for the next login (a closed tab frees it after the grace instead)
		await _request(HTTPClient.METHOD_POST, _api_base() + "/me/session/release",
			["Authorization: Bearer %s" % access_token, "Content-Type: application/json"])
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
		_step_world(c["data"])
	else:
		status.text = c["error"]


## Entering a world: first find out whether the user is a member, then show the hub or the join screen.
func _step_world(world: Dictionary) -> void:
	_world = world
	_character = {}
	_party_id = ""
	status.text = "Opening %s…" % world["name"]
	var m := await api(HTTPClient.METHOD_GET, "/worlds/%s/membership" % world["id"])
	if m["status"] != 200:
		status.text = m["error"]
		return
	status.text = ""
	_membership = m["data"]
	_world = _membership["world"]
	if _membership["status"] == "member":
		await _post_presence() # first, so the server can tell a new session from a reload before the party is read
		_enter_game()
	else:
		_show_join()


## The heartbeat timer: only while the player is inside a world they belong to (the hub, the map and the battle all count).
func _send_presence() -> void:
	if access_token == "":
		return
	if _sign_in.visible or _worlds_screen.visible or _world.is_empty():
		await _request(HTTPClient.METHOD_POST, _api_base() + "/me/session", # no world yet: still keeps the login alive
			["Authorization: Bearer %s" % access_token, "Content-Type: application/json"])
		return
	await _post_presence()


func _post_presence() -> void:
	if access_token == "" or _world.is_empty() or _membership.get("status", "") != "member":
		return
	await api(HTTPClient.METHOD_POST, "/worlds/%s/presence" % _world["id"])


# ---------- Entering the game ----------

## Opens the game view of the world (the map, with you in your party). First checks the player has a character; if not, the
## creator comes first.
func _enter_game() -> void:
	status.text = ""
	_chat_after = -1 # world chat shows only what is said from now on
	_overworld.chat_panel.clear()
	_idle_seen = false
	_shown_requests = []
	_show(_overworld)
	_overworld.show_loading()
	_overworld.set_host(_membership.get("is_host", false))
	var r := await api(HTTPClient.METHOD_GET, "/worlds/%s/characters/me" % _world["id"])
	if not _overworld.is_visible_in_tree():
		return
	if r["status"] == 404 or r["status"] == 403:
		_step_create_character()
		return
	if r["status"] != 200:
		status.text = r["error"]
		return
	_character = r["data"]
	_overworld.set_header("%s - %s, %s - %d gold" % [_world["name"], _character["name"], _character["class"], int(_character.get("gold", 0))])
	_refresh_overworld()


## Fills the Character window (it asks for this each time it is opened).
func _step_character_view() -> void:
	_character_screen.show_checking(_world["name"])
	_character_screen.show_character(_character)
	_character_screen.inventory.show_checking()
	_load_inventory()
	var b := await api(HTTPClient.METHOD_GET, "/worlds/%s/characters/me/battles" % _world["id"])
	if b["status"] == 200 and _character_screen.is_visible_in_tree():
		_character_screen.show_battles(b["data"])
	var c := await api(HTTPClient.METHOD_GET, "/worlds/%s/characters" % _world["id"])
	if c["status"] == 200 and _character_screen.is_visible_in_tree():
		_character_screen.show_world_characters(c["data"])


## Asks the API to change the bag (equip, discard, battle items) and shows the answer; the Character page is redrawn from it.
func _change_inventory(method: int, path: String, body: Variant = null) -> void:
	var r := await api(method, "/characters/%s/%s" % [_character["id"], path], body)
	if r["status"] != 200:
		_character_screen.inventory.show_error(r["error"])
		_load_inventory()
		return
	_adopt_inventory(r["data"])


func _load_inventory() -> void:
	var r := await api(HTTPClient.METHOD_GET, "/characters/%s/inventory" % _character["id"])
	if r["status"] == 200 and _character_screen.is_visible_in_tree():
		_adopt_inventory(r["data"])


## Keeps the character we hold in step with its bag, so the stats and gear line on the Overview tab follow what was just worn.
func _adopt_inventory(inv: Dictionary) -> void:
	_character["gear"] = inv["gear"]
	_character["items"] = inv["items"]
	_character["battle_items"] = inv["battle_items"]
	_character_screen.show_character(_character)
	_character_screen.inventory.show_inventory(inv)


func _on_retire_requested() -> void:
	var r := await api(HTTPClient.METHOD_POST, "/characters/%s/retire" % _character["id"])
	if r["status"] != 200:
		status.text = r["error"]
		return
	_character = {}
	await _enter_game()  # no active character: the creator comes next
	status.text = "Character retired. Create a new one."


# ---------- Settings ----------

func _step_settings() -> void:
	status.text = ""
	_settings.show_account(user_email)
	_settings.show_volumes(AudioSettings.load_volumes())
	_show(_settings)
	var p := await api(HTTPClient.METHOD_GET, "/me/profile")
	if _settings.visible and p["status"] == 200:
		var chosen: Variant = (p["data"] as Dictionary).get("display_name")
		_settings.show_display_name(str(chosen) if chosen != null else "")


func _on_display_name_requested(display_name: String) -> void:
	var r := await api(HTTPClient.METHOD_PUT, "/me/profile", {"display_name": display_name})
	if r["status"] == 200:
		_settings.show_display_name(str(r["data"]["display_name"]))
		status.text = "Name saved."
	else:
		status.text = "Enter a name of 1 to 24 characters" if r["status"] == 422 else r["error"]


func _on_change_password_requested(new_password: String) -> void:
	if new_password.length() < 6:
		status.text = "Enter a new password of at least 6 characters"
		return
	var base := str(env["supabase_url"]).trim_suffix("/")
	var r := await _request(HTTPClient.METHOD_PUT, "%s/auth/v1/user" % base,
		["apikey: %s" % env["supabase_publishable_key"], "Authorization: Bearer %s" % access_token,
		"Content-Type: application/json"], {"password": new_password})
	if r["status"] == 200:
		_settings.show_account(user_email)
		status.text = "Password changed."
	else:
		status.text = r["error"]


func _step_create_character() -> void:
	_creator.reset()
	_show(_creator)


func _on_create_character_requested(character_name: String, class_id: String) -> void:
	var c := await api(HTTPClient.METHOD_POST, "/worlds/%s/characters" % _world["id"],
		{"name": character_name, "class": class_id})
	if c["status"] == 201:
		status.text = ""
		_enter_game()
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
		_enter_game()
	else:
		_show_join()


# ---------- World management (host) ----------

func _step_management() -> void:
	_show(_management)
	_management.show_loading()
	var r := await api(HTTPClient.METHOD_GET, "/worlds/%s/requests" % _world["id"])
	if r["status"] != 200:
		status.text = r["error"]
		return
	_management.show_requests(r["data"])
	_management.show_world(_world["name"])
	var info := await api(HTTPClient.METHOD_GET, "/worlds/%s/info" % _world["id"])
	if info["status"] == 200:
		_management.show_info(info["data"])
	_refresh_members()


func _refresh_members() -> void:
	var m := await api(HTTPClient.METHOD_GET, "/worlds/%s/members" % _world["id"])
	if m["status"] == 200:
		_management.show_members(m["data"])
	else:
		status.text = m["error"]


func _on_rename_requested(new_name: String) -> void:
	var r := await api(HTTPClient.METHOD_POST, "/worlds/%s/rename" % _world["id"], {"name": new_name})
	if r["status"] != 200:
		status.text = r["error"]
		return
	_world["name"] = r["data"]["name"]
	status.text = "Renamed."
	_management.show_world(_world["name"])


func _on_remove_member_requested(user_id: String) -> void:
	var r := await api(HTTPClient.METHOD_POST, "/worlds/%s/members/%s/remove" % [_world["id"], user_id])
	if r["status"] != 204:
		status.text = r["error"]
		return
	status.text = "Member removed."
	_refresh_members()


func _on_delete_world_requested(confirm_name: String) -> void:
	var r := await api(HTTPClient.METHOD_POST, "/worlds/%s/delete" % _world["id"], {"confirm_name": confirm_name})
	if r["status"] != 204:
		status.text = r["error"]
		return
	_world = {}
	await _step_worlds()
	status.text = "World deleted."


func _decide(request_id: String, approve: bool, row: JoinRequestRow) -> void:
	row.set_busy(true)
	var r := await api(HTTPClient.METHOD_POST, "/worlds/%s/requests/%s/%s" % [_world["id"], request_id, "approve" if approve else "reject"])
	if r["status"] == 200:
		status.text = ""
		_management.finish_decision(row)
	else:
		status.text = r["error"]
		_management.row_failed(row)


# ---------- World chat ----------

## The number of the last world-chat message shown; -1 until the first look (which shows nothing from before).
var _chat_after: int = -1
var _chat_busy: bool = false


func _hear_world() -> void:
	if _chat_busy or _world.is_empty() or not _overworld.is_visible_in_tree():
		return
	_chat_busy = true
	var path := "/worlds/%s/chat" % _world["id"]
	if _chat_after >= 0:
		path += "?after=%d" % _chat_after
	var r := await api(HTTPClient.METHOD_GET, path)
	_chat_busy = false
	if r["status"] != 200 or not _overworld.is_visible_in_tree():
		return
	for m: Dictionary in r["data"]["messages"]:
		_overworld.chat_panel.add_line(m["from"], m["text"], m["mine"])
	_chat_after = int(r["data"]["last"])


func _say_in_world(text: String) -> void:
	var r := await api(HTTPClient.METHOD_POST, "/worlds/%s/chat" % _world["id"], {"text": text})
	if r["status"] != 201:
		_overworld.chat_panel.add_line("", r["error"], false, true)
		return
	_hear_world()


# ---------- Overworld ----------

## Re-reads the map and the parties (also asked for by the overworld's timer). When the party's leader starts an
## activity, the other members are taken into the battle from here.
func _refresh_overworld() -> void:
	var ov := await api(HTTPClient.METHOD_GET, "/worlds/%s/overview" % _world["id"])
	var ps := await api(HTTPClient.METHOD_GET, "/worlds/%s/parties" % _world["id"])
	if not _overworld.is_visible_in_tree():
		return
	if ov["status"] != 200 or ps["status"] != 200:
		status.text = ov["error"] if ov["status"] != 200 else ps["error"]
		return
	_overworld.show_world(ov["data"], ps["data"])
	if _membership.get("is_host", false):
		var pending := await api(HTTPClient.METHOD_GET, "/worlds/%s/requests" % _world["id"])
		if pending["status"] == 200:
			_overworld.set_pending_count((pending["data"] as Array).size())
	var mine := _my_party(ps["data"])
	if mine.is_empty():
		return
	_party_id = str(mine["id"])
	var run: Variant = mine["instance"]
	if run == null:
		_idle_seen = true
	elif run["status"] == "active" and _idle_seen:
		_enter_battle(str(run["id"]))
		return
	if status.text == REQUEST_SENT and not ps["data"].any(func(p: Dictionary) -> bool: return p["relation"] == "pending"):
		status.text = "" # the ask was answered (let in, turned down, or withdrawn)
	if mine["relation"] == "leader" and run == null:
		var q := await api(HTTPClient.METHOD_GET, "/parties/%s/requests" % _party_id)
		if q["status"] == 200 and _overworld.is_visible_in_tree():
			var ids: Array = (q["data"] as Array).map(func(x: Dictionary) -> String: return str(x["id"]))
			if ids != _shown_requests:
				_shown_requests = ids
				_overworld.show_requests(q["data"])
	else:
		_shown_requests = []


## Runs an action on the party and refreshes the map; a refusal is shown as the status line.
func _party_action(path: String, expected: int, body: Dictionary = {}) -> Dictionary:
	var r := await api(HTTPClient.METHOD_POST, path, body)
	status.text = "" if r["status"] == expected else r["error"]
	return r


func _on_travel_requested(node_id: String) -> void:
	await _party_action("/parties/%s/travel" % _party_id, 200, {"node_id": node_id})
	_shown_requests = []
	_refresh_overworld()


func _on_start_requested(activity_id: String) -> void:
	var r := await _party_action("/parties/%s/start" % _party_id, 201, {"activity_id": activity_id})
	if r["status"] == 201:
		_enter_battle(str((r["data"] as Dictionary)["id"]))
	else:
		_refresh_overworld()


func _on_party_join_requested(party: Dictionary) -> void:
	var r := await _party_action("/parties/%s/requests" % party["id"], 201)
	if r["status"] == 201:
		status.text = REQUEST_SENT
	_refresh_overworld()


func _on_party_request_cancelled(party: Dictionary) -> void:
	var r := await api(HTTPClient.METHOD_POST, "/parties/%s/requests/cancel" % party["id"])
	status.text = "" if r["status"] == 204 or r["status"] == 404 else r["error"] # 404: it was already decided
	_refresh_overworld()


func _decide_party_request(request_id: String, approve: bool, row: JoinRequestRow) -> void:
	row.set_busy(true)
	var r := await _party_action("/parties/%s/requests/%s/%s" % [_party_id, request_id, "approve" if approve else "reject"], 200)
	if r["status"] == 200:
		_overworld.finish_decision(row)
		_shown_requests = [""] # differs from any real list, so the next refresh redraws it (and hides the box when empty)
	else:
		_overworld.row_failed(row)
	_refresh_overworld()


func _on_make_leader_requested(character_id: String) -> void:
	await _party_action("/parties/%s/leader" % _party_id, 204, {"character_id": character_id})
	_shown_requests = []
	_refresh_overworld()


func _on_leave_party_pressed() -> void:
	await _party_action("/parties/%s/leave" % _party_id, 204)
	_shown_requests = []
	_refresh_overworld()


## The party this player is on, from a list of party views ({} if none).
func _my_party(parties: Array) -> Dictionary:
	for p: Dictionary in parties:
		if p["relation"] == "leader" or p["relation"] == "member":
			return p
	return {}


## Back into the battle the party is fighting.
func _resume_party() -> void:
	var r := await api(HTTPClient.METHOD_GET, "/worlds/%s/parties/me" % _world["id"])
	if r["status"] != 200:
		status.text = r["error"]
		return
	var run: Variant = (r["data"] as Dictionary)["instance"]
	if run != null and run["status"] == "active":
		_enter_battle(str(run["id"]))
	else:
		_refresh_overworld() # it ended in the meantime


# ---------- Battle server ----------

## Connects to the battle server as a member of the party running this activity (the instance id). Also used to come back to a battle in progress.
func _enter_battle(instance_id: String) -> void:
	_lobby.show_connecting()
	_show(_lobby)
	entered.emit(_server_url(), access_token, str(_character.get("name", "")), str(_world["id"]), instance_id)


## The waiting room on the battle server: who has arrived and how many the party has. Called when the server sends it.
func show_lobby(info: Dictionary) -> void:
	_show(_lobby)
	_lobby.show_lobby(info)


func _on_leave_pressed() -> void:
	backed_out.emit()
	status.text = ""
	_back_to_world()


## After a battle: back to the map of the world just played (the party is idle again).
func return_to_menu() -> void:
	status.text = ""
	_back_to_world()


func _back_to_world() -> void:
	if _world.has("id"):
		_enter_game()
	else:
		_step_worlds()
