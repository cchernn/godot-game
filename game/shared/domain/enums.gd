class_name Enums
extends RefCounted

enum Facing { NORTH, EAST, SOUTH, WEST } # NORTH = -y, EAST = +x
enum Team { PLAYERS, ENEMIES }
## Alive -> Downed -> (revived: Alive but inactive this round) -> Eliminated on second defeat.
## Escaped: the character left the fight by choice; they are off the board and spectate.
enum LifeState { ALIVE, DOWNED, ELIMINATED, ESCAPED }
enum RoundPhase { PLANNING, RESOLVING, FINISHED }
enum Frequency { ONCE_PER_TURN, UNLIMITED }
enum TerrainKind { NORMAL, DIFFICULT, BLOCKED }
## SUPPORT: heals, shields and the like. Like ATTACK, it can be aimed at anyone; the kind only says what the skill is for.
enum SkillKind { MOVE, ATTACK, REACTION, REVIVE, SUPPORT }
## SELF: no click, the caster is the target.
## Which slot of the action bar a skill sits in: Attack opens a list, Move and Defend are one button each.
enum ActionSlot { ATTACK, MOVE, DEFEND }
enum Targeting { NONE, CHARACTER, TILE, SELF }
## ESCAPED: nobody is left standing and at least one character got away.
enum Outcome { NONE, PLAYERS_WIN, PLAYERS_LOSE, DRAW, ESCAPED }

const DIRS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]


static func facing_from_delta(d: Vector2i) -> int:
	if absi(d.x) > absi(d.y):
		return Facing.EAST if d.x > 0 else Facing.WEST
	return Facing.SOUTH if d.y > 0 else Facing.NORTH


static func manhattan(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)
