extends TestCase
## Chat: how a message is cleaned and rate limited, the chat box, and the bubble over a unit.


func test_a_message_becomes_one_plain_line_cut_to_the_limit() -> void:
	assert_eq(ChatRules.clean("  hello \n\t world  ", 50), "hello world")
	assert_eq(ChatRules.clean("a" + char(1) + "b" + char(7) + "c", 50), "a b c", "control characters become spaces")
	assert_eq(ChatRules.clean("   \n ", 50), "", "nothing left means the message is dropped")
	assert_eq(ChatRules.clean("abcdefghij", 4), "abcd")
	assert_eq(ChatRules.clean("abc defgh", 4), "abc", "no dangling space after a cut")


func test_the_limits_are_in_the_balance_file_and_the_api_copy() -> void:
	var cfg := GameConfig.load_file()
	assert_true(int(cfg.get_value("chat", "max_length")) > 0)
	assert_eq(ContentCatalog.build(cfg)["chat"]["max_length"], int(cfg.get_value("chat", "max_length")))


func test_a_player_is_limited_to_a_few_messages_per_window() -> void:
	var l := ChatLimiter.new(3, 10_000)
	assert_true(l.allow(0) and l.allow(1_000) and l.allow(2_000), "three fit")
	assert_true(not l.allow(3_000), "the fourth is refused")
	assert_true(not l.allow(9_999), "still inside the window of the first")
	assert_true(l.allow(10_000), "the first has aged out")
	assert_true(not l.allow(10_500), "a refused message does not count, but the new one does")


func _panel() -> ChatPanel:
	var root := (Engine.get_main_loop() as SceneTree).root
	var p := (load("res://game/client/screens/chat_panel.tscn") as PackedScene).instantiate() as ChatPanel
	root.add_child(p)
	return p


func test_the_chat_box_sends_trimmed_lines_and_never_empty_ones() -> void:
	var p := _panel()
	var sent: Array[String] = []
	p.submitted.connect(func(t: String) -> void: sent.append(t))
	p._on_text_submitted("  hello there  ")
	p._on_text_submitted("   ")
	assert_eq(sent, ["hello there"] as Array[String])
	p.queue_free()


func test_the_chat_box_shows_lines_as_text_and_keeps_only_the_latest() -> void:
	var p := _panel()
	p.max_lines = 3
	p.add_line("Aldric", "[b]not bold[/b] [color=red]x[/color]")
	assert_true("[b]not bold[/b]" in p._log.get_parsed_text(), "brackets from a player are shown, not read as formatting")
	assert_true(p._log.get_parsed_text().begins_with("Aldric:"))
	for i in 5:
		p.add_line("Brenna", "line %d" % i, true)
	p.add_line("", "You are sending messages too fast", false, true)
	var shown := p._log.get_parsed_text()
	assert_true("line 4" in shown and "too fast" in shown, "the newest are kept")
	assert_true(not ("line 0" in shown), "the oldest are dropped")
	p.clear()
	assert_eq(p._log.get_parsed_text(), "")
	p.queue_free()


func test_the_chat_box_can_be_folded_away() -> void:
	var p := _panel()
	assert_true(p._body.visible)
	p.set_folded(true)
	assert_true(not p._body.visible)
	assert_true(p._fold.text.begins_with("▸"))
	p.set_folded(false)
	assert_true(p._body.visible)
	p.queue_free()


func _bubble() -> ChatBubble:
	var root := (Engine.get_main_loop() as SceneTree).root
	var b := (load("res://game/content/board/markers/chat_bubble.tscn") as PackedScene).instantiate() as ChatBubble
	root.add_child(b)
	return b


func test_a_bubble_shows_its_line_stays_up_a_while_and_then_goes() -> void:
	var b := _bubble()
	b.seconds_base = 1.0
	b.seconds_per_char = 0.0
	b.fade_seconds = 0.5
	b.play("Hello")
	assert_eq(b.text(), "Hello")
	assert_true(not b.visible, "hidden until the box has been sized")
	b._wait_for_layout = false # the size comes from the label, which only measures itself a frame later
	b._process(1.0)
	assert_true(not b.is_queued_for_deletion(), "fading, not gone")
	b._process(0.6)
	assert_true(b.is_queued_for_deletion(), "gone after its time")
	b.queue_free()


func test_a_longer_line_stays_up_longer() -> void:
	var a := _bubble()
	var b := _bubble()
	a.play("Hi")
	b.play("A much longer line that takes more time to read than a greeting")
	assert_true(b._lifetime > a._lifetime)
	a.queue_free()
	b.queue_free()


func test_a_unit_has_one_bubble_at_a_time() -> void:
	var root := (Engine.get_main_loop() as SceneTree).root
	var u := (load("res://game/content/units/unit.tscn") as PackedScene).instantiate() as Unit3D
	root.add_child(u)
	var scene := load("res://game/content/board/markers/chat_bubble.tscn") as PackedScene
	u.say(scene, "one")
	var first := u._bubble
	u.say(scene, "two")
	assert_true(first.is_queued_for_deletion(), "the old bubble is replaced")
	assert_eq(u._bubble.text(), "two")
	assert_true(is_equal_approx(u._bubble.position.y, u.bubble_height))
	u.queue_free()


func test_the_board_only_shows_bubbles_for_units_it_has() -> void:
	var board := (load("res://game/content/board/board_3d.tscn") as PackedScene).instantiate() as Board3D
	(Engine.get_main_loop() as SceneTree).root.add_child(board)
	board.say("nobody", "hello") # not on the board: nothing happens, and nothing breaks
	assert_true(board.chat_bubble_scene != null, "the board scene has a bubble scene set")
	board.queue_free()
