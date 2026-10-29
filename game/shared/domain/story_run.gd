class_name StoryRun
extends RefCounted
## One party playing one story. Everyone present must press Continue on a slide before it moves on; the leader picks choices.
## Pure state: the server owns one per room and sends each player the view. Players who are offline never block a slide.

var def: StoryDef
var seats: Array[String] = []
## The seat that picks choices (the party leader).
var chooser: String = ""
## Slide indices shown so far, oldest first (the client replays them to rebuild the stage after a reconnect).
var path: Array[int] = []
var finished: bool = false
## The id of the last choice made ("" if none): what an event routes on.
var outcome: String = ""

var _present: Dictionary = {}
var _continued: Dictionary = {}


func _init(p_def: StoryDef, p_seats: Array[String], p_chooser: String) -> void:
	def = p_def
	seats = p_seats
	chooser = p_chooser
	for s in seats:
		_present[s] = true
	path = [0]


func current_index() -> int:
	return path[path.size() - 1]


func current() -> StorySlide:
	return def.slides[current_index()]


## Who is connected right now. A change can complete the slide (the last one holding it up left).
func set_present(seat: String, present: bool) -> bool:
	_present[seat] = present
	return _maybe_advance()


func press_continue(seat: String) -> bool:
	if finished or not seats.has(seat) or not current().choices.is_empty():
		return false
	_continued[seat] = true
	return _maybe_advance()


func choose(seat: String, choice_id: String) -> bool:
	if finished or seat != chooser:
		return false
	for c in current().choices:
		if c.id == choice_id:
			outcome = choice_id
			_go(def.target_index(current_index(), c.next))
			return true
	return false


## Seats that are connected and have not pressed Continue on this slide.
func waiting() -> Array[String]:
	var out: Array[String] = []
	if finished or not current().choices.is_empty():
		return out
	for s in seats:
		if _present.get(s, false) and not _continued.has(s):
			out.append(s)
	return out


func has_continued(seat: String) -> bool:
	return _continued.has(seat)


func _maybe_advance() -> bool:
	if finished or not current().choices.is_empty():
		return false
	var anyone := false
	for s in seats:
		if _present.get(s, false):
			anyone = true
			if not _continued.has(s):
				return false
	if not anyone:
		return false
	_go(def.target_index(current_index(), current().next))
	return true


func _go(index: int) -> void:
	_continued.clear()
	if index < 0:
		finished = true
	else:
		path.append(index)
