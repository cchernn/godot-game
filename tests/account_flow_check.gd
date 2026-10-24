extends SceneTree
## Live check of AccountFlow against real Supabase and a running local API (not part of scripts/test.sh).
##   ACCT_EMAIL / ACCT_PASSWORD: a test user.  Requires the API on client_env.json's api_url.

var _fails := 0


func _check(ok: bool, what: String) -> void:
	print(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		_fails += 1


func _initialize() -> void:
	var env := AccountFlow.load_env()
	_check(not env.is_empty(), "client_env.json loads")
	var flow := (load("res://game/client/account_flow.tscn") as PackedScene).instantiate() as AccountFlow
	root.add_child(flow)
	flow.env = env # no setup(): that would restore a saved session from this machine
	await process_frame
	var email := OS.get_environment("ACCT_EMAIL")
	var password := OS.get_environment("ACCT_PASSWORD")

	_check(await flow.sign_in(email, "definitely-wrong") != "", "wrong password is rejected")
	_check(flow.access_token == "", "no token after a failed sign-in")
	_check(await flow.sign_in(email, password) == "", "sign-in succeeds")
	_check(flow.access_token != "", "access token received")

	var worlds := await flow.api(HTTPClient.METHOD_GET, "/worlds")
	_check(worlds["status"] == 200 and (worlds["data"] as Array).size() > 0, "API accepts the Supabase token (/worlds)")
	var available := await flow.api(HTTPClient.METHOD_GET, "/worlds/available")
	_check(available["status"] == 200 and (available["data"] as Array).size() > 0, "world picker data (/worlds/available)")
	var wid := ""
	for w: Dictionary in available["data"]:
		if w["status"] == "member":
			wid = w["id"]
			break
	var me := await flow.api(HTTPClient.METHOD_GET, "/worlds/%s/characters/me" % wid)
	_check(me["status"] == 200, "character lookup (%s)" % str(me["data"].get("name", me["error"]) if me["data"] is Dictionary else ""))

	var entered: Array = []
	flow.entered.connect(func(url: String, tok: String, nm: String, world: String) -> void: entered.append([url, tok, nm, world]))
	flow._world = {"id": wid, "name": "picked"}
	flow._enter("Aldric")
	_check(entered.size() == 1 and entered[0][1] == flow.access_token and entered[0][0] == env["server_url"] and entered[0][3] == wid,
		"entering emits server URL, token and the chosen world")

	var old := flow.access_token
	_check(await flow._refresh(), "refresh token exchange works")
	_check(flow.access_token != "" and flow.access_token != old, "a new access token was issued")

	await flow._step_worlds()
	await process_frame
	print("INFO  status label: '%s'" % flow.status.text)
	print("RESULT " + ("OK" if _fails == 0 else "FAILED (%d)" % _fails))
	quit(0 if _fails == 0 else 1)
