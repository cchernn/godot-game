class_name GearSet
extends Resource
## Every piece of gear the game knows (game/content/gear/gear_set.tres). To add gear: make a GearDef resource, then add it to this list.

const PATH := "res://game/content/gear/gear_set.tres"

@export var gear: Array[GearDef] = []


static func load_file(path: String = PATH) -> GearSet:
	var set := load(path) as GearSet
	assert(set != null, "Cannot load the gear set: %s" % path)
	return set


func get_gear(id: String) -> GearDef:
	for g in gear:
		if g != null and g.id == id:
			return g
	return null


## The gear a character wears, from the ids it holds equipped: unknown ids and anything past a kind's limit are ignored, so nothing
## the database holds can give a character more than the slots allow.
func worn(ids: Array) -> Array[GearDef]:
	var out: Array[GearDef] = []
	var count := {}
	for id: Variant in ids:
		var g := get_gear(str(id))
		if g == null:
			continue
		if int(count.get(g.slot, 0)) >= GearDef.slot_limit(g.slot):
			continue
		count[g.slot] = int(count.get(g.slot, 0)) + 1
		out.append(g)
	return out


func problems(known: SkillDb) -> Array[String]:
	var out: Array[String] = []
	var seen := {}
	for g in gear:
		if g == null:
			out.append("a gear slot is empty")
			continue
		if seen.has(g.id):
			out.append("gear '%s' appears twice" % g.id)
		seen[g.id] = true
		out.append_array(g.problems(known))
	return out
