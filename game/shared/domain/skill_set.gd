class_name SkillSet
extends Resource
## Every skill the game knows (game/content/skills/skill_set.tres). To add a skill: make a SkillDef resource,
## then add it to this list.

@export var skills: Array[SkillDef] = []


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
	return out
