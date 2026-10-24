extends TestCase

const CLIENT := "res://game/client/client_main.tscn"
const ACCOUNT := "res://game/client/account_flow.tscn"
const NAMES := ["StatusLabel", "ApLabel", "SkillBox", "FaceNorth", "FaceEast", "FaceSouth", "FaceWest", "QueueList",
	"UndoButton", "ClearButton", "ReadyButton", "ErrorLabel", "LogView", "Banner", "ResultPanel", "ResultTitle",
	"ResultDetail", "ContinueButton", "BoardHolder", "SidePanel", "ConnectPanel",
	"UrlEdit", "NameEdit", "ConnectButton", "ConnectStatus", "AccountFlow"]


func _client() -> Control:
	var root := (Engine.get_main_loop() as SceneTree).root
	var c := (load(CLIENT) as PackedScene).instantiate() as Control
	c.set("account_mode_enabled", false) # never touch the network or a saved session in tests
	root.add_child(c)
	return c


func _snapshot() -> Dictionary:
	return Encounter.build(GameConfig.load_file(), SkillDb.load_file(), 3, 1).snapshot_for("pc0")


func test_client_scene_has_every_named_node_the_script_needs() -> void:
	var c := _client()
	for n in NAMES:
		assert_true(c.get_node_or_null("%" + n) != null, n)
	assert_true(c.get("skill_button_scene") != null, "skill button scene assigned")
	c.free()


func test_guest_connect_panel_is_shown_and_account_flow_is_hidden() -> void:
	var c := _client()
	assert_true((c.get_node("%ConnectPanel") as Control).visible)
	assert_true(not (c.get_node("%AccountFlow") as Control).visible)
	assert_true((c.get_node("%UrlEdit") as LineEdit).text != "", "address prefilled")
	c.free()


func test_a_snapshot_fills_the_panel_and_builds_skill_buttons() -> void:
	var c := _client()
	c._on_snapshot(_snapshot())
	assert_true(not (c.get_node("%ConnectPanel") as Control).visible, "connect panel hides on the first snapshot")
	assert_true((c.get_node("%StatusLabel") as Label).text.begins_with("Round 1"))
	assert_true((c.get_node("%ApLabel") as Label).text.begins_with("AP: 0 planned"))
	var box := c.get_node("%SkillBox") as VBoxContainer
	assert_eq(box.get_child_count(), 4, "warrior has move, strike, power strike, disrupt")
	var first := box.get_child(0) as Button
	assert_true(first.toggle_mode and first.text.begins_with("Move"))
	assert_true(not (c.get_node("%ReadyButton") as Button).disabled)
	c.free()


func test_pressing_a_skill_and_clicking_a_tile_queues_a_plan() -> void:
	var c := _client()
	c._on_snapshot(_snapshot())
	c._on_skill_pressed("move")
	assert_eq(c.mode, "move")
	assert_eq((c.get_node("%ErrorLabel") as Label).text, c.skills.get_skill("move").hint, "the skill's hint is shown")
	assert_eq(((c.get_node("%SkillBox") as VBoxContainer).get_child(0) as Button).tooltip_text, c.skills.get_skill("move").hint)
	c._on_cell_clicked(Vector2i(1, 2), "")
	assert_eq((c.plan as Array).size(), 1)
	assert_eq((c.get_node("%QueueList") as ItemList).item_count, 1)
	assert_true((c.get_node("%ApLabel") as Label).text.begins_with("AP: 1 planned"))
	var undo := c.get_node("%UndoButton") as Button
	undo.pressed.emit()
	assert_eq((c.plan as Array).size(), 0, "undo button is wired")
	c.free()


func test_events_go_to_the_log() -> void:
	var c := _client()
	c._on_events([{"type": "hit", "text": "Warrior hits Ghoul for 5."}])
	assert_true((c.get_node("%LogView") as RichTextLabel).get_parsed_text().contains("Warrior hits Ghoul"))
	c.free()


