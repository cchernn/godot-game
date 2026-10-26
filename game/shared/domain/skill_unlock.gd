class_name SkillUnlock
extends Resource
## A skill a class can gain beyond its starting skills, and what it takes. Add these to a class's Unlocks list.
## Only used while config "progression.enabled" is true.

enum Mode {
	## The skill is simply added once every condition is met.
	GRANTED,
	## Once every condition is met the skill becomes pickable; each pick costs one of the class's skill picks.
	PICK,
}

@export var skill: SkillDef
## All of these must be met.
@export var conditions: Array[UnlockCondition] = []
@export var mode: Mode = Mode.GRANTED


func is_met(ctx: Dictionary) -> bool:
	for c in conditions:
		if c == null or not c.met(ctx):
			return false
	return true


func problems(known: SkillDb, owner_id: String) -> Array[String]:
	var out: Array[String] = []
	if skill == null:
		return ["%s: an unlock has no skill" % owner_id] as Array[String]
	if known.get_skill(skill.id) == null:
		out.append("%s: unlock skill '%s' is not in the skill set" % [owner_id, skill.id])
	if conditions.is_empty():
		out.append("%s: unlock '%s' has no conditions" % [owner_id, skill.id])
	for c in conditions:
		var p := "an empty condition slot" if c == null else c.problem()
		if p != "":
			out.append("%s: unlock '%s': %s" % [owner_id, skill.id, p])
	return out
