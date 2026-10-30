extends TestCase
## Sound: the bank and buses, the director's cues, events and music, button clicks, the volume settings, and the skill ids in battle events.


func _beep() -> AudioStreamWAV:
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_8_BITS
	w.mix_rate = 8000
	w.data = PackedByteArray([128, 140, 128, 116])
	return w


func _cue(id: String, stream: AudioStream, bus: StringName = &"Effects", gap_ms: int = 0, jitter: float = 0.0) -> SoundCue:
	var c := SoundCue.new()
	c.id = id
	c.bus = bus
	c.min_gap_ms = gap_ms
	c.pitch_jitter = jitter
	if stream != null:
		c.streams = [stream] as Array[AudioStream]
	return c


func _director(cues: Array[SoundCue]) -> AudioDirector:
	var d := (load("res://game/client/audio/audio_director.tscn") as PackedScene).instantiate() as AudioDirector
	var bank := SoundBank.new()
	bank.cues = cues
	d.bank = bank
	d.crossfade_seconds = 0.0
	(Engine.get_main_loop() as SceneTree).root.add_child(d)
	return d


func _playing(d: AudioDirector) -> Array[AudioStreamPlayer]:
	var out: Array[AudioStreamPlayer] = []
	for v in d._voices:
		if v.playing:
			out.append(v)
	return out


func test_the_shipped_bank_lists_every_cue_the_game_plays_and_is_sound() -> void:
	var bank := load("res://game/content/audio/sound_bank.tres") as SoundBank
	assert_eq(bank.problems(), [] as Array[String])
	assert_eq(bank.cues.size(), SoundBank.CUES.size())


func test_the_buses_exist() -> void:
	for bus in ["Music", "Effects", "UI"]:
		assert_true(AudioServer.get_bus_index(bus) > 0, bus)


func test_a_cue_with_a_sound_plays_on_its_bus_and_a_cue_without_one_is_silent() -> void:
	var beep := _beep()
	var d := _director([_cue("hit", beep), _cue("miss", null), _cue("ui_click", beep, &"UI")])
	d.play("hit")
	assert_eq(_playing(d).size(), 1)
	assert_true(_playing(d)[0].stream == beep)
	assert_eq(_playing(d)[0].bus, &"Effects")
	d.play("miss")
	d.play("no_such_cue")
	assert_eq(_playing(d).size(), 1, "no file, no sound; an unknown name is ignored")
	d.play("ui_click")
	assert_eq(_playing(d).size(), 2)
	d.free()


func test_the_same_cue_is_not_stacked_within_its_gap() -> void:
	var d := _director([_cue("hit", _beep(), &"Effects", 60_000)])
	d.play("hit")
	d.play("hit")
	assert_eq(_playing(d).size(), 1)
	d.free()


func test_a_new_sound_cuts_the_oldest_when_every_voice_is_busy() -> void:
	var d := _director([_cue("hit", _beep())])
	d.voices = 1 # (set after _ready: the pool was made with the default, so shrink it by hand)
	while d._voices.size() > 1:
		d._voices.pop_back().queue_free()
	d.play("hit")
	d.play("hit")
	assert_eq(_playing(d).size(), 1)
	d.free()


func _event(type: String, data: Dictionary = {}) -> Dictionary:
	return {"type": type, "data": data}


func test_battle_events_play_their_generic_cue_and_a_skills_own_sound_wins() -> void:
	var beep := _beep()
	var skill_sound := _beep()
	var d := _director([_cue("hit", beep), _cue("crit", _beep()), _cue("miss", beep), _cue("cast", beep)])
	var db := SkillDb.new()
	var sk := SkillDef.new()
	sk.id = "slash"
	sk.hit_sound = skill_sound
	sk.cast_sound = skill_sound
	db.skills["slash"] = sk
	d.play_event(_event("hit", {"amount": 3}), db)
	assert_true(_playing(d)[0].stream == beep, "no skill sound: the generic hit")
	d._voices[0].stop()
	d._last_played.clear()
	d.play_event(_event("hit", {"amount": 3, "skill": "slash"}), db)
	assert_true(_playing(d)[0].stream == skill_sound, "the skill's own Hit Sound")
	d._voices[0].stop()
	d._last_played.clear()
	d.play_event(_event("windup", {"skill": "slash"}), db)
	assert_true(_playing(d)[0].stream == skill_sound, "and its Cast Sound")
	d._voices[0].stop()
	d.play_event(_event("hit", {"amount": 9, "crit": true}), db)
	assert_true(_playing(d)[0].stream != beep, "a critical hit has its own cue")
	d.play_event(_event("nothing_known_about_this"), db) # ignored
	d.free()


