class_name CharacterBuild
extends RefCounted
## Works out the battle numbers of one character from its class template, level and allocated points. The single place
## that does this: the game server uses it to build a battle and the Character page uses it to show the stats.
## While config "progression.enabled" is false the level is treated as 1 and allocated points are ignored, so a character
## fights with exactly its class's attributes. Never trusts its input (the database may hold anything).


static func progression_enabled(cfg: GameConfig) -> bool:
	return cfg.get_value("progression", "enabled") as bool


## The level for a total XP, from config "progression.xp_to_level" (1 while progression is disabled).
static func level_for_xp(cfg: GameConfig, xp: int) -> int:
	if not progression_enabled(cfg):
		return 1
	var level := 1
	for need: int in cfg.get_value("progression", "xp_to_level"):
		if xp >= need:
			level += 1
	return level


## {attributes: {name: int}, stats: {max_hp, power, accuracy, evasion, dexterity, agility}, points_left: int,
## allocated: {name: int} (what was accepted)}.
static func compose(tpl: UnitTemplate, level: int, allocated: Dictionary, cfg: GameConfig) -> Dictionary:
	var attrs := tpl.base_attributes().to_dict()
	var accepted := {}
	var points_left := 0
	if progression_enabled(cfg):
		level = maxi(1, level)
		var growth := tpl.growth
		var value := tpl.point_value
		var budget := tpl.stat_points_per_level * (level - 1)
		for a in Attributes.NAMES:
			if growth != null:
				attrs[a] += growth.get_attr(a) * (level - 1)
			var asked := _whole(allocated.get(a, 0))
			var worth := value.get_attr(a) if value != null else 0
			if asked <= 0 or worth <= 0:
				continue
			if tpl.max_points_per_stat > 0:
				asked = mini(asked, tpl.max_points_per_stat)
			asked = mini(asked, budget)
			if asked > 0:
				attrs[a] += asked * worth
				accepted[a] = asked
				budget -= asked
		points_left = budget
	return {"attributes": attrs, "stats": battle_stats(attrs, cfg), "points_left": points_left, "allocated": accepted}


## The battle numbers for a set of attributes. Armor is not here: it comes from gear (later).
static func battle_stats(attrs: Dictionary, cfg: GameConfig) -> Dictionary:
	var s := func(key: String) -> Variant: return cfg.get_value("stats", key)
	return {
		"max_hp": maxi(1, (s.call("hp_base") as int) + (attrs["vitality"] as int) * (s.call("hp_per_vitality") as int)),
		"power": roundi((attrs["might"] as int) * (s.call("power_per_might") as float)),
		"accuracy": roundi(((attrs["dexterity"] as int) - (s.call("accuracy_baseline") as float)) * (s.call("accuracy_per_dexterity") as float)),
		"evasion": roundi(((attrs["agility"] as int) - (s.call("evasion_baseline") as float)) * (s.call("evasion_per_agility") as float)),
		"dexterity": maxi(1, attrs["dexterity"] as int),
		"agility": maxi(1, attrs["agility"] as int),
	}


static func _whole(v: Variant) -> int:
	return int(v) if (v is int or v is float) else 0
