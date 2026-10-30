class_name InventoryScreen
extends VBoxContainer
## Your bag: what you wear, the gear you carry, the consumables you carry and which of those you bring into a battle. It only shows what
## the API says (show_inventory) and reports what the player asked for; the coordinator calls the API and feeds the answer back.
## The layout is game/client/screens/inventory_screen.tscn.

signal equip_requested(gear_row: String, place: String)
signal unequip_requested(gear_row: String)
signal discard_gear_requested(gear_row: String)
signal discard_item_requested(item_id: String)
## The kinds to bring (in the order shown), or null to let the game choose.
signal battle_items_changed(kinds: Variant)

const PLACE_TITLES := {"weapon_1": "Weapon", "weapon_2": "Weapon", "armor": "Armor", "accessory": "Accessory"}

var _inv: Dictionary = {}
var _gear_set: GearSet
var _skills: SkillDb
## Row index -> the API's gear row id (or "" for an empty slot / consumable), per list.
var _worn_rows: Array[String] = []
var _bag_rows: Array[String] = []
var _item_rows: Array[String] = []
var _slots: int = 4

@onready var status_label: Label = %InventoryStatusLabel
@onready var worn_list: ItemList = %WornList
@onready var gear_list: ItemList = %GearBagList
@onready var items_list: ItemList = %ConsumablesList
@onready var details: Label = %InventoryDetailsLabel
@onready var place_option: OptionButton = %PlaceOption
@onready var equip_button: Button = %EquipButton
@onready var unequip_button: Button = %UnequipButton
@onready var discard_button: Button = %DiscardGearButton
@onready var discard_item_button: Button = %DiscardItemButton
@onready var battle_title: Label = %BattleItemsTitle
@onready var auto_check: CheckBox = %AutoItemsCheck
@onready var battle_box: VBoxContainer = %BattleItemsBox


func _ready() -> void:
	_gear_set = GearSet.load_file()
	_skills = SkillDb.load_file()
	_slots = int(GameConfig.load_file().get_value("items", "battle_slots"))
	worn_list.item_selected.connect(_on_worn_selected)
	gear_list.item_selected.connect(_on_bag_selected)
	items_list.item_selected.connect(_on_item_selected)
	equip_button.pressed.connect(_on_equip)
	unequip_button.pressed.connect(func() -> void:
		var row := _selected_row(worn_list, _worn_rows)
		if row != "":
			unequip_requested.emit(row))
	discard_button.pressed.connect(func() -> void:
		var row := _selected_row(gear_list, _bag_rows)
		if row != "":
			discard_gear_requested.emit(row))
	discard_item_button.pressed.connect(func() -> void:
		var id := _selected_row(items_list, _item_rows)
		if id != "":
			discard_item_requested.emit(id))
	auto_check.toggled.connect(func(_on: bool) -> void:
		_sync_battle_boxes()
		_emit_battle_items())
	_sync_buttons()


## Shows the loading state while the API answers.
func show_checking() -> void:
	status_label.text = "Loading your bag…"


## inv: the API's inventory {gear: [{id, gear_id, place}], items: [{item_id, quantity}], battle_items: null|[ids], locked: bool}.
func show_inventory(inv: Dictionary) -> void:
	var keep_worn := _selected_row(worn_list, _worn_rows)
	var keep_bag := _selected_row(gear_list, _bag_rows)
	var keep_item := _selected_row(items_list, _item_rows)
	_inv = inv
	status_label.text = "Finish or leave your activity before changing your bag." if inv.get("locked", false) else ""
	_fill_worn(keep_worn)
	_fill_bag(keep_bag)
	_fill_items(keep_item)
	_fill_battle_items()
	details.text = ""
	_sync_buttons()


func show_error(text: String) -> void:
	status_label.text = text


func _fill_worn(keep: String) -> void:
	worn_list.clear()
	_worn_rows.clear()
	var by_place := {}
	for g: Dictionary in _inv.get("gear", []):
		if g.get("place") != null:
			by_place[str(g["place"])] = g
	for place in GearDef.WORN_PLACES:
		var title: String = PLACE_TITLES[place]
		if by_place.has(place):
			var g: Dictionary = by_place[place]
			worn_list.add_item("%s: %s" % [title, _name_of(str(g["gear_id"]))])
			_worn_rows.append(str(g["id"]))
		else:
			worn_list.add_item("%s: (empty)" % title)
			_worn_rows.append("")
		if _worn_rows.back() == keep and keep != "":
			worn_list.select(worn_list.item_count - 1)


func _fill_bag(keep: String) -> void:
	gear_list.clear()
	_bag_rows.clear()
	for g: Dictionary in _inv.get("gear", []):
		if g.get("place") == null:
			gear_list.add_item(_name_of(str(g["gear_id"])))
			_bag_rows.append(str(g["id"]))
			if str(g["id"]) == keep:
				gear_list.select(gear_list.item_count - 1)


func _fill_items(keep: String) -> void:
	items_list.clear()
	_item_rows.clear()
	for it: Dictionary in _inv.get("items", []):
		var id := str(it["item_id"])
		items_list.add_item("%s x%d" % [_item_name(id), int(it["quantity"])])
		_item_rows.append(id)
		if id == keep:
			items_list.select(items_list.item_count - 1)