func test_the_battle_view_only_exists_during_a_battle() -> void:
	var c := _client()
	assert_true(not (c.get_node("%BoardHolder") as Control).visible, "hidden on the menu")
	assert_true(not (c.get_node("%SidePanel") as Control).visible)
	c._on_snapshot(_snapshot())
	assert_true((c.get_node("%BoardHolder") as Control).visible, "shown once a battle starts")
	assert_true((c.get_node("%SidePanel") as Control).visible)
	c._on_continue_pressed()
	assert_true(not (c.get_node("%BoardHolder") as Control).visible, "hidden again after Continue")
	assert_true((c.get_node("%ConnectPanel") as Control).visible, "back on the menu")
	for b in (c.get_node("%SkillBox") as VBoxContainer).get_children():
		assert_true(b.is_queued_for_deletion(), "old skill buttons are removed")
	assert_true(c.snap.is_empty())
	c.free()


func test_result_panel_shows_outcome_xp_and_continue_leaves() -> void:
	var c := _client()
	c._on_snapshot(_snapshot())
	c._on_result({"outcome": "players_win", "rounds": 4, "xp": 20, "you": "survived", "saved": false})
	var panel := c.get_node("%ResultPanel") as Control
	assert_true(panel.visible)
	assert_eq((c.get_node("%ResultTitle") as Label).text, "VICTORY")
	var detail := (c.get_node("%ResultDetail") as Label).text
	assert_true(detail.contains("Round 4") and detail.contains("+20 XP") and detail.contains("saving"), detail)
	c._on_result({"outcome": "players_win", "rounds": 4, "xp": 20, "you": "survived", "saved": true})
	assert_true(not (c.get_node("%ResultDetail") as Label).text.contains("saving"), "saved update replaces the note")
	c._on_result({"outcome": "players_lose", "rounds": 7, "xp": 5, "you": "downed", "saved": true})
	assert_eq((c.get_node("%ResultTitle") as Label).text, "DEFEAT")
	assert_true((c.get_node("%ResultDetail") as Label).text.contains("downed"))
	(c.get_node("%ContinueButton") as Button).pressed.emit()
	assert_true(not panel.visible, "Continue closes the result")
	c.free()


func test_guest_lobby_message_lists_the_party() -> void:
	var c := _client()
	c._on_lobby({"players": ["Ann", "Bo"], "needed": 3})
	var t := (c.get_node("%ConnectStatus") as Label).text
	assert_true(t.contains("2/3") and t.contains("Ann") and t.contains("Bo"), t)
	c.free()


func _screen(path: String) -> Control:
	var root := (Engine.get_main_loop() as SceneTree).root
	var n := (load(path) as PackedScene).instantiate() as Control
	root.add_child(n)
	return n


func _press(screen: Node, node_name: String) -> void:
	(screen.get_node("%" + node_name) as Button).pressed.emit()


func _flow() -> AccountFlow:
	return _screen(ACCOUNT) as AccountFlow


# ---------- the coordinator ----------

func test_the_coordinator_shows_exactly_one_screen_at_a_time() -> void:
	var f := _flow()
	assert_eq(f._screens.size(), 7)
	for pick: Control in f._screens:
		f._show(pick)
		for other: Control in f._screens:
			assert_eq(other.visible, other == pick, "%s while showing %s" % [other.name, pick.name])
	f.free()


func test_the_coordinator_starts_on_the_sign_in_screen() -> void:
	var f := _flow()
	assert_true((f.get_node("%SignInScreen") as Control).visible)
	assert_true(not (f.get_node("%WorldPickerScreen") as Control).visible)
	f.free()


func test_the_lobby_message_shows_the_lobby_screen_with_the_party() -> void:
	var f := _flow()
	f.show_lobby({"players": ["Aldric", "Brea"], "needed": 3})
	assert_true((f.get_node("%LobbyScreen") as Control).visible)
	var lobby := f.get_node("%LobbyScreen") # a %Name only sees inside its own scene: go through the instance
	assert_true((lobby.get_node("%WaitLabel") as Label).text.contains("2/3"))
	var list := lobby.get_node("%LobbyList") as ItemList
	assert_eq(list.item_count, 2)
	assert_eq(list.get_item_text(0), "Aldric")
	f.show_lobby({"players": ["Aldric"], "needed": 3})
	assert_eq(list.item_count, 1, "the list is replaced, not appended")
	f.free()


