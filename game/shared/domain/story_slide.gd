class_name StorySlide
extends Resource
## One screen of a story: a line of dialogue (or narration), who says it, and optionally a new backdrop or choices.
## Portraits stay on stage from slide to slide until replaced; the speaker is lit, the other side dimmed.

enum Stand { LEFT, RIGHT }

## Optional unique name other slides can jump to ("" = not a jump target).
@export var id: String = ""
## Who speaks. Empty = narration (no name plate, nobody lit).
@export var actor: StoryActor
@export var side: Stand = Stand.LEFT
@export_multiline var text: String = ""
## A new backdrop picture. Empty keeps the previous one.
@export var background: Texture2D
## Backdrop colour used when there is no picture (alpha 0 = keep the previous backdrop).
@export var backdrop_color: Color = Color(0, 0, 0, 0)
## Takes everyone off stage before this slide.
@export var clear_stage: bool = false
## Options for the leader. Empty = just continue; two or more = a choice.
@export var choices: Array[StoryChoice] = []
## Where to go instead of the following slide ("" = following, "end" = finish). Ignored when there are choices (each has its own).
@export var next: String = ""
