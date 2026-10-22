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


func test_account_flow_shows_exactly_one_step_at_a_time() -> void:
	var root := (Engine.get_main_loop() as SceneTree).root
	var f := (load(ACCOUNT) as PackedScene).instantiate() as AccountFlow
	root.add_child(f)
	var steps := ["SignInStep", "WorldsStep", "JoinStep", "CharacterStep", "HostStep", "CreateCharacterStep", "WaitStep"]
	for pick in steps:
		f._show_step(f.get_node("%" + pick))
		for n in steps:
			assert_eq((f.get_node("%" + n) as Control).visible, n == pick, "%s while showing %s" % [n, pick])
	assert_eq((f.get_node("%OriginOption") as OptionButton).item_count, AccountFlow.ORIGINS.size())
	assert_eq((f.get_node("%ClassOption") as OptionButton).item_count, AccountFlow.CLASSES.size())
	f.free()


func test_account_flow_turns_error_bodies_into_messages_and_resolves_addresses() -> void:
	var root := (Engine.get_main_loop() as SceneTree).root
	var f := (load(ACCOUNT) as PackedScene).instantiate() as AccountFlow
	root.add_child(f)
	assert_eq(f._error_text({"status": 400, "data": {"msg": "Invalid login credentials"}}), "Invalid login credentials")
	assert_eq(f._error_text({"status": 403, "data": {"detail": "Not a member of this world"}}), "Not a member of this world")
	assert_eq(f._error_text({"status": 422, "data": {"detail": [{"loc": ["body"]}]}}), "Invalid input")
	assert_eq(f._error_text({"status": 500, "data": {}}), "Request failed (500)")
	f.env = {"api_url": "http://example.test:8081/", "server_url": "ws://example.test:8082"}
	assert_eq(f._api_base(), "http://example.test:8081", "trailing slash trimmed")
	assert_eq(f._server_url(), "ws://example.test:8082")
	f.free()


func _account() -> AccountFlow:
	var root := (Engine.get_main_loop() as SceneTree).root
	var f := (load(ACCOUNT) as PackedScene).instantiate() as AccountFlow
	root.add_child(f)
	return f


func test_join_screen_explains_each_membership_state() -> void:
	var f := _account()
	f._world = {"id": "w1", "name": "Hollow"}
	var request := f.get_node("%RequestJoinButton") as Button
	var label := f.get_node("%JoinLabel") as Label
	f._membership = {"status": "none"}
	f._show_join()
	assert_true((f.get_node("%JoinStep") as Control).visible)
	assert_true(request.visible and request.text == "Request to join" and label.text.contains("Hollow"))
	assert_true(f._join_poll.is_stopped(), "no polling until a request is sent")
	f._membership = {"status": "pending"}
	f._show_join()
	assert_true(not request.visible, "cannot ask twice")
	assert_true(label.text.contains("waiting"))
	assert_true(not f._join_poll.is_stopped(), "pending requests are checked automatically")
	f._membership = {"status": "rejected"}
	f._show_join()
	assert_true(request.visible and request.text == "Ask to join again" and label.text.contains("declined"))
	assert_true(f._join_poll.is_stopped())
	f._membership = {"status": "removed"}
	f._show_join()
	assert_true(label.text.contains("removed"))
	f._show_step(f.get_node("%CharacterStep"))
	assert_true(f._join_poll.is_stopped(), "polling stops when leaving the join screen")
	f.free()


func test_lobby_screen_lists_who_is_waiting() -> void:
	var f := _account()
	f.show_lobby({"players": ["Aldric", "Brea"], "needed": 3})
	assert_true((f.get_node("%WaitStep") as Control).visible)
	assert_true((f.get_node("%WaitLabel") as Label).text.contains("2/3"))
	var list := f.get_node("%LobbyList") as ItemList
	assert_eq(list.item_count, 2)
	assert_eq(list.get_item_text(0), "Aldric")
	f.show_lobby({"players": ["Aldric"], "needed": 3})
	assert_eq(list.item_count, 1, "the list is replaced, not appended")
	f.free()


func test_join_request_row_reports_approve_and_reject() -> void:
	var root := (Engine.get_main_loop() as SceneTree).root
	var row := (load("res://game/content/ui/join_request_row.tscn") as PackedScene).instantiate() as JoinRequestRow
	root.add_child(row)
	row.setup("tester@example.com")
	assert_eq((row.get_node("%NameLabel") as Label).text, "tester@example.com")
	var events: Array[String] = []
	row.approved.connect(func() -> void: events.append("approved"))
	row.rejected.connect(func() -> void: events.append("rejected"))
	(row.get_node("%ApproveButton") as Button).pressed.emit()
	(row.get_node("%RejectButton") as Button).pressed.emit()
	assert_eq(events, ["approved", "rejected"] as Array[String])
	row.set_busy(true)
	assert_true((row.get_node("%ApproveButton") as Button).disabled and (row.get_node("%RejectButton") as Button).disabled)
	row.free()


func test_world_picker_lists_every_world_with_your_standing() -> void:
	var f := _account()
	f.user_email = "me@example.com"
	f._show_worlds([
		{"id": "a", "name": "Alpha", "members": 3, "status": "member", "is_host": false},
		{"id": "b", "name": "Bravo", "members": 1, "status": "member", "is_host": true},
		{"id": "c", "name": "Charlie", "members": 5, "status": "none", "is_host": false},
		{"id": "d", "name": "Delta", "members": 2, "status": "pending", "is_host": false}])
	var list := f.get_node("%WorldList") as ItemList
	assert_eq(list.item_count, 4)
	assert_eq(list.get_item_text(0), "Alpha  -  joined  (3 players)")
	assert_eq(list.get_item_text(1), "Bravo  -  host  (1 player)")
	assert_eq(list.get_item_text(2), "Charlie  -  not joined  (5 players)")
	assert_eq(list.get_item_text(3), "Delta  -  request pending  (2 players)")
	f._show_worlds([{"id": "a", "name": "Only", "members": 1, "status": "member", "is_host": false}])
	assert_eq(list.item_count, 1, "a single world is still listed, never auto-entered")
	f._show_worlds([])
	assert_true((f.get_node("%SignedInLabel") as Label).text.contains("no worlds yet"))
	f.free()


func test_opening_a_world_needs_a_selection_and_every_screen_can_go_back_to_the_list() -> void:
	var f := _account()
	f._show_step(f.get_node("%WorldsStep"))
	f._show_worlds([{"id": "a", "name": "Alpha", "members": 1, "status": "member", "is_host": false}])
	f._on_play_pressed()
	assert_eq((f.get_node("%StatusLabel") as Label).text, "Select a world first")
	for back in ["JoinBackButton", "CharacterBackButton", "CreateBackButton"]:
		assert_true(f.get_node("%" + back) != null, back)
	f.free()
