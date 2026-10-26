class_name StatusLine
extends RefCounted
## The one-line message area (errors, "Request sent"...). The menu panel shows it under its screens; the game view shows it as a
## bar over the map. Writing `text` updates whichever is on screen, so the flow's code does not care which view it is in.

var menu: Label
var toast_box: Control
var toast_label: Label

var text: String:
	get:
		return menu.text if menu != null else ""
	set(value):
		if menu != null:
			menu.text = value
		if toast_label != null:
			toast_label.text = value
		if toast_box != null:
			toast_box.visible = value != ""
