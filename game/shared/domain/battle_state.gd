class_name BattleState
extends RefCounted
## Authoritative state of one encounter. No networking or persistence code.

var round_number: int = 1
var phase: int = Enums.RoundPhase.PLANNING
var combatants: Dictionary = {} # id -> Combatant


func add(c: Combatant) -> void:
	combatants[c.id] = c


func get_c(id: String) -> Combatant:
	return combatants.get(id) as Combatant


## Occupant of a tile (downed characters still occupy; eliminated ones do not).
func at_cell(cell: Vector2i) -> Combatant:
	for c: Combatant in combatants.values():
		if c.cell == cell and c.is_present():
			return c
	return null


func team_members(team: int) -> Array[Combatant]:
	var out: Array[Combatant] = []
	for id: String in combatants.keys():
		var c: Combatant = combatants[id]
		if c.team == team:
			out.append(c)
	return out
