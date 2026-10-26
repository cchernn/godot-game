class_name MenuBackground
extends Control
## The animated backdrop behind the menu screens (sign-in, worlds, hub, map). All of the art and the motion are in
## game/content/ui/menu_background.tscn: edit the layers and the "drift" animation in the editor, or swap them for your own
## art. The client shows it while the player is in the menus and hides it (and stops the animation) in a battle.

@onready var _animation: AnimationPlayer = %AnimationPlayer


## True shows the backdrop and plays it; false hides it and pauses it so a battle gets every frame.
func set_playing(on: bool) -> void:
	visible = on
	if on:
		_animation.play(_animation.autoplay if _animation.autoplay != "" else "drift")
	else:
		_animation.pause()
