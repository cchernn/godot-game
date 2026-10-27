class_name SkillSet
extends Resource
## Every skill the game knows (game/content/skills/skill_set.tres). To add a skill: make a SkillDef resource,
## then add it to this list.

@export var skills: Array[SkillDef] = []
## The basic actions every player character has automatically (Move, Attack, Defend), so classes do not list them. Each must also be in
## the list above. Enemies do not get them: an enemy lists whatever it can do.
@export var basic: Array[SkillDef] = []
## The attack a player character falls back on when no gear gives it one (bare hands). Must also be in the list above.
@export var unarmed: SkillDef


func problems() -> Array[String]:
	var out: Array[String] = []
	var seen := {}
	for s in skills:
		if s == null:
			out.append("a skill slot is empty")
			continue
		if seen.has(s.id):
			out.append("skill '%s' appears twice" % s.id)
		seen[s.id] = true
		out.append_array(s.problems())
	for b in basic:
		if b == null or not seen.has(b.id):
			out.append("a basic skill is not in the skill list")
	if unarmed != null and not seen.has(unarmed.id):
		out.append("the unarmed attack is not in the skill list")
	return out
