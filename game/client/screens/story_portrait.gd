class_name StoryPortrait
extends Control
## One standing character on the story screen (screens/story_portrait.tscn). Shows the actor's painted portrait, or a coloured
## silhouette until there is one. Restyle the scene freely: the script only needs the nodes named below.

@export var picture: TextureRect
@export var silhouette: Control
@export var name_label: Label
## How bright the speaker is lit and how dark everyone else gets.
@export_range(0.0, 1.0) var dim_brightness: float = 0.45


## `actor` null empties the spot. `lit` is true for the current speaker.
func show_actor(actor: StoryActor, lit: bool) -> void:
	visible = actor != null
	if actor == null:
		return
	var tint := Color(1, 1, 1) if lit else Color(dim_brightness, dim_brightness, dim_brightness)
	picture.texture = actor.portrait
	picture.visible = actor.portrait != null
	silhouette.visible = actor.portrait == null
	picture.modulate = tint
	silhouette.modulate = actor.color * tint
	if name_label != null:
		name_label.text = actor.display_name
