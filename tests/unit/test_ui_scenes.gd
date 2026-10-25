extends TestCase

const CLIENT := "res://game/client/client_main.tscn"
const ACCOUNT := "res://game/client/account_flow.tscn"
const NAMES := ["StatusLabel", "ApLabel", "SkillBox", "FaceNorth", "FaceEast", "FaceSouth", "FaceWest", "QueueList",
	"UndoButton", "ClearButton", "ReadyButton", "ErrorLabel", "LogView", "Banner", "ResultPanel", "ResultTitle",
	"ResultDetail", "ContinueButton", "BoardHolder", "SidePanel", "ConnectPanel",
	"UrlEdit", "NameEdit", "ConnectButton", "ConnectStatus", "AccountFlow", "UnitStrip", "PartyCards", "EnemyCards", "HoverLabel", "BeatsLabel"]


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


func test_the_strip_shows_one_card_per_visible_unit_with_you_first() -> void:
	var c := _client()
	var s := _snapshot()
	c._on_snapshot(s)
	var party := c.get_node("%PartyCards") as HBoxContainer
	var enemies := c.get_node("%EnemyCards") as HBoxContainer
	var allies := (s["units"] as Array).filter(func(u: Dictionary) -> bool: return u["team"] == Enums.Team.PLAYERS)
	var foes := (s["units"] as Array).filter(func(u: Dictionary) -> bool: return u["team"] != Enums.Team.PLAYERS)
	assert_eq(party.get_child_count(), allies.size())
	assert_eq(enemies.get_child_count(), foes.size(), "only enemies in sight get a card")
	assert_eq(party.get_child(0).name, StringName(s["you"]), "your own card comes first")
	assert_true((c.get_node("%UnitStrip") as Control).visible)
	c._on_snapshot(s) # a second snapshot reuses the cards
	assert_eq(party.get_child_count(), allies.size())
	c.free()


func test_unit_card_shows_hp_ap_and_ready_state() -> void:
	var card := (load("res://game/content/ui/unit_card.tscn") as PackedScene).instantiate() as UnitCard
	(Engine.get_main_loop() as SceneTree).root.add_child(card)
	var u := {"id": "pc1", "name": "Brea", "visual": "ranger", "team": Enums.Team.PLAYERS, "hp": 12, "max_hp": 28,
		"life": Enums.LifeState.ALIVE, "ready": false, "active": true, "ap_capacity": 4, "ap_reserved": 0}
	card.show_unit(u, Enums.RoundPhase.PLANNING, false)
	assert_eq((card.get_node("%NameLabel") as Label).text, "Brea - Ranger")
	assert_eq((card.get_node("%HpLabel") as Label).text, "HP 12/28")
	assert_eq((card.get_node("%HpBar") as ProgressBar).value, 12.0)
	assert_eq((card.get_node("%StatusLabel") as Label).text, "AP 4 - Planning")
	u["ready"] = true
	u["ap_reserved"] = 2
	card.show_unit(u, Enums.RoundPhase.PLANNING, true)
	assert_eq((card.get_node("%NameLabel") as Label).text, "Brea (you) - Ranger")
	assert_eq((card.get_node("%StatusLabel") as Label).text, "AP 4 (2 reserved) - Ready")
	u["life"] = Enums.LifeState.DOWNED
	card.show_unit(u, Enums.RoundPhase.RESOLVING, false)
	assert_eq((card.get_node("%StatusLabel") as Label).text, "AP 4 (2 reserved) - Downed")
	var e := {"id": "g1", "name": "Ghoul", "visual": "ghoul", "team": Enums.Team.ENEMIES, "hp": 9, "max_hp": 18,
		"life": Enums.LifeState.ALIVE, "ready": false, "active": true}
	card.show_unit(e, Enums.RoundPhase.PLANNING, false)
	assert_eq((card.get_node("%NameLabel") as Label).text, "Ghoul", "no class and no AP for an enemy")
	assert_eq((card.get_node("%StatusLabel") as Label).text, "")
	card.free()