func test_screens_can_put_a_message_in_the_flows_status_line() -> void:
	var f := _flow()
	_press(f.get_node("%WorldPickerScreen"), "PlayButton") # nothing selected
	assert_eq((f.get_node("%StatusLabel") as Label).text, "Select a world first")
	f.free()


func test_the_coordinator_turns_error_bodies_into_messages_and_resolves_addresses() -> void:
	var f := _flow()
	assert_eq(f._error_text({"status": 400, "data": {"msg": "Invalid login credentials"}}), "Invalid login credentials")
	assert_eq(f._error_text({"status": 403, "data": {"detail": "Not a member of this world"}}), "Not a member of this world")
	assert_eq(f._error_text({"status": 422, "data": {"detail": [{"loc": ["body"]}]}}), "Invalid input")
	assert_eq(f._error_text({"status": 500, "data": {}}), "Request failed (500)")
	f.env = {"api_url": "http://example.test:8081/", "server_url": "ws://example.test:8082"}
	assert_eq(f._api_base(), "http://example.test:8081", "trailing slash trimmed")
	assert_eq(f._server_url(), "ws://example.test:8082")
	f.free()


# ---------- the screens (each one on its own) ----------

func test_sign_in_screen_announces_what_was_typed() -> void:
	var s := _screen("res://game/client/screens/sign_in_screen.tscn") as SignInScreen
	var got: Array = []
	s.sign_in_pressed.connect(func(e: String, p: String) -> void: got.append(["in", e, p]))
	s.create_account_pressed.connect(func(e: String, p: String) -> void: got.append(["new", e, p]))
	(s.get_node("%EmailEdit") as LineEdit).text = "  me@example.com "
	(s.get_node("%PasswordEdit") as LineEdit).text = "secret"
	_press(s, "SignInButton")
	_press(s, "CreateAccountButton")
	(s.get_node("%PasswordEdit") as LineEdit).text_submitted.emit("secret")
	assert_eq(got, [["in", "me@example.com", "secret"], ["new", "me@example.com", "secret"], ["in", "me@example.com", "secret"]],
		"email is trimmed; Enter in the password box signs in")
	s.prefill_email("other@example.com")
	assert_eq((s.get_node("%EmailEdit") as LineEdit).text, "  me@example.com ", "never overwrites what was typed")
	s.clear_password()
	assert_eq((s.get_node("%PasswordEdit") as LineEdit).text, "")
	assert_true((s.get_node("%PasswordEdit") as LineEdit).secret)
	s.free()


func test_world_picker_lists_every_world_with_your_standing() -> void:
	var s := _screen("res://game/client/screens/world_picker_screen.tscn") as WorldPickerScreen
	s.show_worlds([
		{"id": "a", "name": "Alpha", "members": 3, "status": "member", "is_host": false},
		{"id": "b", "name": "Bravo", "members": 1, "status": "member", "is_host": true},
		{"id": "c", "name": "Charlie", "members": 5, "status": "none", "is_host": false},
		{"id": "d", "name": "Delta", "members": 2, "status": "pending", "is_host": false}], "me@example.com")
	var list := s.get_node("%WorldList") as ItemList
	assert_eq(list.item_count, 4)
	assert_eq(list.get_item_text(0), "Alpha  -  joined  (3 players)")
	assert_eq(list.get_item_text(1), "Bravo  -  host  (1 player)")
	assert_eq(list.get_item_text(2), "Charlie  -  not joined  (5 players)")
	assert_eq(list.get_item_text(3), "Delta  -  request pending  (2 players)")
	s.show_worlds([{"id": "a", "name": "Only", "members": 1, "status": "member", "is_host": false}], "me@example.com")
	assert_eq(list.item_count, 1, "a single world is still listed, never auto-entered")
	s.show_worlds([], "me@example.com")
	assert_true((s.get_node("%SignedInLabel") as Label).text.contains("no worlds yet"))
	s.free()


