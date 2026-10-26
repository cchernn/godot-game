class_name ItemSet
extends Resource
## Every item the game knows (game/content/items/item_set.tres). To add an item: make an ItemDef resource, then add it to this list.

@export var items: Array[ItemDef] = []


func problems() -> Array[String]:
	var out: Array[String] = []
	var seen := {}
	for it in items:
		if it == null:
			out.append("an item slot is empty")
			continue
		if seen.has(it.id):
			out.append("item '%s' appears twice" % it.id)
		seen[it.id] = true
		out.append_array(it.problems())
	return out
