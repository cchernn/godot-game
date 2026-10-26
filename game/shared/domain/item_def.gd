class_name ItemDef
extends Resource
## A consumable a character can bring into a battle (game/content/items/*.tres). Using it runs the embedded skill, so everything
## a skill can do (heal, shield, damage, areas, statuses) an item can do. All numbers are PROVISIONAL; no real items ship yet.

## Lower-case id with no spaces: what the inventory stores and plans refer to.
@export var id: String = ""
@export var display_name: String = ""
## One line shown on the Item list and when the item is picked.
@export_multiline var hint: String = ""
## Most copies a character can carry (the grant script and later shops respect it).
@export_range(1, 99) var max_stack: int = 5
## What using it does: targeting, range, area, speed and stages with effects, exactly like a skill. Its id and frequency are set by
## the game (an item can be used as often as the character has copies and AP).
@export var use: SkillDef


## The id the item's skill goes by in the skill list and in plans.
static func skill_id_for(item_id: String) -> String:
	return "item:" + item_id


func problems() -> Array[String]:
	var out: Array[String] = []
	if id == "" or id != id.to_lower() or " " in id or ":" in id:
		out.append("item id must be lower-case with no spaces or colons (got '%s')" % id)
	if display_name == "":
		out.append("%s: display_name is empty" % id)
	if use == null:
		out.append("%s: has no use skill" % id)
		return out
	if use.kind not in [Enums.SkillKind.ATTACK, Enums.SkillKind.SUPPORT, Enums.SkillKind.REVIVE]:
		out.append("%s: the use skill must be an attack, support or revive" % id)
	var probe := use.duplicate(true) as SkillDef
	probe.id = skill_id_for(id)
	probe.display_name = display_name
	for p in probe.problems():
		out.append("%s: %s" % [id, p])
	return out


## The skill the battle runs, as its own copy: id set, display name defaulted, no once-per-turn limit.
func make_skill() -> SkillDef:
	var sk := use.duplicate(true) as SkillDef
	sk.id = skill_id_for(id)
	if sk.display_name == "":
		sk.display_name = display_name
	if sk.hint == "":
		sk.hint = hint
	sk.frequency = Enums.Frequency.UNLIMITED
	return sk
