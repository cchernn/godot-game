class_name SoundCue
extends Resource
## One named sound of the game (an entry of the sound bank): what to play when something happens. Edited in the Inspector. With several
## streams, one is picked at random each time, which keeps repeated hits from sounding mechanical. No streams = silence.

## The event's name. The ones the game uses are listed in sound_bank.gd (SoundBank.CUES); do not rename them.
@export var id: String = ""
## Drop sound files (.ogg or .wav) here. For music cues, one track (set Loop in its Import dock).
@export var streams: Array[AudioStream] = []
## Louder or quieter than the file itself, in decibels (-6 is about half as loud).
@export_range(-40.0, 12.0, 0.5) var volume_db: float = 0.0
## Each play is pitched up or down by up to this fraction (0.05 = 5 percent), so repeats differ a little.
@export_range(0.0, 0.5, 0.01) var pitch_jitter: float = 0.0
## The same cue is not played again within this many milliseconds (many hits in one beat would stack into noise).
@export_range(0, 1000) var min_gap_ms: int = 60
## The audio bus: "Effects" for game sounds, "UI" for buttons, "Music" for tracks.
@export var bus: StringName = &"Effects"


func pick() -> AudioStream:
	if streams.is_empty():
		return null
	return streams[randi() % streams.size()]