func test_picking_a_skill_shades_the_board_and_the_queue_shows_beats() -> void:
	var c := _client()
	c._on_snapshot(_snapshot())
	var board := c.board as Board3D
	assert_eq(board.range_cells.size(), 0, "nothing is shaded until a skill is picked")
	assert_eq((c.get_node("%BeatsLabel") as Label).text, "Beats used: 0 of 8")
	c._on_skill_pressed("move")
	assert_true(board.range_cells.size() > 0, "reachable tiles are shaded")
	assert_eq(board.valid_cells.size(), 0)
	c._on_skill_pressed("strike")
	assert_true(board.range_cells.size() > 0, "a strike's reach is shaded")
	c._on_skill_pressed("move")
	c._on_cell_clicked(Vector2i(1, 2), "")
	assert_true((c.get_node("%QueueList") as ItemList).get_item_text(0).ends_with("[1 AP, beat 1]"))
	assert_eq((c.get_node("%BeatsLabel") as Label).text, "Beats used: 1 of 8")
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
	assert_eq(f._screens.size(), 12)
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


func test_the_coordinator_finds_your_party_in_the_list() -> void:
	var f := _flow()
	assert_eq(f._my_party([_party("a", "none"), _party("b", "pending")]), {})
	assert_eq(f._my_party([_party("a", "none"), _party("b", "member")])["id"], "b")
	assert_eq(f._my_party([_party("a", "leader")])["id"], "a")
	assert_eq(f._my_party([]), {})
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


func test_character_screen_shows_stats_skills_battles_and_everyones_characters() -> void:
	var s := _screen("res://game/client/screens/character_screen.tscn") as CharacterScreen
	var got: Array[String] = []
	s.back_pressed.connect(func() -> void: got.append("back"))
	s.retire_requested.connect(func() -> void: got.append("retire"))
	s.show_checking("Hollow")
	assert_eq((s.get_node("%WorldLabel") as Label).text, "World: Hollow")
	s.show_character({"name": "Aldric", "level": 1, "class": "warrior", "xp": 0})
	assert_eq((s.get_node("%CharacterLabel") as Label).text, "Aldric\nLevel 1 Warrior")
	assert_eq((s.get_node("%XpLabel") as Label).text, "0 XP")
	assert_true((s.get_node("%StatsLabel") as Label).text.begins_with("HP "), "stats come from the class resource")
	assert_true((s.get_node("%SkillsList") as ItemList).item_count >= 2, "and so do the skills")
	s.show_battles([{"created_at": "2026-10-25T12:00:00+00:00", "result": "players_win", "outcome": "survived", "xp_awarded": 100}])
	assert_eq((s.get_node("%BattlesList") as ItemList).get_item_text(0), "2026-10-25  Victory - survived, +100 XP")
	s.show_battles([])
	assert_eq((s.get_node("%BattlesLabel") as Label).text, "No battles yet.")
	s.show_world_characters([
		{"name": "Aldric", "class": "warrior", "owner": "Host", "mine": true, "status": "active"},
		{"name": "Tessa", "class": "rogue", "owner": "tess@example.com", "mine": false, "status": "retired"}])
	assert_eq((s.get_node("%RosterList") as ItemList).get_item_text(0), "Aldric - Warrior, Host (you)")
	assert_eq((s.get_node("%FallenList") as ItemList).get_item_text(0), "Tessa - Rogue, tess@example.com")
	var retire := s.get_node("%RetireButton") as Button
	var edit := s.get_node("%RetireConfirmEdit") as LineEdit
	assert_true(retire.disabled)
	edit.text = "aldric"
	edit.text_changed.emit("aldric")
	assert_true(retire.disabled, "the name must match exactly")
	edit.text = "Aldric"
	edit.text_changed.emit("Aldric")
	assert_true(not retire.disabled)
	retire.pressed.emit()
	_press(s, "CharacterBackButton")
	assert_eq(got, ["retire", "back"] as Array[String])
	s.show_unavailable()
	assert_eq((s.get_node("%CharacterLabel") as Label).text, "")
	s.free()


