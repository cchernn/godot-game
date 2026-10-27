class_name HoverCard
extends PanelContainer
## A small card that follows the mouse over the board and says what is under it (see game/content/ui/hover_card.tscn).

@export var text_label: RichTextLabel
@export var edge_margin: float = 8.0
@export var cursor_offset: Vector2 = Vector2(18, 18)


## Shows `bbcode` near `at`, kept inside `bounds`.
func show_card(bbcode: String, at: Vector2, bounds: Rect2) -> void:
	if bbcode == "":
		hide()
		return
	text_label.text = bbcode
	show()
	reset_size()
	var sz := get_combined_minimum_size()
	var pos := at + cursor_offset
	if pos.x + sz.x > bounds.end.x - edge_margin:
		pos.x = at.x - cursor_offset.x - sz.x # flip to the other side of the cursor
	if pos.y + sz.y > bounds.end.y - edge_margin:
		pos.y = at.y - cursor_offset.y - sz.y
	position = Vector2(maxf(bounds.position.x + edge_margin, pos.x), maxf(bounds.position.y + edge_margin, pos.y))
