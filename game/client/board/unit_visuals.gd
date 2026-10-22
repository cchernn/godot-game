class_name UnitVisuals
extends Resource
## Maps a unit's visual id (the class or enemy template, lower-case: "warrior", "ghoul"...) to the
## scene that draws it. Edit this resource in the Inspector to give each one its own model.

@export var default_scene: PackedScene
@export var scenes: Dictionary[String, PackedScene] = {}


func scene_for(visual: String) -> PackedScene:
	var s: PackedScene = scenes.get(visual)
	return s if s != null else default_scene