func test_character_creator_announces_the_choice() -> void:
	var s := _screen("res://game/client/screens/character_creator.tscn") as CharacterCreator
	assert_eq((s.get_node("%ClassOption") as OptionButton).item_count, CharacterCreator.CLASSES.size())
	var made: Array = []
	var messages: Array[String] = []
	s.create_requested.connect(func(n: String, c: String) -> void: made.append([n, c]))
	s.message.connect(func(t: String) -> void: messages.append(t))
	_press(s, "CreateCharacterButton")
	assert_eq(messages, ["Enter a name"] as Array[String])
	assert_eq(made, [])
	(s.get_node("%CharacterNameEdit") as LineEdit).text = " Tessa "
	(s.get_node("%ClassOption") as OptionButton).select(2)
	_press(s, "CreateCharacterButton")
	assert_eq(made, [["Tessa", "cleric"]])
	s.reset()
	assert_eq((s.get_node("%CharacterNameEdit") as LineEdit).text, "")
	assert_eq((s.get_node("%ClassOption") as OptionButton).selected, 0)
	s.free()


func test_world_management_screen_lists_rows_and_reports_decisions() -> void:
	var s := _screen("res://game/client/screens/world_management_screen.tscn") as WorldManagementScreen
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
	assert_eq((s.get_node("%ManagementLabel") as Label).text, "No pending join requests.")
	s.show_info({"template_id": "prototype", "definition_version": 1, "created_at": "2026-10-20T08:00:00+00:00",
		"members": 3, "characters": 2, "live_parties": 1, "battles": 7})
	assert_eq((s.get_node("%WorldInfoLabel") as Label).text,
		"Template prototype v1, created 2026-10-20\n3 members, 2 characters, 1 live parties, 7 battles fought")
	s.free()


func test_world_management_renames_removes_members_and_guards_delete() -> void:
	var s := _screen("res://game/client/screens/world_management_screen.tscn") as WorldManagementScreen
	var got: Array = []
	s.rename_requested.connect(func(n: String) -> void: got.append(["rename", n]))
	s.remove_member_requested.connect(func(u: String) -> void: got.append(["remove", u]))
	s.delete_requested.connect(func(n: String) -> void: got.append(["delete", n]))
	s.show_world("Hollow")
	s.show_members([{"user_id": "h-1", "role": "host", "character_name": "Aldric", "label": null},
		{"user_id": "m-2", "role": "member", "character_name": null, "label": "tess@example.com"}])
	var list := s.get_node("%MembersList") as ItemList
	var remove := s.get_node("%RemoveMemberButton") as Button
	var del := s.get_node("%DeleteButton") as Button
	var edit := s.get_node("%DeleteConfirmEdit") as LineEdit
	var name_edit := s.get_node("%WorldNameEdit") as LineEdit
	assert_eq(list.get_item_text(0), "Aldric  (host)")
	assert_eq(list.get_item_text(1), "tess@example.com")
	assert_true(not list.is_item_selectable(0), "the host cannot be picked for removal")
	assert_true(remove.disabled and del.disabled)
	remove.pressed.emit()
	list.select(1)
	list.item_selected.emit(1)
	assert_true(not remove.disabled)
	remove.pressed.emit()
	(s.get_node("%RenameButton") as Button).pressed.emit()
	assert_eq(got, [["remove", "m-2"]], "an unchanged name is not a rename")
	name_edit.text = "Hollowmere"
	(s.get_node("%RenameButton") as Button).pressed.emit()
	edit.text = "hollow"
	edit.text_changed.emit("hollow")
	assert_true(del.disabled, "the name must match exactly")
	edit.text = "Hollow"
	edit.text_changed.emit("Hollow")
	assert_true(not del.disabled)
	del.pressed.emit()
	assert_eq(got, [["remove", "m-2"], ["rename", "Hollowmere"], ["delete", "Hollow"]])
	s.free()


