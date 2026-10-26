class_name GrantItemEffect
extends SkillEffect
## Gives copies of an item to whoever receives it, up to the item's own limit. Kept in the battle result and added to the character's
## inventory when the result is saved. PROVISIONAL.

@export var item_id: String = ""
@export_range(1, 99) var count: int = 1


func to_dict() -> Dictionary:
	return {"type": "grant_item", "on": on, "item": item_id, "count": count}


func problems() -> Array[String]:
	return ["a grant item effect needs an item id"] if item_id == "" else []
