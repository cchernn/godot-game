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
var dexterity: int = 8
var power: int = 0
var armor: int = 0
var accuracy: int = 0
var evasion: int = 0
var skills: Array[String] = []

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
## Player id controlling this character ("" for AI).
var controller: String = ""


func is_active(round_number: int) -> bool:
	return life_state == Enums.LifeState.ALIVE and round_number >= inactive_until_round


func is_present() -> bool:
	return life_state != Enums.LifeState.ELIMINATED
