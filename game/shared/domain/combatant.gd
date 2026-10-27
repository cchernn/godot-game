class_name Combatant
extends RefCounted
## Authoritative per-battle state of one character or enemy.

var id: String
var display_name: String
## Key into the client's UnitVisuals resource (a class or enemy template id, e.g. "warrior", "ghoul").
var visual: String = ""
var team: int = Enums.Team.PLAYERS
var cell: Vector2i
var facing: int = Enums.Facing.SOUTH
var max_hp: int = 20
var hp: int = 20
## Soaks damage after armor, before HP; cleared at the end of every round.
var shield: int = 0
## A shield that only lasts the beat it was raised in; soaks damage before `shield` does.
var beat_shield: int = 0
## Sets action points (see config "ap").
var dexterity: int = 8
## Sets tiles moved per AP (see config "movement").
var agility: int = 8
var power: int = 0
var armor: int = 0
var accuracy: int = 0
var evasion: int = 0
var skills: Array[String] = []
## What this combatant carries into the battle: item id -> copies. Enemies carry nothing.
var items: Dictionary = {}
## Copies used up so far (an item is used up when its skill begins), reported with the result.
var items_used: Dictionary = {}
## Copies picked up during the battle (from map objects), and event flags earned. Reported with the result.
var items_gained: Dictionary = {}
var flags_gained: Array[String] = []
## Active statuses: {id, def (StatusDef.to_dict()), turns_left, stacks}. Counted in turns, cleared when the combatant is defeated.
var statuses: Array[Dictionary] = []

var life_state: int = Enums.LifeState.ALIVE
## Only one revival per encounter.
var revived_this_encounter: bool = false
## Revived characters cannot act or react until this round.
var inactive_until_round: int = 0

# AP: capacity refreshes each round; reserved (committed, unspent), spent, and forfeited are tracked separately.
var ap_capacity: int = 0
var ap_reserved: int = 0
var ap_spent: int = 0
var ap_forfeited: int = 0

var ready: bool = false
var plan: Array[PlannedAction] = []
var queue_index: int = 0
var current: PlannedAction = null
var current_stage: int = 0
var move_index: int = 0
var interrupt_points: int = 0
## skill_id -> true once a once-per-turn skill began executing this round
var skills_used: Dictionary = {}
## Prepared reaction: {skill, expires_beat} or empty.
var reaction: Dictionary = {}
## Asked to escape while beats were resolving; takes effect before the next beat.
var escape_pending: bool = false
## Player id controlling this character ("" for AI).
var controller: String = ""


func is_active(round_number: int) -> bool:
	return life_state == Enums.LifeState.ALIVE and round_number >= inactive_until_round


func is_present() -> bool:
	return life_state != Enums.LifeState.ELIMINATED and life_state != Enums.LifeState.ESCAPED


## Armor, power, accuracy, evasion, dexterity or agility including the changes from statuses (always use this in the rules, not the raw field).
func stat(stat_name: String) -> int:
	var v: int = get(stat_name)
	for s in statuses:
		v += ((s["def"]["mods"] as Dictionary).get(stat_name, 0) as int) * (s["stacks"] as int)
	return maxi(1, v) if stat_name == "dexterity" or stat_name == "agility" else v


## True when any status carries the condition ("stunned", "rooted" or "maimed").
func has_condition(condition: String) -> bool:
	for s in statuses:
		if s["def"].get(condition, false):
			return true
	return false


## The active status with this id, or an empty dictionary.
func status_of(status_id: String) -> Dictionary:
	for s in statuses:
		if s["id"] == status_id:
			return s
	return {}
