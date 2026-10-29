extends TestCase
## Stories: the data checks and the party's progress through one (everyone continues, the leader chooses).


func _actor(id: String) -> StoryActor:
	var a := StoryActor.new()
	a.id = id
	a.display_name = id.capitalize()
	return a


func _slide(text: String, id: String = "", next: String = "") -> StorySlide:
	var s := StorySlide.new()
	s.text = text
	s.id = id
	s.next = next
	s.actor = _actor("warden")
	return s


func _choice(id: String, next: String = "") -> StoryChoice:
	var c := StoryChoice.new()
	c.id = id
	c.text = id.capitalize()
	c.next = next
	return c


func _story(slides: Array[StorySlide]) -> StoryDef:
	var d := StoryDef.new()
	d.slides = slides
	return d


func _seats(ids: Array[String]) -> Array[String]:
	return ids


func test_a_sound_story_has_no_problems_and_each_kind_of_mistake_is_reported() -> void:
	var branching := _story([_slide("Hello"), _slide("A fork"), _slide("Left", "left", "end"), _slide("Right", "right")])
	branching.slides[1].choices = [_choice("left", "left"), _choice("right", "right")]
	assert_eq(branching.problems(), [] as Array[String], "branching story is fine")
	assert_true(not _story([]).problems().is_empty(), "no slides")
	assert_true(not _story([_slide("")]).problems().is_empty(), "no text")
	assert_true(not _story([_slide("a", "x"), _slide("b", "x")]).problems().is_empty(), "duplicate slide id")
	assert_true(not _story([_slide("a", "", "nowhere"), _slide("b")]).problems().is_empty(), "unknown jump")
	assert_true(not _story([_slide("a", "start"), _slide("b", "", "start")]).problems().is_empty(), "jumping back could loop forever")
	var one := _story([_slide("a"), _slide("b")])
	one.slides[0].choices = [_choice("only")]
	assert_true(not one.problems().is_empty(), "one choice is no choice")
	var dup := _story([_slide("a"), _slide("b")])
	dup.slides[0].choices = [_choice("x"), _choice("x")]
	assert_true(not dup.problems().is_empty(), "duplicate choice ids")


func test_everyone_present_must_continue_before_the_story_moves_on() -> void:
	var run := StoryRun.new(_story([_slide("one"), _slide("two")]), _seats(["a", "b"]), "a")
	assert_eq(run.current_index(), 0)
	assert_true(not run.press_continue("a"), "one of two is not enough")
	assert_eq(run.waiting(), ["b"] as Array[String])
	assert_true(run.press_continue("a") == false and run.current_index() == 0, "pressing twice does not count twice")
	assert_true(run.press_continue("b"), "the last one moves it on")
	assert_eq(run.current_index(), 1)
	assert_eq(run.waiting(), ["a", "b"] as Array[String], "a new slide waits for everyone again")
	run.press_continue("a")
	run.press_continue("b")
	assert_true(run.finished, "the story ends after its last slide")
	assert_eq(run.path, [0, 1] as Array[int])


func test_a_player_who_leaves_never_holds_the_story_up() -> void:
	var run := StoryRun.new(_story([_slide("one"), _slide("two")]), _seats(["a", "b"]), "a")
	run.press_continue("a")
	assert_true(run.set_present("b", false), "the only one still holding it up left")
	assert_eq(run.current_index(), 1)
	run.set_present("b", true)
	assert_eq(run.waiting(), ["a", "b"] as Array[String], "back again, they are waited for")
	assert_true(not run.set_present("a", false) and not run.set_present("b", false), "an empty room does not skip ahead")
	assert_eq(run.current_index(), 1)


func test_only_the_leader_chooses_and_the_choice_routes_the_story() -> void:
	var story := _story([_slide("Fork"), _slide("Left", "left", "end"), _slide("Right", "right")])
	story.slides[0].choices = [_choice("left", "left"), _choice("right", "right")]
	var run := StoryRun.new(story, _seats(["a", "b"]), "a")
	assert_true(not run.press_continue("a"), "a choice slide is not continued")
	assert_true(not run.choose("b", "left"), "a follower cannot choose")
	assert_true(not run.choose("a", "nope"), "unknown choice")
	assert_true(run.choose("a", "left"))
	assert_eq(run.outcome, "left")
	assert_eq(run.current_index(), 1)
	run.press_continue("a")
	run.press_continue("b")
	assert_true(run.finished and run.path == ([0, 1] as Array[int]), "'end' on the left slide skips the right one")