func test_world_picker_opens_the_selected_world_and_reports_problems() -> void:
	var s := _screen("res://game/client/screens/world_picker_screen.tscn") as WorldPickerScreen
	var opened: Array = []
	var messages: Array[String] = []
	var created: Array[String] = []
	s.open_world_requested.connect(func(w: Dictionary) -> void: opened.append(w["id"]))
	s.message.connect(func(t: String) -> void: messages.append(t))
	s.create_world_requested.connect(func(n: String) -> void: created.append(n))
	s.show_worlds([{"id": "a", "name": "Alpha", "members": 1, "status": "member", "is_host": false},
		{"id": "b", "name": "Bravo", "members": 1, "status": "none", "is_host": false}], "me")
	_press(s, "PlayButton")
	assert_eq(messages.back(), "Select a world first")
	assert_eq(opened, [])
	(s.get_node("%WorldList") as ItemList).select(1)
	_press(s, "PlayButton")
	assert_eq(opened, ["b"])
	(s.get_node("%WorldList") as ItemList).item_activated.emit(0)
	assert_eq(opened, ["b", "a"], "double-click opens too")
	_press(s, "CreateWorldButton")
	assert_eq(messages.back(), "Enter a world name")
	(s.get_node("%NewWorldEdit") as LineEdit).text = "  Fresh "
	_press(s, "CreateWorldButton")
	assert_eq(created, ["Fresh"])
	s.free()


func test_join_screen_explains_each_membership_state() -> void:
	var s := _screen("res://game/client/screens/join_screen.tscn") as JoinScreen
	var request := s.get_node("%RequestJoinButton") as Button
	var label := s.get_node("%JoinLabel") as Label
	s.show_state("Hollow", "none")
	assert_true(request.visible and request.text == "Request to join" and label.text.contains("Hollow"))
	assert_true(not s.is_polling(), "no polling until a request is sent")
	s.show_state("Hollow", "pending")
	assert_true(not request.visible, "cannot ask twice")
	assert_true(label.text.contains("waiting"))
	assert_true(s.is_polling(), "pending requests are checked automatically")
	s.show_state("Hollow", "rejected")
	assert_true(request.visible and request.text == "Ask to join again" and label.text.contains("declined"))
	assert_true(not s.is_polling())
	s.show_state("Hollow", "removed")
	assert_true(label.text.contains("removed"))
	s.show_state("Hollow", "pending")
	s.hide()
	assert_true(not s.is_polling(), "polling stops when the screen is hidden")
	s.free()


func test_join_screen_announces_its_buttons_and_the_poll() -> void:
	var s := _screen("res://game/client/screens/join_screen.tscn") as JoinScreen
	var got: Array[String] = []
	s.request_join_pressed.connect(func() -> void: got.append("request"))
	s.check_pressed.connect(func() -> void: got.append("check"))
	s.back_pressed.connect(func() -> void: got.append("back"))
	s.sign_out_pressed.connect(func() -> void: got.append("out"))
	_press(s, "RequestJoinButton")
	_press(s, "JoinCheckButton")
	_press(s, "JoinBackButton")
	_press(s, "JoinSignOutButton")
	(s.get_node("%PollTimer") as Timer).timeout.emit()
	assert_eq(got, ["request", "check", "back", "out", "check"] as Array[String])
	s.free()


func test_character_screen_shows_the_character_and_host_controls() -> void:
	var s := _screen("res://game/client/screens/character_screen.tscn") as CharacterScreen
	var got: Array[String] = []
	s.enter_pressed.connect(func() -> void: got.append("enter"))
	s.manage_requests_pressed.connect(func() -> void: got.append("manage"))
	s.back_pressed.connect(func() -> void: got.append("back"))
	var enter := s.get_node("%EnterButton") as Button
	s.show_checking("Hollow")
	assert_true(enter.disabled and not (s.get_node("%ManageRequestsButton") as Control).visible)
	assert_eq((s.get_node("%WorldLabel") as Label).text, "World: Hollow")
	s.show_character({"name": "Aldric", "level": 1, "class": "warrior", "origin": "soldier", "xp": 40})
	assert_true(not enter.disabled)
	assert_eq((s.get_node("%CharacterLabel") as Label).text, "Aldric — level 1 warrior (soldier), 40 XP")
	s.set_host(true)
	s.set_pending_count(3)
	assert_eq((s.get_node("%ManageRequestsButton") as Button).text, "Join requests (3)")
	_press(s, "EnterButton")
	_press(s, "ManageRequestsButton")
	_press(s, "CharacterBackButton")
	assert_eq(got, ["enter", "manage", "back"] as Array[String])
	s.show_unavailable()
	assert_true(enter.disabled)
	s.free()


