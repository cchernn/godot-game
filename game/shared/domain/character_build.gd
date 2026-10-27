class_name CharacterBuild
extends RefCounted
## Works out the battle numbers and skills of one character from its class template and the event flags it holds. The single place
## that does this: the game server uses it to build a battle and the Character page uses it to show the stats.
## There are no levels: a character is its class's attributes plus the Attribute Grants whose flags it has earned, kept within the cap in
## config "stats.attribute_cap". Skills are the class's own plus the Skill Unlocks whose conditions are met. Never trusts its input
## (the database may hold anything).


## {attributes: {name: int}, stats: {max_hp, power, accuracy, evasion, dexterity, agility, armor (the gear's)}, skills: Array[String] (ids,
## in order: starting, unlocked, then granted by gear), gear: Array[String] (ids)}. `flags` = the event flags the character holds.
static func compose(tpl: UnitTemplate, cfg: GameConfig, flags: Array = []) -> Dictionary:
	var held: Array = flags.filter(func(f: Variant) -> bool: return f is String)
	var attrs := tpl.base_attributes().to_dict()
	for g in tpl.attribute_grants:
		if g != null and g.bonus != null and g.flag in held:
			for a in Attributes.NAMES:
				attrs[a] += maxi(0, g.bonus.get_attr(a))
	var cap: int = cfg.get_value("stats", "attribute_cap")
	for a in Attributes.NAMES:
		attrs[a] = clampi(attrs[a], 0 if a == "might" else 1, cap)
	var stats := battle_stats(attrs, cfg)
	var armor := 0
	var skills := _skills(tpl, attrs, held)
	var gear: Array[String] = []
	for g in tpl.gear:
		if g == null:
			continue
		gear.append(g.id)
		armor += g.armor
		for sk in g.grants:
			if not sk.id in skills:
				skills.append(sk.id)
	stats["armor"] = armor
	return {"attributes": attrs, "stats": stats, "skills": skills, "gear": gear}


static func _skills(tpl: UnitTemplate, attrs: Dictionary, held: Array) -> Array[String]:
	var ids: Array[String] = []
	for sk in tpl.skills:
		ids.append(sk.id)
	var ctx := {"attributes": attrs, "flags": held}
	for u in tpl.unlocks:
		if u != null and u.skill != null and not u.skill.id in ids and u.is_met(ctx):
			ids.append(u.skill.id)
	return ids


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
