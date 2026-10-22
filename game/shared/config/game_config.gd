class_name GameConfig
extends RefCounted
## Typed access to provisional balance values loaded from balance.json.

const DEFAULT_PATH := "res://game/shared/config/balance.json"

var data: Dictionary = {}


static func load_file(path: String = DEFAULT_PATH) -> GameConfig:
	var cfg := GameConfig.new()
	var file := FileAccess.open(path, FileAccess.READ)
	assert(file != null, "Cannot open config: %s" % path)
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	assert(parsed is Dictionary, "Config is not a JSON object: %s" % path)
	cfg.data = parsed
	return cfg


static func from_dict(d: Dictionary) -> GameConfig:
	var cfg := GameConfig.new()
	cfg.data = d
	return cfg


func get_value(section: String, key: String) -> Variant:
	return (data[section] as Dictionary)[key]


## AP capacity: base plus one per Dexterity threshold reached, capped. (Provisional formula.)
func ap_capacity(dexterity: int) -> int:
	var cap: int = get_value("ap", "base_capacity")
	for t: int in get_value("ap", "dexterity_thresholds"):
		if dexterity >= t:
			cap += 1
	return mini(cap, get_value("ap", "max_capacity") as int)


## Tiles moved per AP: base plus Dexterity bonus, bonus capped. (Provisional formula.)
func tiles_per_ap(dexterity: int) -> int:
	var bonus := 0
	for t: int in get_value("movement", "dexterity_bonus_thresholds"):
		if dexterity >= t:
			bonus += 1
	bonus = mini(bonus, get_value("movement", "max_dexterity_bonus") as int)
	return (get_value("movement", "tiles_per_ap") as int) + bonus
