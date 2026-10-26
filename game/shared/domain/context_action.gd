class_name ContextAction
extends Resource
## One thing a unit next to a map object can do ("Open", "Pull", "Disarm"). Planned like a skill: it costs the AP of its stages
## and resolves in the beat order by its speed. All numbers are PROVISIONAL; no real objects ship yet.

## Lower-case id with no spaces or colons: what plans refer to.
@export var id: String = ""
## Shown on the Context list and in the combat log.
@export var display_name: String = ""
@export_multiline var hint: String = ""
## The object must be in this state for the action to be offered. Empty = any state.
@export var requires_state: String = ""
## The object's state after the action. Empty = unchanged.
@export var sets_state: String = ""
## What the action does: speed and stages (each with its AP cost and effects). Effects land on the unit that acts (use Grant Item,
## Set Flag, Damage, Heal, Apply Status...). A stage with no effects is fine, e.g. a lever that only changes state.
## Its kind, targeting and frequency are set by the game.
@export var use: SkillDef


func problems(owner_id: String) -> Array[String]:
	var out: Array[String] = []
	if id == "" or id != id.to_lower() or " " in id or ":" in id:
		out.append("%s: action id must be lower-case with no spaces or colons (got '%s')" % [owner_id, id])
	if display_name == "":
		out.append("%s/%s: display_name is empty" % [owner_id, id])
	if use == null:
		out.append("%s/%s: has no 'use' skill" % [owner_id, id])
		return out
	var probe := make_skill("probe")
	for p in probe.problems():
		out.append("%s/%s: %s" % [owner_id, id, p])
	return out


## The skill the battle runs for this action on the object `object_id`: its own copy with the id set.
func make_skill(object_id: String) -> SkillDef:
	var sk := use.duplicate(true) as SkillDef
	sk.id = skill_id_for(object_id, id)
	sk.display_name = display_name
	if sk.hint == "":
		sk.hint = hint
	sk.kind = Enums.SkillKind.SUPPORT
	sk.targeting = Enums.Targeting.SELF
	sk.area = null
	sk.frequency = Enums.Frequency.UNLIMITED
	return sk


static func skill_id_for(object_id: String, action_id: String) -> String:
	return "ctx:%s:%s" % [object_id, action_id]
