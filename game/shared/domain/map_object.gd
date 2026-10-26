@tool
class_name MapObject
extends Marker3D
## A map object placed in the editor: add game/content/objects/map_object.tscn under the map scene's Objects node, name it (the name is
## its id: lower-case letters, digits and underscores), move it onto a tile and assign its definition. The server and the client both
## read it from the map scene.

@export var def: ContextObjectDef
## Optional Label3D that shows the object's name and state during a battle.
@export var state_label: Label3D


func show_state(state: String) -> void:
	if state_label != null:
		state_label.text = "%s\n(%s)" % [def.display_name if def != null else name, state]
