class_name UnitTemplate
extends Resource
## The stats of one kind of combatant: a player class (warrior, ranger...) or an enemy (ghoul...).
## Edit the .tres files under game/content/stats in the Inspector. All numbers are PROVISIONAL.
## Rules that use them (hit chance, damage formulas, AP) are in code and in config/balance.json.

@export_group("Identity")
## Lower-case id. For player classes it must match the class names in services/api/app/rules.py and
## account_flow.gd. It is also the key used to pick this unit's look in units/unit_visuals.tres.
@export var id: String = ""
## Shown above the unit and in the combat log.
@export var display_name: String = ""

@export_group("Stats")
@export_range(1, 9999) var max_hp: int = 20
## Dexterity sets action points and speed (see config/balance.json "ap").
@export_range(1, 99) var dexterity: int = 8
## Added to the damage of every attack.
@export_range(0, 99) var power: int = 0
## Subtracted from incoming damage.
@export_range(0, 99) var armor: int = 0
## Added to the chance to hit.
@export_range(-99, 99) var accuracy: int = 0
## Subtracts from the enemy's chance to hit.
@export_range(-99, 99) var evasion: int = 0

@export_group("Skills")
## Skill ids from config/skills.json: move, strike, power_strike, bolt, disrupt, revive.
@export var skills: Array[String] = []


## What is wrong with this template, if anything (empty = fine). `known` is the SkillDb.
func problems(known: SkillDb) -> Array[String]:
	var out: Array[String] = []
	if id == "" or id != id.to_lower() or " " in id:
		out.append("id must be lower-case with no spaces (got '%s')" % id)
	if display_name == "":
		out.append("%s: display_name is empty" % id)
	if max_hp < 1 or dexterity < 1:
		out.append("%s: max_hp and dexterity must be at least 1" % id)
	if skills.is_empty():
		out.append("%s: has no skills" % id)
	for sid in skills:
		if known.get_skill(sid) == null:
			out.append("%s: unknown skill '%s'" % [id, sid])
	return out


func make_combatant(combatant_id: String, team: int, facing: int, cell: Vector2i) -> Combatant:
	var c := Combatant.new()
	c.id = combatant_id
	c.display_name = display_name
	c.visual = id
	c.team = team
	c.cell = cell
	c.facing = facing
	c.max_hp = max_hp
	c.hp = max_hp
	c.dexterity = dexterity
	c.power = power
	c.armor = armor
	c.accuracy = accuracy
	c.evasion = evasion
	c.skills.assign(skills)
	return c
