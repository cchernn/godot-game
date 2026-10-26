class_name UnitTemplate
extends Resource
## The stats of one kind of combatant: a player class (warrior, ranger...) or an enemy (ghoul...).
## Edit the .tres files under game/content/stats in the Inspector. All numbers are PROVISIONAL.
## Rules that use them (hit chance, damage formulas, AP) are in code and in config/balance.json ("stats" turns attributes into battle numbers); what each skill does is in
## game/content/skills.

@export_group("Identity")
## Lower-case id. For player classes it must match the class names in services/api/app/rules.py and
## account_flow.gd. It is also the key used to pick this unit's look in units/unit_visuals.tres.
@export var id: String = ""
## Shown above the unit and in the combat log.
@export var display_name: String = ""

@export_group("Attributes")
## Max HP: config "stats" hp_base + this x hp_per_vitality.
@export_range(1, 99) var vitality: int = 5
## Added to the damage and healing of every skill (config "stats" power_per_might).
@export_range(0, 99) var might: int = 0
## Sets action points (config "ap") and adds to the chance to hit.
@export_range(1, 99) var dexterity: int = 10
## Sets tiles moved per AP (config "movement") and subtracts from the enemy's chance to hit.
@export_range(1, 99) var agility: int = 8

@export_group("Progression")
## Attributes gained per level above 1. Only used when config "progression.enabled" is true. Leave empty for none.
@export var growth: Attributes
## What one allocated point is worth, per attribute. An attribute at 0 here cannot take points.
@export var point_value: Attributes
## Points a character earns at each level above 1.
@export_range(0, 20) var stat_points_per_level: int = 0
## The most points a character can put in one attribute. 0 = no limit.
@export_range(0, 99) var max_points_per_stat: int = 0

@export_group("Skills")
## The skills this unit can use. Pick skill resources from game/content/skills (move, strike, power_strike, bolt,
## disrupt, revive, or your own). A skill must also be listed in skills/skill_set.tres.
@export var skills: Array[SkillDef] = []


## What is wrong with this template, if anything (empty = fine). `known` is the SkillDb.
func problems(known: SkillDb) -> Array[String]:
	var out: Array[String] = []
	if id == "" or id != id.to_lower() or " " in id:
		out.append("id must be lower-case with no spaces (got '%s')" % id)
	if display_name == "":
		out.append("%s: display_name is empty" % id)
	if vitality < 1 or dexterity < 1 or agility < 1:
		out.append("%s: vitality, dexterity and agility must be at least 1" % id)
	for part: Attributes in [growth, point_value]:
		if part != null and (part.might < 0 or part.dexterity < 0 or part.agility < 0 or part.vitality < 0):
			out.append("%s: growth and point values cannot be negative" % id)
	if stat_points_per_level > 0 and (point_value == null or point_value.is_zero()):
		out.append("%s: earns stat points but no attribute has a point value" % id)
	if skills.is_empty():
		out.append("%s: has no skills" % id)
	for sk in skills:
		if sk == null:
			out.append("%s: a skill slot is empty" % id)
		elif known.get_skill(sk.id) == null:
			out.append("%s: skill '%s' is not in the skill set" % [id, sk.id])
	return out


func base_attributes() -> Attributes:
	var a := Attributes.new()
	a.might = might
	a.dexterity = dexterity
	a.agility = agility
	a.vitality = vitality
	return a


## `build` is CharacterBuild.compose(...) for this template (leave empty for the plain class at level 1).
func make_combatant(combatant_id: String, team: int, facing: int, cell: Vector2i, cfg: GameConfig,
		build: Dictionary = {}) -> Combatant:
	if build.is_empty():
		build = CharacterBuild.compose(self, 1, {}, cfg)
	var st: Dictionary = build["stats"]
	var c := Combatant.new()
	c.id = combatant_id
	c.display_name = display_name
	c.visual = id
	c.team = team
	c.cell = cell
	c.facing = facing
	c.max_hp = st["max_hp"]
	c.hp = c.max_hp
	c.dexterity = st["dexterity"]
	c.agility = st["agility"]
	c.power = st["power"]
	c.accuracy = st["accuracy"]
	c.evasion = st["evasion"]
	for sk in skills:
		c.skills.append(sk.id)
	return c