func test_world_hub_shows_who_you_are_and_announces_each_door() -> void:
	var s := _screen("res://game/client/screens/world_hub_screen.tscn") as WorldHubScreen
	var got: Array[String] = []
	for sig in ["parties_pressed", "character_pressed", "management_pressed", "settings_pressed", "resume_pressed",
			"switch_world_pressed"]:
		s.connect(sig, func() -> void: got.append(sig))
	s.show_loading("Hollow")
	assert_eq((s.get_node("%HubWorldLabel") as Label).text, "Hollow")
	assert_true(not (s.get_node("%ManagementButton") as Control).visible and not (s.get_node("%ResumeButton") as Control).visible)
	s.show_character({"name": "Aldric", "level": 2, "class": "warrior"})
	assert_eq((s.get_node("%HubCharacterLabel") as Label).text, "Aldric, level 2 warrior")
	s.show_party({})
	assert_eq((s.get_node("%HubPartyLabel") as Label).text, "You are not in a party.")
	assert_true(not (s.get_node("%ResumeButton") as Control).visible)
	var party := {"activity_name": "Training skirmish", "status": "forming", "members": [{}, {}], "max_players": 4}
	s.show_party(party)
	assert_eq((s.get_node("%HubPartyLabel") as Label).text, "Your party: Training skirmish (gathering, 2/4)")
	assert_eq((s.get_node("%ResumeButton") as Button).text, "Open party")
	party["status"] = "active"
	s.show_party(party)
	assert_eq((s.get_node("%ResumeButton") as Button).text, "Return to battle", "a started party is rejoined, not opened")
	s.set_host(true)
	assert_true((s.get_node("%ManagementButton") as Control).visible)
	s.set_pending_count(3)
	assert_eq((s.get_node("%ManagementButton") as Button).text, "World management (3 requests)")
	s.set_pending_count(1)
	assert_eq((s.get_node("%ManagementButton") as Button).text, "World management (1 request)")
	s.set_pending_count(0)
	assert_eq((s.get_node("%ManagementButton") as Button).text, "World management")
	for b in ["PartiesButton", "CharacterButton", "ManagementButton", "SettingsButton", "ResumeButton", "SwitchWorldButton"]:
		_press(s, b)
	assert_eq(got, ["parties_pressed", "character_pressed", "management_pressed", "settings_pressed", "resume_pressed",
		"switch_world_pressed"] as Array[String])
	s.free()


func test_settings_screen_shows_the_account_and_announces_its_actions() -> void:
	var s := _screen("res://game/client/screens/settings_screen.tscn") as SettingsScreen
	var got: Array = []
	s.back_pressed.connect(func() -> void: got.append("back"))
	s.sign_out_pressed.connect(func() -> void: got.append("out"))
	s.change_password_requested.connect(func(p: String) -> void: got.append(p))
	s.show_account("a@example.com")
	assert_eq((s.get_node("%AccountEmailLabel") as Label).text, "Signed in as a@example.com")
	(s.get_node("%NewPasswordEdit") as LineEdit).text = "hunter22"
	_press(s, "ChangePasswordButton")
	_press(s, "SettingsSignOutButton")
	_press(s, "SettingsBackButton")
	assert_eq(got, ["hunter22", "out", "back"])
	s.show_account("a@example.com")
	assert_eq((s.get_node("%NewPasswordEdit") as LineEdit).text, "", "the typed password is cleared")
	s.free()


func _party(id: String, relation: String, status: String = "forming", members: int = 2, open: bool = true) -> Dictionary:
	var m: Array = []
	for i in members:
		m.append({"id": "c%d" % i, "name": "Hero%d" % i, "class": "warrior"})
	return {"id": id, "activity_id": "training_skirmish", "activity_name": "Training skirmish", "kind": "minor",
		"status": status, "max_players": 4, "leader": m[0], "members": m, "relation": relation, "open": open}


