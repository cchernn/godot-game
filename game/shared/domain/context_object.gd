class_name ContextObject
extends RefCounted
## One map object in a running battle: where it is and what state it is in.

var id: String
var def: ContextObjectDef
var cell: Vector2i
var state: String


func _init(p_id: String, p_def: ContextObjectDef, p_cell: Vector2i) -> void:
	id = p_id
	def = p_def
	cell = p_cell
	state = p_def.initial_state


func blocks() -> bool:
	return state in def.blocking_states


func in_reach(from: Vector2i) -> bool:
	return Enums.manhattan(from, cell) <= def.reach


## True when `action` can be done in the current state.
func offers(action: ContextAction) -> bool:
	return action.requires_state == "" or action.requires_state == state