func test_music_follows_the_screen_and_is_not_restarted() -> void:
	var track := _beep()
	var other := _beep()
	var d := _director([_cue("music_menu", track, &"Music"), _cue("music_battle", other, &"Music"), _cue("music_story", null, &"Music")])
	d.play_music("music_menu")
	assert_eq(d.music_id, "music_menu")
	var now: AudioStreamPlayer = d._music[d._music_now]
	assert_true(now.stream == track and now.bus == &"Music")
	d.play_music("music_menu")
	assert_true(d._music[d._music_now] == now, "the same track keeps playing")
	d.play_music("music_battle")
	assert_true(d._music[d._music_now].stream == other)
	d.play_music("music_story")
	assert_true(not d._music[d._music_now].playing or d._music[d._music_now].stream != track, "a cue with no file ends the music")
	d.free()


func test_every_button_clicks_and_hovers_without_any_wiring() -> void:
	var beep := _beep()
	var d := _director([_cue("ui_click", beep, &"UI"), _cue("ui_hover", beep, &"UI")])
	var root := (Engine.get_main_loop() as SceneTree).root
	var b := Button.new()
	root.add_child(b)
	assert_true(b.has_meta("sfx_hooked"), "a button added later is hooked at once")
	b.pressed.emit()
	assert_eq(_playing(d).size(), 1)
	d._voices[0].stop()
	b.disabled = true
	b.mouse_entered.emit()
	assert_eq(_playing(d).size(), 0, "no hover sound for a disabled button")
	var quiet := Button.new()
	quiet.set_meta("silent", true)
	root.add_child(quiet)
	assert_true(not quiet.has_meta("sfx_hooked"), "a button can opt out with the 'silent' meta")
	b.queue_free()
	quiet.queue_free()
	d.free()


func test_the_helpers_do_nothing_when_there_is_no_director() -> void:
	var saved := AudioDirector.instance
	AudioDirector.instance = null
	AudioDirector.cue("hit")
	AudioDirector.music("music_menu")
	AudioDirector.event(_event("hit"), null)
	AudioDirector.instance = saved


func test_volumes_are_kept_per_bus_and_applied_to_the_buses() -> void:
	var saved := AudioSettings.file
	AudioSettings.file = "user://test_audio.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(AudioSettings.file))
	assert_eq(AudioSettings.load_volumes(), AudioSettings.DEFAULTS, "defaults before anything is saved")
	AudioSettings.set_volume("Music", 0.5)
	AudioSettings.set_volume("UI", 0.0)
	var i := AudioServer.get_bus_index("Music")
	assert_true(absf(AudioServer.get_bus_volume_db(i) - linear_to_db(0.5)) < 0.01)
	assert_true(AudioServer.is_bus_mute(AudioServer.get_bus_index("UI")), "0 mutes")
	assert_eq(AudioSettings.load_volumes()["Music"], 0.5, "kept for next time")
	AudioSettings.apply_all()
	for bus in AudioSettings.BUSES: # put the buses back to the defaults for the other tests
		AudioSettings.apply(bus, 1.0)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(AudioSettings.file))
	AudioSettings.file = saved


func test_the_settings_screen_has_a_slider_per_bus() -> void:
	var s := (load("res://game/client/screens/settings_screen.tscn") as PackedScene).instantiate() as SettingsScreen
	(Engine.get_main_loop() as SceneTree).root.add_child(s)
	var heard: Array = []
	s.volume_changed.connect(func(bus: String, v: float) -> void: heard.append([bus, v]))
	s.show_volumes({"Music": 0.25, "Effects": 0.5, "UI": 1.0})
	assert_eq(heard, [], "showing the saved volumes announces nothing")
	assert_eq((s.get_node("%MusicVolumeSlider") as HSlider).value, 0.25)
	(s.get_node("%EffectsVolumeSlider") as HSlider).value = 0.75
	assert_eq(heard, [["Effects", 0.75]])
	s.queue_free()


func test_battle_events_carry_the_skill_that_caused_them() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(1, 1)), Fx.enemy("e", V(2, 1), {"hp": 40})])
	Fx.plan(b, "a", [Fx.act("strike", "e")])
	Fx.plan(b, "e", [])
	b.begin_resolution()
	Fx.run_beats(b, 2)
	var found := false
	for e: Dictionary in b.events:
		if e["type"] in ["hit", "miss"]:
			found = true
			assert_eq(e["data"].get("skill"), "strike")
	assert_true(found, "the strike hit or missed")
