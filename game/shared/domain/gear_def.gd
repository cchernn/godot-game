class_name GearDef
extends Resource
## One piece of equipment, edited in the Inspector (game/content/gear/*.tres). A class lists the gear it starts with; a character
## has two weapon slots, one armor slot and one accessory slot. All numbers are PROVISIONAL.

enum Slot { WEAPON, ARMOR, ACCESSORY }

## The places on a character that gear goes, in the order the Inventory shows them: the slot kind each one takes. PROVISIONAL.
const WORN_PLACES: Array[String] = ["weapon_1", "weapon_2", "armor", "accessory"]

@export_group("Identity")
## Lower-case id: the file name.
@export var id: String = ""
@export var display_name: String = ""
@export_multiline var description: String = ""
@export var slot: Slot = Slot.WEAPON

@export_group("Effect")
## Flat damage taken off every hit (after flanking and crits, before a shield; a hit still does at least 1). Adds up over all gear worn.
@export_range(0, 99) var armor: int = 0
## The attacks and skills this gear lets its wearer use (a weapon's attack goes in the Attack list: give the skill the Attack action slot).
## Each must also be in skills/skill_set.tres.
@export var grants: Array[SkillDef] = []


func slot_name() -> String:
	return ["weapon", "armor", "accessory"][slot]


## Which kind of gear a worn place takes ("weapon_2" -> WEAPON), or -1 for a place that does not exist.
static func place_slot(place: String) -> int:
	match place:
		"weapon_1", "weapon_2":
			return Slot.WEAPON
		"armor":
			return Slot.ARMOR
		"accessory":
			return Slot.ACCESSORY
	return -1


## How many of a kind a character wears at once.
static func slot_limit(kind: int) -> int:
	return 2 if kind == Slot.WEAPON else 1


func problems(known: SkillDb) -> Array[String]:
	var out: Array[String] = []
	if id == "" or id != id.to_lower() or " " in id:
		out.append("gear id must be lower-case with no spaces (got '%s')" % id)
	if display_name == "":
		out.append("%s: display_name is empty" % id)
	for sk in grants:
		if sk == null:
			out.append("%s: a granted skill slot is empty" % id)
		elif known.get_skill(sk.id) == null:
			out.append("%s: granted skill '%s' is not in the skill set" % [id, sk.id])
	return out
