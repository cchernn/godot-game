class_name AttributeGrant
extends Resource
## A permanent attribute gain a character earns: once it holds the event flag, the bonus is added to its class attributes (never past the cap
## in config "stats.attribute_cap"). Activities, items and story events set the flags; add these to a class's Attribute Grants list.

## Lower-case with no spaces, e.g. "trained_with_the_smith".
@export var flag: String = ""
## What the flag is worth, per attribute. Leave an attribute at 0 to leave it alone.
@export var bonus: Attributes


func problems(owner_id: String) -> Array[String]:
	var out: Array[String] = []
	if flag == "" or flag != flag.to_lower() or " " in flag:
		out.append("%s: an attribute grant needs a lower-case flag with no spaces (got '%s')" % [owner_id, flag])
	if bonus == null or bonus.is_zero():
		out.append("%s: attribute grant '%s' gives nothing" % [owner_id, flag])
	elif bonus.might < 0 or bonus.dexterity < 0 or bonus.agility < 0 or bonus.vitality < 0:
		out.append("%s: attribute grant '%s' cannot be negative" % [owner_id, flag])
	return out
