class_name EncounterDef
extends Resource
## One battle setup, edited in the Inspector: which map, which classes the party can use, and who the enemies are.
## The map scene supplies the tiles and the spawn markers (P0.., E0..); this resource decides who stands on them.

## The painted map scene (game/content/maps/*.tscn). Its file name is the id the clients use to draw it.
@export var map: PackedScene
## Player classes. Seat 0 defaults to the first, seat 1 to the second, and so on; a player whose character
## class matches one of these (by id) gets that class instead. The list length is also the maximum party size, unless Max Party is higher.
@export var classes: Array[UnitTemplate] = []
## The most players the battle seats. 0 = one seat per class. Seats beyond the class list start as the classes again, in order
## (a seat's class is replaced by the character's own anyway).
@export_range(0, 8) var max_party: int = 0
## Gold each player who is still in the fight at the end of a win receives (the same for everyone). PROVISIONAL; 0 = none.
@export_range(0, 100000) var gold: int = 0
## Enemies in order: the first stands on spawn marker E0, the second on E1, and so on.
@export var enemies: Array[UnitTemplate] = []
## Things that happen during the fight: enemies waking up, arriving or falling away (see EncounterTrigger).
@export var triggers: Array[EncounterTrigger] = []


func map_id() -> String:
	return map.resource_path.get_file().get_basename() if map != null else ""


func max_players() -> int:
	return maxi(classes.size(), max_party)


## The class template for a character class id, or null.
func class_by_id(class_id: String) -> UnitTemplate:
	for t in classes:
		if t.id == class_id:
			return t
	return null


func problems(known: SkillDb) -> Array[String]:
	var out: Array[String] = []
	if map == null:
		out.append("encounter has no map")
	if classes.is_empty():
		out.append("encounter has no player classes")
	if enemies.is_empty():
		out.append("encounter has no enemies")
	var seen := {}
	for t in classes:
		if t == null:
			out.append("a class slot is empty")
			continue
		if seen.has(t.id):
			out.append("class '%s' appears twice" % t.id)
		seen[t.id] = true
		out.append_array(t.problems(known))
	for t in enemies:
		if t == null:
			out.append("an enemy slot is empty")
			continue
		out.append_array(t.problems(known))
	for tr in triggers:
		if tr == null:
			out.append("a trigger slot is empty")
		else:
			out.append_array(tr.problems(enemies.size()))
	return out
