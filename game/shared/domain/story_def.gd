class_name StoryDef
extends Resource
## A conversation scene shown like a visual novel (game/content/stories/*.tres). A list of slides played in order, with optional
## choices and jumps. The file name is the id the world template's "story" uses.

@export var title: String = ""
@export var slides: Array[StorySlide] = []


## The slide index a jump target names: a slide id, "" for the one after `from`, or -1 for "end".
func target_index(from: int, target: String) -> int:
	if target == "end":
		return -1
	if target == "":
		return from + 1 if from + 1 < slides.size() else -1
	for i in slides.size():
		if slides[i].id == target:
			return i
	return -2 # unknown


## What is on stage after the slides in `path` (slide indices, oldest first) were shown:
## {picture: Texture2D or null, color: Color (alpha 0 = nothing), left: StoryActor or null, right: StoryActor or null}.
func stage_after(path: Array) -> Dictionary:
	var stage := {"picture": null, "color": Color(0, 0, 0, 0), "left": null, "right": null}
	for i: int in path:
		var s := slides[i]
		if s.clear_stage:
			stage["left"] = null
			stage["right"] = null
		if s.background != null:
			stage["picture"] = s.background
			stage["color"] = Color(0, 0, 0, 0)
		elif s.backdrop_color.a > 0.0:
			stage["picture"] = null
			stage["color"] = s.backdrop_color
		if s.actor != null:
			stage["left" if s.side == StorySlide.Stand.LEFT else "right"] = s.actor
	return stage


func problems() -> Array[String]:
	var out: Array[String] = []
	if slides.is_empty():
		out.append("story has no slides")
	var seen := {}
	for i in slides.size():
		var s := slides[i]
		var where := "slide %d" % (i + 1)
		if s == null:
			out.append("%s is empty" % where)
			continue
		if s.id != "":
			if seen.has(s.id) or s.id == "end":
				out.append("%s: id '%s' is used twice or reserved" % [where, s.id])
			seen[s.id] = true
		if s.text.strip_edges() == "":
			out.append("%s has no text" % where)
		if s.actor != null:
			out.append_array(s.actor.problems())
		if not s.choices.is_empty():
			if s.choices.size() < 2:
				out.append("%s: a choice needs two or more options" % where)
			var ids := {}
			for c in s.choices:
				if c == null or c.id == "" or c.id != c.id.to_lower() or " " in c.id or ids.has(c.id) or c.text == "":
					out.append("%s has a bad choice" % where)
					continue
				ids[c.id] = true
				if target_index(i, c.next) == -2:
					out.append("%s: choice %s jumps to unknown slide '%s'" % [where, c.id, c.next])
		elif target_index(i, s.next) == -2:
			out.append("%s jumps to unknown slide '%s'" % [where, s.next])
	# every jump must go forward, so a story always ends
	for i in slides.size():
		var s := slides[i]
		if s == null:
			continue
		var targets: Array[String] = []
		if s.choices.is_empty():
			targets.append(s.next)
		for c in s.choices:
			if c != null:
				targets.append(c.next)
		for t in targets:
			var j := target_index(i, t)
			if j >= 0 and j <= i:
				out.append("slide %d jumps back to slide %d (stories only move forward)" % [i + 1, j + 1])
	return out


## Loads a story by id (a file in game/content/stories), or null if the id is malformed or has no such file.
static func load_story(story_id: String) -> StoryDef:
	var plain := story_id != ""
	for ch in story_id:
		if not (ch in "abcdefghijklmnopqrstuvwxyz0123456789_"):
			plain = false
	var path := "res://game/content/stories/%s.tres" % story_id
	if not plain or not ResourceLoader.exists(path):
		return null
	return load(path) as StoryDef