func test_parties_screen_lists_parties_and_offers_the_right_action() -> void:
	var s := _screen("res://game/client/screens/parties_screen.tscn") as PartiesScreen
	var got: Array = []
	s.request_join_requested.connect(func(p: Dictionary) -> void: got.append(["join", p["id"]]))
	s.cancel_request_requested.connect(func(p: Dictionary) -> void: got.append(["cancel", p["id"]]))
	s.open_party_requested.connect(func(p: Dictionary) -> void: got.append(["open", p["id"]]))
	s.create_party_pressed.connect(func() -> void: got.append(["create"]))
	var list := s.get_node("%PartyList") as ItemList
	var action := s.get_node("%PartyActionButton") as Button
	s.show_parties([])
	assert_eq((s.get_node("%PartiesLabel") as Label).text, "No parties are forming. Start one.")
	s.show_parties([_party("a", "none"), _party("b", "pending"), _party("c", "member"), _party("d", "leader", "active"),
			_party("e", "none", "forming", 4, false)])
	assert_eq(list.item_count, 5)
	assert_eq(list.get_item_text(0), "Training skirmish - led by Hero0 - 2/4 - gathering")
	assert_true(list.get_item_text(1).ends_with("[request sent]") and list.get_item_text(2).ends_with("[your party]"))
	assert_true(list.get_item_text(3).contains("in battle"))
	assert_true(action.disabled, "nothing selected")
	var expect := [["Request to join", false], ["Cancel request", false], ["Open party", false], ["Return to battle", false],
		["Request to join", true]]
	for i in 5:
		list.select(i)
		list.item_selected.emit(i)
		assert_eq([action.text, action.disabled], expect[i], "row %d" % i)
		if not action.disabled:
			action.pressed.emit()
	assert_eq(got, [["join", "a"], ["cancel", "b"], ["open", "c"], ["open", "d"]])
	list.select(4)
	action.pressed.emit()
	assert_eq(got.size(), 4, "a full party cannot be asked")
	list.select(1)
	s.show_parties([_party("a", "none"), _party("b", "pending")])
	assert_eq(list.get_selected_items(), PackedInt32Array([1]), "the selected party stays selected across a refresh")
	_press(s, "CreatePartyButton")
	assert_eq(got.back(), ["create"])
	s.free()


func test_parties_screen_refreshes_on_a_timer_only_while_visible() -> void:
	var s := _screen("res://game/client/screens/parties_screen.tscn") as PartiesScreen
	var asked: Array[bool] = []
	s.refresh_requested.connect(func() -> void: asked.append(true))
	s.show_loading()
	var timer := s.get_node("%PartiesTimer") as Timer
	assert_true(not timer.is_stopped())
	timer.timeout.emit()
	assert_eq(asked.size(), 1)
	s.hide()
	assert_true(timer.is_stopped(), "a hidden screen stops polling")
	s.free()


func test_create_party_screen_offers_only_runnable_activities() -> void:
	var s := _screen("res://game/client/screens/create_party_screen.tscn") as CreatePartyScreen
	var made: Array[String] = []
	var messages: Array[String] = []
	s.create_requested.connect(func(id: String) -> void: made.append(id))
	s.message.connect(func(t: String) -> void: messages.append(t))
	s.show_activities([
		{"id": "training_skirmish", "name": "Training skirmish", "kind": "minor", "available": true, "max_players": 4},
		{"id": "ashen_keep_siege", "name": "Break the siege", "kind": "major", "available": false, "max_players": 4},
		{"id": "wolf_hunt", "name": "Thin the wolf pack", "kind": "major", "available": true, "max_players": 6}])
	var list := s.get_node("%ActivityList") as ItemList
	assert_eq(list.item_count, 2, "a completed one-time activity is hidden")
	assert_eq(list.get_item_text(0), "Training skirmish - up to 4 players")
	assert_eq(list.get_item_text(1), "Thin the wolf pack [major] - up to 6 players")
	_press(s, "StartPartyButton")
	assert_eq(messages, ["Select an activity first"] as Array[String])
	list.select(1)
	_press(s, "StartPartyButton")
	assert_eq(made, ["wolf_hunt"] as Array[String])
	s.free()


