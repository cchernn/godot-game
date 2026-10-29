class_name EventRun
extends RefCounted
## One party's walk through an event: the step they are on, where each outcome leads, and what carries from one battle to the next
## (hit points and items). Pure state like StoryRun; the server owns one per room and runs the current step (a battle or a story).
## Steps are the template's own dictionaries (id, type, encounter or story, on_win / on_lose / next / choices).

const END := "end"
const FAIL := "fail"

var steps: Array = []
var current: String = ""
## "" while the event is running; END or FAIL once a path has finished.
var ending: String = ""
var visited: Array[String] = []
## Character id -> {hp, items}: how a character leaves a battle and enters the next one.
var carry: Dictionary = {}
## Characters who escaped from a battle: they play on but are not paid the event's rewards.
var forfeited: Dictionary = {}
## How many times the event restarted after a failure.
var restarts: int = 0


func _init(p_steps: Array) -> void:
	steps = p_steps
	_begin()


func _begin() -> void:
	current = str(steps[0]["id"])
	ending = ""
	visited = [current]
	carry = {}
	forfeited = {}


## Starts over from the first step (the party failed and the event restarts).
func restart() -> void:
	restarts += 1
	_begin()


func running() -> bool:
	return ending == ""


func step() -> Dictionary:
	for s: Dictionary in steps:
		if s["id"] == current:
			return s
	return {}


func _after() -> String:
	for i in steps.size():
		if steps[i]["id"] == current:
			return str(steps[i + 1]["id"]) if i + 1 < steps.size() else END
	return END


## A battle step ended: on_win after a win, on_lose (default: the event fails) otherwise.
func finish_battle(won: bool) -> void:
	var s := step()
	_go(str(s.get("on_win", _after())) if won else str(s.get("on_lose", FAIL)))


## A story step ended; `choice_id` is the last choice the party made ("" if none). A step with choices routes on it.
func finish_story(choice_id: String) -> void:
	var s := step()
	var choices: Array = s.get("choices", [])
	if choices.is_empty():
		_go(str(s.get("next", _after())))
		return
	var target := str((choices[0] as Dictionary)["next"])
	for c: Dictionary in choices:
		if c["id"] == choice_id:
			target = str(c["next"])
	_go(target)


func _go(target: String) -> void:
	if target == END or target == FAIL:
		ending = target
	else:
		current = target
		visited.append(target)


func remember(character_id: String, hp: int, items: Dictionary) -> void:
	carry[character_id] = {"hp": hp, "items": items.duplicate()}


## How a character enters the next battle ({} when they have not fought yet).
func carried(character_id: String) -> Dictionary:
	return carry.get(character_id, {})


func forfeit(character_id: String) -> void:
	forfeited[character_id] = true


func reached_end(character_id: String) -> bool:
	return ending == END and not forfeited.has(character_id)


## The hit points a character starts the next battle with: what they had, but at least `revive_percent` of their maximum
## (a character who was downed or eliminated is back on their feet), and never above the maximum.
static func hp_after(hp: int, max_hp: int, revive_percent: int) -> int:
	return clampi(maxi(hp, ceili(max_hp * revive_percent / 100.0)), 1, max_hp)
