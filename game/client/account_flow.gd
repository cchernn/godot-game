class_name AccountFlow
extends PanelContainer
## Supabase sign-in and the steps before a battle: pick or create a world, create a character.
## client_env.json holds only public values (project URL, publishable key). Passwords are never
## stored; the rotating refresh token is kept in user:// so the next launch signs in silently.

signal entered(server_url: String, access_token: String, display_name: String)
signal token_refreshed(access_token: String)
signal backed_out

const ENV_PATH := "res://game/client/client_env.json"
const SESSION_PATH := "user://account.cfg"
const REFRESH_MARGIN_S := 120
## Mirrors services/api/app/rules.py (provisional); the API rejects anything else.
const ORIGINS: Array[String] = ["outcast", "soldier", "scholar"]
const CLASSES: Array[String] = ["warrior", "ranger", "cleric", "rogue"]

var env: Dictionary = {}
var access_token: String = ""
var user_email: String = ""
var status: Label

var _refresh_token: String = ""
var _body: VBoxContainer
var _refresh_timer: Timer


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


func setup(p_env: Dictionary) -> void:
	env = p_env
	set_anchors_preset(Control.PRESET_CENTER)
	custom_minimum_size = Vector2(420, 0)
	offset_left = -210
	offset_top = -170
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	add_child(v)
	var title := Label.new()
	title.text = "Unnamed"
	v.add_child(title)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 6)
	v.add_child(_body)
	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(status)
	_refresh_timer = Timer.new()
	_refresh_timer.one_shot = true
	_refresh_timer.timeout.connect(_on_refresh_due)
	add_child(_refresh_timer)
	_restore_session()


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

func _clear() -> void:
	for c in _body.get_children():
		c.queue_free()


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_child(l)
	return l


func _edit(placeholder: String, secret: bool = false, text: String = "") -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.secret = secret
	e.text = text
	_body.add_child(e)
	return e


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	_body.add_child(b)
	return b


func _step_sign_in() -> void:
	_clear()
	_label("Sign in")
	var email := _edit("Email", false, user_email)
	var pw := _edit("Password", true)
	var go := func(create: bool) -> void:
		status.text = "Working…"
		var err: String
		if create:
			err = await sign_up(email.text.strip_edges(), pw.text)
		else:
			err = await sign_in(email.text.strip_edges(), pw.text)
		pw.text = ""
		if err == "":
			status.text = ""
			_step_after_sign_in()
		else:
			status.text = err
	pw.text_submitted.connect(func(_t: String) -> void: go.call(false))
	_button("Sign in", go.bind(false))
	_button("Create account", go.bind(true))


func _step_after_sign_in() -> void:
	var fixed := str(env.get("world_id", ""))
	if fixed != "":
		_step_character({"id": fixed, "name": "Prototype world"})
	else:
		_step_worlds()


func _step_worlds() -> void:
	_clear()
	_label("Signed in as %s" % user_email)
	var r := await api(HTTPClient.METHOD_GET, "/worlds")
	if r["status"] != 200:
		status.text = r["error"]
		_button("Retry", _step_worlds)
		_button("Sign out", sign_out_and_show)
		return
	var worlds: Array = r["data"]
	var list := ItemList.new()
	list.custom_minimum_size = Vector2(0, 100)
	for w: Dictionary in worlds:
		list.add_item(w["name"])
	_body.add_child(list)
	_button("Play in selected world", func() -> void:
		var sel := list.get_selected_items()
		if sel.is_empty():
			status.text = "Select a world first"
		else:
			status.text = ""
			_step_character(worlds[sel[0]]))
	var wname := _edit("New world name")
	_button("Create world", func() -> void:
		if wname.text.strip_edges() == "":
			status.text = "Enter a world name"
			return
		var c := await api(HTTPClient.METHOD_POST, "/worlds", {"name": wname.text.strip_edges()})
		if c["status"] == 201:
			status.text = ""
			_step_character(c["data"])
		else:
			status.text = c["error"])
	_button("Sign out", sign_out_and_show)


func sign_out_and_show() -> void:
	sign_out()
	status.text = ""
	_step_sign_in()


func _step_character(world: Dictionary) -> void:
	_clear()
	_label("World: %s" % world["name"])
	var r := await api(HTTPClient.METHOD_GET, "/worlds/%s/characters/me" % world["id"])
	if r["status"] == 200:
		var c: Dictionary = r["data"]
		_label("%s — level %d %s (%s), %d XP" % [c["name"], c["level"], c["class"], c["origin"], c["xp"]])
		_button("Enter battle", func() -> void: _enter(c["name"]))
	elif r["status"] == 404 or r["status"] == 403:
		_step_create_character(world)
		return
	else:
		status.text = r["error"]
	_back_button(world)


func _step_create_character(world: Dictionary) -> void:
	_clear()
	_label("Create your character")
	var nm := _edit("Character name")
	var origin := OptionButton.new()
	for o in ORIGINS:
		origin.add_item(o.capitalize())
	_body.add_child(origin)
	var cls := OptionButton.new()
	for c in CLASSES:
		cls.add_item(c.capitalize())
	_body.add_child(cls)
	_button("Create", func() -> void:
		var n := nm.text.strip_edges()
		if n == "":
			status.text = "Enter a name"
			return
		var c := await api(HTTPClient.METHOD_POST, "/worlds/%s/characters" % world["id"],
			{"name": n, "origin": ORIGINS[origin.selected], "class": CLASSES[cls.selected]})
		if c["status"] == 201:
			status.text = ""
			_step_character(world)
		else:
			status.text = c["error"])
	_back_button(world)


func _back_button(world: Dictionary) -> void:
	if str(env.get("world_id", "")) != "":
		_button("Sign out", sign_out_and_show)
	else:
		_button("Back", _step_worlds)


func _enter(display_name: String) -> void:
	_clear()
	_label("Connecting to the battle server…")
	_button("Cancel", func() -> void:
		backed_out.emit()
		status.text = ""
		_step_after_sign_in())
	entered.emit(_server_url(), access_token, display_name)
