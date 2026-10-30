class_name AudioDirector
extends Node
## Plays the game's sounds. It is a scene (audio_director.tscn, instanced once in the client): its Inspector holds the sound bank and the
## pool size and fade length. Everything else asks it through the static helpers, so any script can say `AudioDirector.cue("chat")`
## without holding a reference; with no director in the scene (tests, the headless bot) they do nothing.
##   - Cues (sound_bank.tres) are looked up by name; a cue with no sound file is silent.
##   - Every button in the game makes the "ui_click" cue when pressed and "ui_hover" when the mouse moves over it (no wiring needed).
##   - Battle events map to cues; a skill's own Cast Sound / Hit Sound wins over the generic cue.
##   - Music crossfades when the screen changes.

static var instance: AudioDirector = null

@export var bank: SoundBank
## How many sounds can play at once; a new one beyond this cuts the oldest.
@export_range(1, 64) var voices: int = 16
## Seconds to fade one music track out while the next fades in.
@export_range(0.0, 10.0, 0.1) var crossfade_seconds: float = 1.0

var music_id: String = ""
var _voices: Array[AudioStreamPlayer] = []
var _next_voice: int = 0
var _last_played: Dictionary = {} # cue id or stream path -> ticks (ms)
var _music: Array[AudioStreamPlayer] = []
var _music_now: int = 0

const EVENT_CUES := {
	"miss": "miss", "windup": "cast", "move": "move", "downed": "downed", "eliminated": "eliminated", "revived": "revived",
	"status_apply": "status_apply", "status_end": "status_end", "interrupt": "interrupt", "round_start": "round_start",
	"resolution_start": "resolution_start", "escape": "escape", "trigger": "alert", "wake": "alert", "appear": "alert",
	"grant_item": "pickup", "context": "object", "object_state": "object",
}


func _ready() -> void:
	instance = self
	for i in voices:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_voices.append(p)
	for i in 2:
		var p := AudioStreamPlayer.new()
		p.bus = &"Music"
		add_child(p)
		_music.append(p)
	AudioSettings.apply_all()
	get_tree().node_added.connect(_hook)
	_hook_tree(get_tree().root)


func _exit_tree() -> void:
	if instance == self:
		instance = null


# ---- static helpers: safe to call from anywhere ----

static func cue(id: String) -> void:
	if instance != null:
		instance.play(id)


static func music(id: String) -> void:
	if instance != null:
		instance.play_music(id)


## A battle event from the server (`skills` lets a skill's own sounds be found).
static func event(e: Dictionary, skills: SkillDb) -> void:
	if instance != null:
		instance.play_event(e, skills)


# ---- playing ----

func play(id: String) -> void:
	var c := bank.get_cue(id) if bank != null else null
	if c != null:
		_play_cue(c, c.pick(), id)


func play_event(e: Dictionary, skills: SkillDb) -> void:
	var type: String = e.get("type", "")
	var data: Dictionary = e.get("data", {})
	var sk: SkillDef = skills.get_skill(str(data.get("skill", ""))) if skills != null and data.get("skill", "") != "" else null
	match type:
		"hit":
			if sk != null and sk.hit_sound != null:
				_play_stream(sk.hit_sound, &"Effects", "skill:" + sk.id)
			else:
				play("crit" if data.get("crit", false) else "hit")
		"heal", "shield":
			if sk != null and sk.hit_sound != null:
				_play_stream(sk.hit_sound, &"Effects", "skill:" + sk.id)
			else:
				play(type)
		"windup":
			if sk != null and sk.cast_sound != null:
				_play_stream(sk.cast_sound, &"Effects", "cast:" + sk.id)
			else:
				play("cast")
		_:
			if EVENT_CUES.has(type):
				play(EVENT_CUES[type])


func _play_cue(c: SoundCue, stream: AudioStream, key: String) -> void:
	if stream == null:
		return
	_voice_play(stream, c.bus, c.volume_db, c.pitch_jitter, key, c.min_gap_ms)


func _play_stream(stream: AudioStream, bus: StringName, key: String) -> void:
	_voice_play(stream, bus, 0.0, 0.0, key, 60)


func _voice_play(stream: AudioStream, bus: StringName, volume_db: float, jitter: float, key: String, gap_ms: int) -> void:
	var now := Time.get_ticks_msec()
	if gap_ms > 0 and now - int(_last_played.get(key, -100000)) < gap_ms:
		return
	_last_played[key] = now
	var v := _free_voice()
	v.stream = stream
	v.bus = bus
	v.volume_db = volume_db
	v.pitch_scale = 1.0 + randf_range(-jitter, jitter)
	v.play()


func _free_voice() -> AudioStreamPlayer:
	for v in _voices:
		if not v.playing:
			return v
	var v := _voices[_next_voice % _voices.size()] # all busy: cut the oldest
	_next_voice += 1
	return v


## Fades to the track of the music cue `id` (nothing changes if it is already the one playing; a cue with no file fades the music out).
func play_music(id: String) -> void:
	if id == music_id:
		return
	music_id = id
	var c := bank.get_cue(id) if bank != null else null
	var stream := c.pick() if c != null else null
	var old := _music[_music_now]
	_music_now = 1 - _music_now
	var fresh := _music[_music_now]
	_fade(old, -60.0, true)
	if stream == null:
		return
	fresh.stream = stream
	fresh.volume_db = -60.0 if crossfade_seconds > 0.0 else c.volume_db
	fresh.play()
	if crossfade_seconds > 0.0:
		_fade(fresh, c.volume_db, false)


func _fade(p: AudioStreamPlayer, to_db: float, stop_after: bool) -> void:
	if crossfade_seconds <= 0.0:
		if stop_after:
			p.stop()
		return
	var tw := create_tween()
	tw.tween_property(p, "volume_db", to_db, crossfade_seconds)
	if stop_after:
		tw.tween_callback(p.stop)


# ---- every button clicks and hovers ----

func _hook_tree(n: Node) -> void:
	_hook(n)
	for ch in n.get_children():
		_hook_tree(ch)


func _hook(n: Node) -> void:
	var b := n as BaseButton
	if b == null or b.has_meta("sfx_hooked") or b.has_meta("silent"):
		return
	b.set_meta("sfx_hooked", true)
	b.pressed.connect(func() -> void: play("ui_click"))
	b.mouse_entered.connect(func() -> void:
		if not b.disabled:
			play("ui_hover"))
