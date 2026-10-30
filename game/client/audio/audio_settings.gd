class_name AudioSettings
extends RefCounted
## The player's volume per bus (Music, Effects, UI), kept on this device and applied to the audio buses. The sliders are on the Settings screen.

## Where the volumes are kept (a variable so tests can use a throwaway file).
static var file: String = "user://audio.cfg"
const BUSES: Array[String] = ["Music", "Effects", "UI"]
## PROVISIONAL starting volumes, 0 to 1.
const DEFAULTS := {"Music": 0.7, "Effects": 0.9, "UI": 0.8}


static func load_volumes() -> Dictionary:
	var out := DEFAULTS.duplicate()
	var cf := ConfigFile.new()
	if cf.load(file) == OK:
		for bus in BUSES:
			out[bus] = clampf(float(cf.get_value("volume", bus, out[bus])), 0.0, 1.0)
	return out


## Applies one bus's volume (0 mutes it) and remembers it.
static func set_volume(bus: String, value: float) -> void:
	apply(bus, value)
	var cf := ConfigFile.new()
	cf.load(file)
	cf.set_value("volume", bus, clampf(value, 0.0, 1.0))
	cf.save(file)


static func apply(bus: String, value: float) -> void:
	var i := AudioServer.get_bus_index(bus)
	if i < 0:
		return
	AudioServer.set_bus_mute(i, value <= 0.0)
	AudioServer.set_bus_volume_db(i, linear_to_db(maxf(value, 0.0001)))


static func apply_all() -> void:
	var v := load_volumes()
	for bus in BUSES:
		apply(bus, v[bus])
