class_name DropEntry
extends Resource
## One thing an encounter may drop, edited in the Inspector. Every player who is still in the fight at the end of a win rolls for it
## on their own. Set either a gear piece (each drop is its own copy) or a consumable item. All numbers are PROVISIONAL.

@export var gear: GearDef
@export var item: ItemDef
## The chance, in percent, that a player gets it.
@export_range(1, 100) var chance_percent: int = 10
## How many copies of a consumable (a gear drop is always one piece).
@export_range(1, 99) var count: int = 1


## The id as the API knows it, and which kind it is.
func is_gear() -> bool:
	return gear != null


func drop_id() -> String:
	return gear.id if gear != null else (item.id if item != null else "")


func problems() -> Array[String]:
	var out: Array[String] = []
	if (gear == null) == (item == null):
		out.append("a drop needs exactly one of gear or item")
	return out
