extends TestCase
## Events: where each outcome leads, and what a character carries from one battle into the next.


func _steps() -> Array:
	return [
		{"id": "warning", "type": "story", "story": "w", "choices": [{"id": "fight", "next": "ghouls"}, {"id": "bargain", "next": "dawn"}]},
		{"id": "ghouls", "type": "battle", "encounter": "e", "on_lose": "dawn"},
		{"id": "boss", "type": "battle", "encounter": "e"},
		{"id": "dawn", "type": "story", "story": "d"},
	]


func test_a_story_with_choices_routes_on_the_choice_and_a_plain_one_goes_on() -> void:
	var run := EventRun.new(_steps())
	assert_eq(run.current, "warning")
	run.finish_story("bargain")
	assert_eq(run.current, "dawn")
	var other := EventRun.new(_steps())
	other.finish_story("fight")
	assert_eq(other.current, "ghouls")
	var unknown := EventRun.new(_steps())
	unknown.finish_story("")
	assert_eq(unknown.current, "ghouls", "no choice made takes the first option")


func test_a_battle_leads_on_with_on_win_or_on_lose() -> void:
	var run := EventRun.new(_steps())
	run.finish_story("fight")
	run.finish_battle(true)
	assert_eq(run.current, "boss", "a win goes to the next step in the list")
	run.finish_battle(true)
	assert_eq(run.current, "dawn")
	run.finish_story("")
	assert_eq(run.ending, EventRun.END)
	assert_true(not run.running())
	var lost := EventRun.new(_steps())
	lost.finish_story("fight")
	lost.finish_battle(false)
	assert_eq(lost.current, "dawn", "on_lose names where a loss goes")
	var boss := EventRun.new(_steps())
	boss.finish_story("fight")
	boss.finish_battle(true)
	boss.finish_battle(false)
	assert_eq(boss.ending, EventRun.FAIL, "a loss with no on_lose fails the event")


func test_hit_points_and_items_carry_over_and_a_restart_forgets_them() -> void:
	var run := EventRun.new(_steps())
	run.remember("c1", 7, {"potion": 1})
	assert_eq(run.carried("c1")["hp"], 7)
	assert_eq((run.carried("c1")["items"] as Dictionary)["potion"], 1)
	assert_true(run.carried("nobody").is_empty())
	run.forfeit("c2")
	run.finish_story("fight")
	run.finish_battle(true)
	run.finish_battle(false)
	run.restart()
	assert_eq(run.current, "warning")
	assert_eq(run.restarts, 1)
	assert_true(run.running())
	assert_true(run.carried("c1").is_empty(), "a restart starts everyone fresh")
	assert_eq(run.visited.size(), 1)
	assert_true(run.forfeited.is_empty())


func test_only_who_stayed_reaches_the_end() -> void:
	var run := EventRun.new(_steps())
	run.forfeit("c2")
	run.finish_story("bargain")
	run.finish_story("")
	assert_true(run.reached_end("c1"))
	assert_true(not run.reached_end("c2"), "an escaped character is not paid the event")
	var running := EventRun.new(_steps())
	assert_true(not running.reached_end("c1"))


func test_a_character_who_was_downed_stands_up_at_the_revive_fraction() -> void:
	assert_eq(EventRun.hp_after(0, 40, 25), 10)
	assert_eq(EventRun.hp_after(3, 40, 25), 10, "never below the revive fraction")
	assert_eq(EventRun.hp_after(33, 40, 25), 33, "a healthy character keeps their hit points")
	assert_eq(EventRun.hp_after(99, 40, 25), 40, "and never goes above the maximum")
	assert_eq(EventRun.hp_after(0, 1, 0), 1, "at least 1")


## An event routes on the id of the choice the party made in a story, so each step choice must exist in its story and the other way round.
func test_event_story_choices_match_the_stories_they_route_on() -> void:
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://services/api/templates/prototype@1.json"))
	for a: Dictionary in (raw as Dictionary)["activities"]:
		if a["type"] != "event":
			continue
		for step: Dictionary in a["steps"]:
			if step["type"] != "story":
				continue
			var story := StoryDef.load_story(str(step["story"]))
			assert_true(story != null, "%s: story %s exists" % [a["id"], step["story"]])
			if story == null:
				continue
			var in_story: Array[String] = []
			for slide in story.slides:
				for c in slide.choices:
					in_story.append(c.id)
			in_story.sort()
			var in_step: Array[String] = []
			for c: Dictionary in step.get("choices", []):
				in_step.append(str(c["id"]))
			in_step.sort()
			assert_eq(in_story, in_step, "%s step %s: choices agree with the story" % [a["id"], step["id"]])
