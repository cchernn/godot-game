class_name Visibility
extends RefCounted


static func can_see(bf: Battlefield, from: Vector2i, to: Vector2i, sight_range: int) -> bool:
	return Enums.manhattan(from, to) <= sight_range and bf.has_los(from, to)


## True if any present (alive or downed) member of `team` can see the cell.
static func team_sees(state: BattleState, bf: Battlefield, team: int, cell: Vector2i, sight_range: int) -> bool:
	for c: Combatant in state.team_members(team):
		if c.is_present() and can_see(bf, c.cell, cell, sight_range):
			return true
	return false
