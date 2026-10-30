class_name SoundBank
extends Resource
## Every sound the game can make, by name (game/content/audio/sound_bank.tres). The bank ships with every cue listed and no sound files in them:
## open it, pick a cue and drop a file into its Streams. A cue with no stream is silent, so you can fill it in at your own pace.

## The cues the game plays, with when each plays. Music cues play on the Music bus, the rest on Effects or UI.
const CUES := {
	"ui_click": "Any button is pressed",
	"ui_hover": "The mouse moves over a button",
	"chat": "A chat line from someone else arrives",
	"hit": "A hit lands (a skill's own Hit Sound replaces this)",
	"crit": "A critical hit lands",
	"miss": "An attack misses or finds no one",
	"heal": "Someone is healed",
	"shield": "Someone is shielded",
	"cast": "A skill begins with a wind-up, such as drawing a bow",
	"move": "A unit steps (plays every beat for every walker: leave empty or keep it very quiet)",
	"downed": "A unit is downed",
	"eliminated": "A unit is defeated",
	"revived": "A unit is revived",
	"status_apply": "A status lands on a unit",
	"status_end": "A status wears off",
	"interrupt": "A skill is interrupted",
	"round_start": "A new round begins and planning starts",
	"resolution_start": "All plans are in and the beats begin",
	"escape": "A character flees the fight",
	"alert": "Something stirs: a dormant enemy wakes, a new one arrives, a trigger fires",
	"pickup": "An item is picked up in a battle",
	"object": "A map object is used or changes state",
	"music_menu": "Music for the menus and the overworld",
	"music_story": "Music while a story or the lobby is on screen",
	"music_battle": "Music during a battle",
	"music_victory": "Plays once on the result screen after a win",
	"music_defeat": "Plays once on the result screen after a defeat or a draw",
}

@export var cues: Array[SoundCue] = []


func get_cue(id: String) -> SoundCue:
	for c in cues:
		if c != null and c.id == id:
			return c
	return null


func problems() -> Array[String]:
	var out: Array[String] = []
	var seen := {}
	for c in cues:
		if c == null:
			out.append("an empty entry in the list")
			continue
		if seen.has(c.id):
			out.append("cue '%s' is listed twice" % c.id)
		seen[c.id] = true
		if not CUES.has(c.id):
			out.append("cue '%s' is not one the game plays" % c.id)
		if c.id.begins_with("music_") != (c.bus == &"Music"):
			out.append("cue '%s': music cues belong on the Music bus and only they" % c.id)
	for id: String in CUES:
		if not seen.has(id):
			out.append("cue '%s' is missing from the bank" % id)
	return out
