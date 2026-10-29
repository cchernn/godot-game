class_name StoryActor
extends Resource
## Someone who speaks in a story (game/content/stories/actors/*.tres). Slides point at an actor; the story screen shows the
## portrait and name. Until you paint a portrait, the screen shows a coloured silhouette in the actor's colour.

## Lower-case id with no spaces, e.g. "old_warden".
@export var id: String = ""
@export var display_name: String = ""
## Standing portrait. Optional: without it the screen draws a placeholder silhouette.
@export var portrait: Texture2D
## The placeholder silhouette's colour and the name plate's accent.
@export var color: Color = Color(0.7, 0.7, 0.8)


func problems() -> Array[String]:
	var out: Array[String] = []
	if id == "" or id != id.to_lower() or " " in id:
		out.append("story actor id must be lower-case with no spaces (got '%s')" % id)
	if display_name == "":
		out.append("%s: display_name is empty" % id)
	return out
