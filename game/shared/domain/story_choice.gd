class_name StoryChoice
extends Resource
## One option on a slide. The party leader picks it for everyone.

## Lower-case id with no spaces. An event step routes on this id of the story's last choice (template: the step's choices[].id).
@export var id: String = ""
## What the player reads.
@export var text: String = ""
## The slide to go to ("" = the following slide, "end" = finish the story).
@export var next: String = ""