## One check box per kind of consumable held: ticked = brought into the battle. "Choose for me" ticks nothing by hand.
func _fill_battle_items() -> void:
	for c in battle_box.get_children():
		battle_box.remove_child(c)
		c.queue_free()
	var chosen: Variant = _inv.get("battle_items")
	auto_check.set_pressed_no_signal(not chosen is Array)
	battle_title.text = "Take into battle (up to %d kinds)" % _slots
	for it: Dictionary in _inv.get("items", []):
		var id := str(it["item_id"])
		var box := CheckBox.new()
		box.text = _item_name(id)
		box.set_meta("item_id", id)
		box.set_pressed_no_signal(chosen is Array and (chosen as Array).has(id))
		box.toggled.connect(func(_on: bool) -> void:
			_enforce_slots(box)
			_emit_battle_items())
		battle_box.add_child(box)
	_sync_battle_boxes()


func _sync_battle_boxes() -> void:
	var locked: bool = _inv.get("locked", false)
	for box: CheckBox in battle_box.get_children():
		box.disabled = auto_check.button_pressed or locked
	auto_check.disabled = locked


## Ticking more than the battle takes un-ticks the box just ticked.
func _enforce_slots(changed: CheckBox) -> void:
	if _ticked().size() > _slots:
		changed.set_pressed_no_signal(false)
		status_label.text = "A battle takes at most %d kinds of item." % _slots


func _ticked() -> Array[String]:
	var out: Array[String] = []
	for box: CheckBox in battle_box.get_children():
		if box.button_pressed:
			out.append(str(box.get_meta("item_id")))
	return out


func _emit_battle_items() -> void:
	battle_items_changed.emit(null if auto_check.button_pressed else _ticked())


# ---------- selection ----------

func _selected_row(list: ItemList, rows: Array[String]) -> String:
	var sel := list.get_selected_items()
	return rows[sel[0]] if not sel.is_empty() and sel[0] < rows.size() else ""


func _on_worn_selected(i: int) -> void:
	gear_list.deselect_all()
	items_list.deselect_all()
	details.text = _gear_text(_gear_id_of(_worn_rows[i])) if _worn_rows[i] != "" else "Nothing in this place."
	_sync_buttons()


func _on_bag_selected(i: int) -> void:
	worn_list.deselect_all()
	items_list.deselect_all()
	var gear_id := _gear_id_of(_bag_rows[i])
	details.text = _gear_text(gear_id)
	place_option.clear()
	var g := _gear_set.get_gear(gear_id)
	if g != null:
		for place in GearDef.WORN_PLACES:
			if GearDef.place_slot(place) == g.slot:
				place_option.add_item(("Left/first hand" if place == "weapon_1" else "Second hand") if g.slot == GearDef.Slot.WEAPON else "Wear",
					GearDef.WORN_PLACES.find(place))
	_sync_buttons()


func _on_item_selected(i: int) -> void:
	worn_list.deselect_all()
	gear_list.deselect_all()
	var def: ItemDef = _skills.items.get(_item_rows[i])
	details.text = ("%s\n%s" % [def.display_name, def.hint]) if def != null else _item_rows[i]
	_sync_buttons()


func _on_equip() -> void:
	var row := _selected_row(gear_list, _bag_rows)
	if row == "" or place_option.item_count == 0:
		return
	equip_requested.emit(row, GearDef.WORN_PLACES[place_option.get_selected_id()])


func _sync_buttons() -> void:
	var locked: bool = _inv.get("locked", false)
	var bag_pick := _selected_row(gear_list, _bag_rows) != ""
	equip_button.disabled = locked or not bag_pick
	discard_button.disabled = locked or not bag_pick
	place_option.disabled = locked or not bag_pick
	place_option.visible = bag_pick and place_option.item_count > 1
	unequip_button.disabled = locked or _selected_row(worn_list, _worn_rows) == ""
	discard_item_button.disabled = locked or _selected_row(items_list, _item_rows) == ""


# ---------- names ----------

func _gear_id_of(row: String) -> String:
	for g: Dictionary in _inv.get("gear", []):
		if str(g["id"]) == row:
			return str(g["gear_id"])
	return ""


func _name_of(gear_id: String) -> String:
	var g := _gear_set.get_gear(gear_id) if _gear_set != null else null
	return g.display_name if g != null else gear_id.replace("_", " ")


func _item_name(id: String) -> String:
	var def: ItemDef = _skills.items.get(id) if _skills != null else null
	return def.display_name if def != null else id.replace("_", " ")


## Name, what it is, the armor it gives and the attacks it lets you use.
func _gear_text(gear_id: String) -> String:
	var g := _gear_set.get_gear(gear_id)
	if g == null:
		return gear_id.replace("_", " ")
	var lines: Array[String] = [g.display_name, g.description]
	if g.armor > 0:
		lines.append("Armor +%d" % g.armor)
	var granted: Array[String] = []
	for sk in g.grants:
		granted.append(sk.display_name)
	if not granted.is_empty():
		lines.append("Lets you use: %s" % ", ".join(granted))
	return "\n".join(lines)