func test_character_creator_announces_the_choice() -> void:
	var s := _screen("res://game/client/screens/character_creator.tscn") as CharacterCreator
	assert_eq((s.get_node("%OriginOption") as OptionButton).item_count, CharacterCreator.ORIGINS.size())
	assert_eq((s.get_node("%ClassOption") as OptionButton).item_count, CharacterCreator.CLASSES.size())
	var made: Array = []
	var messages: Array[String] = []
	s.create_requested.connect(func(n: String, o: String, c: String) -> void: made.append([n, o, c]))
	s.message.connect(func(t: String) -> void: messages.append(t))
	_press(s, "CreateCharacterButton")
	assert_eq(messages, ["Enter a name"] as Array[String])
	assert_eq(made, [])
	(s.get_node("%CharacterNameEdit") as LineEdit).text = " Tessa "
	(s.get_node("%OriginOption") as OptionButton).select(1)
	(s.get_node("%ClassOption") as OptionButton).select(2)
	_press(s, "CreateCharacterButton")
	assert_eq(made, [["Tessa", "soldier", "cleric"]])
	s.reset()
	assert_eq((s.get_node("%CharacterNameEdit") as LineEdit).text, "")
	assert_eq((s.get_node("%ClassOption") as OptionButton).selected, 0)
	s.free()


func test_host_requests_screen_lists_rows_and_reports_decisions() -> void:
	var s := _screen("res://game/client/screens/host_requests_screen.tscn") as HostRequestsScreen
	var got: Array = []
	s.decision_made.connect(func(id: String, ok: bool, _row: JoinRequestRow) -> void: got.append([id, ok]))
	s.show_requests([{"id": "r1", "user_id": "11111111-aaaa", "requester_label": "tester@example.com"},
		{"id": "r2", "user_id": "22222222-bbbb", "requester_label": null}])
	var rows := s.get_node("%RequestRows") as VBoxContainer
	assert_eq(rows.get_child_count(), 2)
	assert_eq(((rows.get_child(0) as JoinRequestRow).get_node("%NameLabel") as Label).text, "tester@example.com")
	assert_eq(((rows.get_child(1) as JoinRequestRow).get_node("%NameLabel") as Label).text, "Player 22222222", "no label: a short id")
	((rows.get_child(0) as JoinRequestRow).get_node("%ApproveButton") as Button).pressed.emit()
	((rows.get_child(1) as JoinRequestRow).get_node("%RejectButton") as Button).pressed.emit()
	assert_eq(got, [["r1", true], ["r2", false]])
	s.show_requests([])
	assert_eq((s.get_node("%HostLabel") as Label).text, "No pending join requests.")
	s.free()


func test_lobby_screen_lists_the_party_and_can_be_left() -> void:
	var s := _screen("res://game/client/screens/lobby_screen.tscn") as LobbyScreen
	var left: Array[bool] = []
	s.leave_pressed.connect(func() -> void: left.append(true))
	s.show_lobby({"players": ["Aldric", "Brea"], "needed": 3})
	assert_true((s.get_node("%WaitLabel") as Label).text.contains("2/3"))
	assert_eq((s.get_node("%LobbyList") as ItemList).item_count, 2)
	s.show_connecting()
	assert_eq((s.get_node("%LobbyList") as ItemList).item_count, 0)
	_press(s, "CancelButton")
	assert_eq(left.size(), 1)
	s.free()


func test_join_request_row_reports_approve_and_reject() -> void:
	var row := _screen("res://game/content/ui/join_request_row.tscn") as JoinRequestRow
	row.setup("tester@example.com")
	assert_eq((row.get_node("%NameLabel") as Label).text, "tester@example.com")
	var events: Array[String] = []
	row.approved.connect(func() -> void: events.append("approved"))
	row.rejected.connect(func() -> void: events.append("rejected"))
	_press(row, "ApproveButton")
	_press(row, "RejectButton")
	assert_eq(events, ["approved", "rejected"] as Array[String])
	row.set_busy(true)
	assert_true((row.get_node("%ApproveButton") as Button).disabled and (row.get_node("%RejectButton") as Button).disabled)
	row.free()