func test_every_story_in_the_content_folder_is_sound() -> void:
	var dir := DirAccess.open("res://game/content/stories")
	var count := 0
	for f in dir.get_files():
		if not f.ends_with(".tres"):
			continue
		count += 1
		var def := load("res://game/content/stories/" + f) as StoryDef
		assert_true(def != null, "%s is a StoryDef" % f)
		if def != null:
			assert_eq(def.problems(), [] as Array[String], f)
	assert_true(count > 0, "there is at least one story")


func test_the_stage_remembers_portraits_and_backdrops_from_earlier_slides() -> void:
	var def := StoryDef.load_story("elder_rumor")
	assert_true(def != null)
	var stage := def.stage_after([0, 1, 2])
	assert_eq((stage["left"] as StoryActor).id, "village_elder")
	assert_eq((stage["right"] as StoryActor).id, "scout")
	assert_true((stage["color"] as Color).a > 0.0, "the first slide sets the backdrop colour and later ones keep it")
	var run := StoryRun.new(def, ["a"] as Array[String], "a")
	for i in 6:
		run.press_continue("a")
	assert_eq(run.current_index(), 6)
	assert_true(run.choose("a", "yes"))
	assert_eq(def.slides[run.current_index()].id, "go", "'We will go' skips the explanation")
	run.press_continue("a")
	assert_true(run.finished)


func _player() -> StoryPlayer:
	var root := (Engine.get_main_loop() as SceneTree).root
	var p := (load("res://game/client/screens/story_player.tscn") as PackedScene).instantiate() as StoryPlayer
	p.characters_per_second = 0.0 # show lines at once
	root.add_child(p)
	return p


func _state(path: Array, extra: Dictionary = {}) -> Dictionary:
	return {"story": "elder_rumor", "path": path, "waiting": [], "you_continued": false, "can_choose": true, "finished": false}.merged(extra, true)


func test_the_story_screen_shows_the_line_the_speaker_and_the_portraits() -> void:
	var p := _player()
	p.show_state(_state([0]))
	assert_eq(p.speaker_label.visible, false, "narration has no name plate")
	assert_true("Dusk" in p.text_label.text)
	p.show_state(_state([0, 1, 2]))
	assert_eq(p.speaker_label.text, "Scout")
	assert_true(p.left_portrait.visible and p.right_portrait.visible, "both stand on stage")
	assert_eq(p.right_portrait.modulate, Color(1, 1, 1), "the speaker's side is not dimmed")
	p.queue_free()


func test_continue_is_reported_once_and_choices_are_the_leaders() -> void:
	var p := _player()
	var presses := [0]
	p.continue_pressed.connect(func() -> void: presses[0] += 1)
	p.show_state(_state([0, 1]))
	p._advance() # the first press while the line is still typing only shows the whole line
	assert_eq(presses[0], 0)
	p._advance()
	assert_eq(presses[0], 1)
	p.show_state(_state([0, 1], {"you_continued": true, "waiting": ["Bo"]}))
	p._advance()
	assert_eq(presses[0], 1, "pressed already: waiting for the others")
	assert_true("Bo" in p.waiting_label.text)
	var picked := [""]
	p.choice_chosen.connect(func(id: String) -> void: picked[0] = id)
	p.show_state(_state([0, 1, 2, 3, 4, 5, 6]))
	assert_eq(p.choices_box.get_child_count(), 2)
	(p.choices_box.get_child(0) as Button).pressed.emit()
	assert_eq(picked[0], "yes")
	p.show_state(_state([0, 1, 2, 3, 4, 5, 6], {"can_choose": false}))
	assert_true((p.choices_box.get_child(0) as Button).disabled, "followers see the choices but cannot pick")
	p.queue_free()