func test_party_lobby_shows_the_roster_and_only_the_leader_gets_controls() -> void:
	var s := _screen("res://game/client/screens/party_lobby_screen.tscn") as PartyLobbyScreen
	var got: Array = []
	s.start_pressed.connect(func() -> void: got.append("start"))
	s.leave_pressed.connect(func() -> void: got.append("leave"))
	s.back_pressed.connect(func() -> void: got.append("back"))
	s.decision_made.connect(func(id: String, ok: bool, _row: JoinRequestRow) -> void: got.append([id, ok]))
	var start := s.get_node("%StartButton") as Button
	s.show_party(_party("a", "member"))
	assert_eq((s.get_node("%PartyTitleLabel") as Label).text, "Training skirmish (2/4)")
	var roster := s.get_node("%RosterList") as ItemList
	assert_eq(roster.get_item_text(0), "Hero0 - warrior (leader)")
	assert_eq(roster.get_item_text(1), "Hero1 - warrior")
	assert_true(not start.visible and not (s.get_node("%RequestsBox") as Control).visible, "members cannot start or decide")
	assert_eq((s.get_node("%PartyHintLabel") as Label).text, "Waiting for Hero0 to start the battle.")
	s.show_party(_party("a", "leader"))
	assert_true(start.visible and (s.get_node("%RequestsBox") as Control).visible)
	s.show_requests([{"id": "q1", "name": "Mira", "class": "rogue"}, {"id": "q2", "name": "Orrin", "class": "cleric"}])
	var rows := s.get_node("%PartyRequestRows") as VBoxContainer
	assert_eq(rows.get_child_count(), 2)
	assert_eq(((rows.get_child(0) as JoinRequestRow).get_node("%NameLabel") as Label).text, "Mira (rogue)")
	((rows.get_child(0) as JoinRequestRow).get_node("%ApproveButton") as Button).pressed.emit()
	((rows.get_child(1) as JoinRequestRow).get_node("%RejectButton") as Button).pressed.emit()
	_press(s, "StartButton")
	_press(s, "PartyLeaveButton")
	_press(s, "PartyBackButton")
	assert_eq(got, [["q1", true], ["q2", false], "start", "leave", "back"])
	s.set_start_busy(true)
	assert_true(start.disabled)
	s.show_party(_party("a", "member")) # leadership handed over to someone else: the controls go away
	assert_true(not start.visible)
	s.free()


func test_party_lobby_leader_can_hand_over_and_the_pick_survives_a_refresh() -> void:
	var s := _screen("res://game/client/screens/party_lobby_screen.tscn") as PartyLobbyScreen
	var got: Array[String] = []
	s.make_leader_requested.connect(func(id: String) -> void: got.append(id))
	var btn := s.get_node("%MakeLeaderButton") as Button
	var roster := s.get_node("%RosterList") as ItemList
	s.show_party(_party("a", "member"))
	assert_true(not btn.visible, "members cannot hand over")
	s.show_party(_party("a", "leader"))
	assert_true(btn.visible and btn.disabled, "nothing picked yet")
	roster.select(1)
	roster.item_selected.emit(1)
	assert_true(not btn.disabled)
	s.show_party(_party("a", "leader")) # the 3-second refresh rebuilds the list
	assert_eq(roster.get_selected_items(), PackedInt32Array([1]))
	btn.pressed.emit()
	assert_eq(got, ["c1"] as Array[String])
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


func test_event_log_groups_by_beat_and_recaps_the_round() -> void:
	var c := _client()
	var log_view := c.get_node("%LogView") as RichTextLabel
	c.call("_on_events", [
		{"type": "hit", "round": 1, "beat": 1, "text": "A hits B"},
		{"type": "miss", "round": 1, "beat": 1, "text": "B misses A"},
		{"type": "hit", "round": 1, "beat": 2, "text": "A hits B"},
		{"type": "round_start", "round": 2, "beat": 0, "text": "Round 2"}])
	var t := log_view.get_parsed_text()
	assert_eq(t.count("Round 1 · Beat 1"), 1, "one header per beat")
	assert_true("Round 1 · Beat 2" in t, "second beat header")
	assert_true("Last round: 2 hit, 1 miss" in t, "recap line")
	c.free()
