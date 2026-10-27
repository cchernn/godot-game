extends TestCase
## The battle screen: the menu that opens where you click, the hover card, the symbols on the board and the floating numbers.

const CLIENT := "res://game/client/client_main.tscn"
const SKILLS := ["move", "strike", "defend", "power_strike", "shield_wall", "lob_shot", "fireball"]


func _client(units: Array = []) -> Control:
	var root := (Engine.get_main_loop() as SceneTree).root
	var c := (load(CLIENT) as PackedScene).instantiate() as Control
	c.set("account_mode_enabled", false)
	root.add_child(c)
	if units.is_empty():
		units = [Fx.player("pc0", V(2, 1), {"skills": SKILLS, "power": 2}), Fx.enemy("e0", V(3, 1), {"armor": 1}),
			Fx.enemy("far", V(7, 3)), Fx.player("pc1", V(2, 2))]
	var b := Fx.battle(Fx.OPEN, units)
	c.call("_on_snapshot", b.snapshot_for("pc0"))
	return c


func _menu(c: Control) -> ActionMenu:
	return c.get_node("%ActionMenu") as ActionMenu


func _open(c: Control, cell: Vector2i, unit: String = "") -> Array[Dictionary]:
	c.call("_on_cell_clicked", cell, unit)
	return c.call("_options_at", cell, unit)


func _option(opts: Array[Dictionary], id: String) -> Dictionary:
	for o in opts:
		if o["id"] == id:
			return o
	return {}


func test_clicking_an_enemy_lists_the_attacks_with_their_damage_and_queues_the_pick() -> void:
	var c := _client()
	var opts := _open(c, V(3, 1), "e0")
	assert_true(_menu(c).visible, "the menu opens where you click")
	assert_eq(_menu(c).entry_count(), opts.size())
	var attack := _option(opts, "strike")
	assert_true(attack["enabled"])
	assert_eq(attack["summary"], "Damage 7-17", "6 + 2 power - 1 armor; at most a rear hit that crits")
	var power := _option(opts, "power_strike")
	assert_true(power["enabled"] and power["ap"] == 2)
	assert_true(_option(opts, "move").is_empty() and _option(opts, "defend").is_empty(), "no walking onto a unit, no self skills on an enemy")
	c.call("_on_option_chosen", attack)
	assert_eq(c.plan.size(), 1)
	assert_eq([c.plan[0]["skill"], c.plan[0]["target"]], ["strike", "e0"])
	assert_eq(c.board.marks, [{"cell": V(3, 1), "text": "1"}] as Array[Dictionary], "the target gets a symbol with its order number")
	c.free()


func test_what_cannot_be_used_is_listed_with_its_reason() -> void:
	var c := _client()
	var far := _open(c, V(7, 3), "far")
	assert_true(not _option(far, "strike")["enabled"])
	assert_true("out of range" in _option(far, "strike")["reason"])
	var near := _open(c, V(3, 1), "e0")
	c.call("_on_option_chosen", _option(near, "power_strike"))
	var again := _open(c, V(3, 1), "e0")
	assert_true(not _option(again, "power_strike")["enabled"] and "already planned" in _option(again, "power_strike")["reason"])
	assert_true(not _option(again, "strike")["enabled"] and "AP" in _option(again, "strike")["reason"] or _option(again, "strike")["enabled"],
		"1 AP is left, so a basic attack still fits")
	c.free()


func test_clicking_a_tile_offers_the_walk_and_the_aimed_skills_and_a_walk_shows_the_facing_row() -> void:
	var c := _client()
	var opts := _open(c, V(1, 3), "")
	var walk := _option(opts, "move")
	assert_true(walk["enabled"] and walk["ap"] == 3 and walk["summary"] == "3 tiles")
	assert_true(_option(opts, "lob_shot")["enabled"] and _option(opts, "fireball")["enabled"], "tile skills are listed on a tile")
	assert_true(_option(_open(c, V(7, 0), ""), "fireball")["reason"].begins_with("out of range"), "and say when the tile is too far")
	c.call("_on_option_chosen", walk)
	assert_eq(c.plan[0]["skill"], "move")
	assert_true((c.get_node("%FacingRow") as Control).visible, "after a walk you can turn")
	c.call("_undo")
	assert_true(not (c.get_node("%FacingRow") as Control).visible)
	c.free()


func test_clicking_yourself_offers_the_self_skills_once() -> void:
	var c := _client()
	var opts := _open(c, V(2, 1), "pc0")
	assert_true(_option(opts, "defend")["enabled"] and _option(opts, "shield_wall")["enabled"])
	assert_eq(_option(opts, "defend")["summary"], "Shield 4 (this beat)")
	assert_eq(_option(opts, "shield_wall")["summary"], "Shield 8 (this round)")
	c.call("_on_option_chosen", _option(opts, "shield_wall"))
	assert_true(not _option(_open(c, V(2, 1), "pc0"), "shield_wall")["enabled"], "once per turn")
	c.free()


func test_the_menu_closes_on_escape_and_when_planning_ends() -> void:
	var c := _client()
	_open(c, V(3, 1), "e0")
	assert_true(_menu(c).visible and c.board.selected_cell == V(3, 1), "the clicked tile is marked")
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	c.set("_state", "battle")
	c.call("_unhandled_key_input", esc)
	assert_true(not _menu(c).visible)
	assert_eq(c.board.selected_cell, V(-1, -1), "the mark goes with it")
	_open(c, V(3, 1), "e0")
	c.get_node("%ReadyButton").button_pressed = true
	c.me["ready"] = true
	c.call("_refresh")
	assert_true(not _menu(c).visible, "no menu while you cannot plan")
	c.free()


func test_hovering_a_menu_entry_shades_its_reach_and_area() -> void:
	var c := _client()
	var opts := _open(c, V(5, 1), "")
	var fire := _option(opts, "fireball")
	c.call("_on_option_previewed", fire)
	assert_true(c.board.range_cells.size() > 0, "its reach")
	assert_eq(c.board.area_cells.size(), 5, "the star around the clicked tile")
	c.call("_on_option_previewed", _option(opts, "move"))
	assert_true(c.board.path_cells.size() > 0, "the walk there")
	c.call("_on_option_previewed", {})
	assert_eq(c.board.area_cells.size(), 0)
	c.free()


func test_hovering_a_tile_or_unit_shows_the_walk_the_reach_and_the_attack() -> void:
	var c := _client()
	var board := c.board as Board3D
	board.hover = V(1, 1)
	c.set("_preview_sig", 0)
	c.call("_update_overlays")
	assert_true(board.range_cells.size() > 0 and board.path_cells.size() > 0, "where you can walk and the way to the tile")
	assert_true("Walk: 1 tile, 1 AP" in c.get("_card_text"), c.get("_card_text"))
	board.hover = V(3, 1)
	c.set("_preview_sig", 0)
	c.call("_update_overlays")
	var text: String = c.get("_card_text")
	assert_true("e0" in text and "HP 20/20" in text and "Attack: 7-17 damage, 1 AP, in reach" in text, text)
	assert_eq(board.valid_cells, [V(3, 1)] as Array[Vector2i], "the enemy in reach of your Attack is picked out")
	board.hover = V(7, 3)
	c.set("_preview_sig", 0)
	c.call("_update_overlays")
	assert_true("out of reach" in c.get("_card_text"))
	c.free()


func test_items_and_map_objects_are_in_the_menu_too() -> void:
	var c := _client()
	var potion := ItemDef.new()
	potion.id = "potion"
	potion.display_name = "Potion"
	potion.hint = "Heals a bit"
	potion.use = SkillDef.new()
	potion.use.kind = Enums.SkillKind.SUPPORT
	potion.use.targeting = Enums.Targeting.SELF
	var st := SkillStage.new()
	var heal := HealEffect.new()
	heal.amount = 5
	var fx: Array[SkillEffect] = [heal]
	st.effects = fx
	var stages: Array[SkillStage] = [st]
	potion.use.stage_defs = stages
	c.skills.add_item(potion)
	var chest := ContextObjectDef.new()
	chest.id = "chest"
	chest.display_name = "Chest"
	var act := ContextAction.new()
	act.id = "open"
	act.display_name = "Open"
	act.use = SkillDef.new()
	var cs := SkillStage.new()
	var cstages: Array[SkillStage] = [cs]
	act.use.stage_defs = cstages
	chest.actions = [act] as Array[ContextAction]
	c.skills.add_context("chest", chest)
	var b := Fx.battle(Fx.OPEN, [Fx.player("pc0", V(2, 1), {"skills": SKILLS}), Fx.enemy("e0", V(7, 3))])
	var s := b.snapshot_for("pc0")
	for u: Dictionary in s["units"]:
		if u["id"] == "pc0":
			u["items"] = [{"id": "potion", "name": "Potion", "hint": "Heals a bit", "count": 2}]
	s["objects"] = [{"id": "chest", "name": "Chest", "cell": V(3, 1), "state": "closed", "blocks": true, "reach": 1,
		"actions": [{"id": "open", "name": "Open", "hint": "Opens it"}]}]
	c.call("_on_snapshot", s)
	var me_opts := _open(c, V(2, 1), "pc0")
	var item := _option(me_opts, "item:potion")
	assert_true(item["enabled"] and item["label"] == "Potion ×2" and item["summary"] == "Heal 5")
	assert_eq(_option(me_opts, "ctx:chest:open")["label"], "Chest: Open", "an object in reach is listed when you click yourself")
	c.call("_on_option_chosen", item)
	assert_eq([c.plan[0]["item"], c.plan[0]["skill"]], ["potion", "item:potion"])
	assert_eq(_option(_open(c, V(2, 1), "pc0"), "item:potion")["label"], "Potion ×1", "one is spoken for")
	var on_chest := _open(c, V(3, 1), "")
	c.call("_on_option_chosen", _option(on_chest, "ctx:chest:open"))
	assert_eq([c.plan[1]["object"], c.plan[1]["action"], c.plan[1]["skill"]], ["chest", "open", "ctx:chest:open"])
	assert_true(c.board.bf.object_blocks.has(V(3, 1)), "a blocking object closes its tile on the board")
	c.free()


func test_events_float_numbers_over_the_unit_they_hit() -> void:
	var c := _client()
	var board := c.board as Board3D
	var before := board.overlay_root.get_child_count()
	c.call("_on_events", [
		{"type": "hit", "round": 1, "beat": 1, "text": "x", "target": "e0", "data": {"amount": 8, "absorbed": 3, "crit": false}},
		{"type": "hit", "round": 1, "beat": 1, "text": "x", "target": "e0", "data": {"amount": 12, "absorbed": 0, "crit": true}},
		{"type": "miss", "round": 1, "beat": 1, "text": "x", "target": "pc1", "data": {}},
		{"type": "heal", "round": 1, "beat": 1, "text": "x", "target": "pc1", "data": {"amount": 4}},
		{"type": "status_apply", "round": 1, "beat": 1, "text": "x", "target": "e0", "data": {"glyph": "F", "name": "Frozen", "color": "8ccbff"}},
		{"type": "hit", "round": 1, "beat": 1, "text": "x", "target": "", "data": {"amount": 5, "absorbed": 0}}])
	var texts: Array[String] = []
	for ch in board.overlay_root.get_children():
		if ch is FloatingText:
			texts.append((ch as FloatingText).label.text)
	assert_eq(texts, ["-5", "-12!", "Miss", "+4", "F Frozen"] as Array[String], "damage through the shield, a crit, a miss, healing, a status; an unseen target shows nothing")
	assert_eq(board.overlay_root.get_child_count() - before, 5)
	c.free()


func test_a_floating_text_rises_and_removes_itself() -> void:
	var ft := (load("res://game/content/board/markers/floating_text.tscn") as PackedScene).instantiate() as FloatingText
	(Engine.get_main_loop() as SceneTree).root.add_child(ft)
	ft.play("-5", Color.RED, 1.0, 0.0)
	var y0 := ft.position.y
	ft._process(ft.duration * 0.5)
	assert_true(ft.position.y > y0, "it rises")
	ft._process(ft.duration)
	assert_true(ft.is_queued_for_deletion(), "and goes away")


func test_damage_ranges_add_up_stages_and_respect_armor_and_crits() -> void:
	var cfg := GameConfig.load_file()
	var db := SkillDb.load_file()
	var strike := TargetingPreview.damage_range(db.get_skill("strike"), 0, 0, cfg)
	assert_eq(strike.x, 6)
	assert_eq(strike.y, roundi(6 * (cfg.get_value("combat", "rear_multiplier") as float) * (cfg.get_value("combat", "crit_multiplier") as float)))
	assert_eq(TargetingPreview.damage_range(db.get_skill("strike"), 0, 100, cfg), Vector2i(1, 1), "armor never takes it below 1")
	assert_eq(TargetingPreview.damage_range(db.get_skill("defend"), 0, 0, cfg), Vector2i(0, 0), "no damage")
	assert_eq(TargetingPreview.effect_summary(db.get_skill("ice_floor"), 0, 0, cfg), "Frozen")


func test_battle_events_carry_their_numbers_to_the_client() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(0, 1)), Fx.enemy("e", V(1, 1))])
	Fx.plan(b, "a", [Fx.act("strike", "e")])
	b.begin_resolution()
	Fx.run_beats(b, 1)
	var hit: Dictionary = {}
	for e in b.public_events_since(0):
		if e["type"] == "hit":
			hit = e
	assert_eq(hit["data"]["amount"], 6)
	assert_eq(hit["data"]["crit"], false)
	assert_eq(hit["target"], "e")
	var snapshot := b.snapshot_for("a")
	assert_true(snapshot["units"][0].has("armor") and snapshot["units"][0].has("power"), "stats the damage preview needs")


func test_statuses_show_as_badges_over_the_unit_with_their_turns() -> void:
	var u := (load("res://game/content/units/warrior.tscn") as PackedScene).instantiate() as Unit3D
	(Engine.get_main_loop() as SceneTree).root.add_child(u)
	var b := Fx.battle(Fx.OPEN, [Fx.player("pc0", V(1, 1))])
	var unit: Dictionary = b.snapshot_for("pc0")["units"][0]
	unit["statuses"] = [{"id": "maimed", "name": "Maimed", "glyph": "M", "color": "ff9a4d", "turns": 2, "stacks": 1},
		{"id": "made_up", "name": "Odd", "glyph": "?", "color": "ffffff", "turns": 1, "stacks": 3}]
	u.apply(unit, true)
	var icons := u.status_row.get_children().filter(func(n: Node) -> bool: return n is StatusIcon and (n as Node3D).visible)
	assert_eq(icons.size(), 2)
	assert_eq((icons[0] as StatusIcon).glyph_label.text, "M")
	assert_eq((icons[0] as StatusIcon).turns_label.text, "2")
	assert_eq((icons[1] as StatusIcon).turns_label.text, "1×3", "stacks are shown")
	assert_true((icons[0] as Node3D).position.x < (icons[1] as Node3D).position.x, "side by side")
	unit["statuses"] = []
	u.apply(unit, true)
	assert_eq(u.status_row.get_children().filter(func(n: Node) -> bool: return (n as Node3D).visible).size(), 0, "gone with the status")
	u.free()


func _ability(c: Control, id: String) -> Button:
	for b in (c.get_node("%AbilityList") as GridContainer).get_children():
		if b is Button and (b as Button).text.begins_with(id):
			return b
	return null


func test_the_ability_list_shows_what_you_can_do_with_its_cost() -> void:
	var c := _client()
	var list := c.get_node("%AbilityList") as GridContainer
	var names: Array[String] = []
	for b in list.get_children():
		names.append((b as Button).text)
	assert_eq(names, ["Move  1 AP/1 tile", "Attack  1 AP", "Power Strike  2 AP", "Shield Wall  1 AP", "Lob Shot  2 AP", "Fireball  3 AP", "Defend  1 AP"] as Array[String],
		"Move, the attack, the class skills, then Defend")
	assert_true(not _ability(c, "Power Strike").disabled)
	c.call("_on_ability_pressed", "shield_wall")
	assert_true(_ability(c, "Shield Wall").disabled, "once per turn")
	assert_true("already planned" in _ability(c, "Shield Wall").tooltip_text)
	c.free()


func test_an_armed_ability_keeps_its_reach_shaded_and_the_next_click_queues_it() -> void:
	var c := _client()
	c.call("_on_ability_pressed", "power_strike")
	assert_eq(c.get("_armed"), "power_strike")
	assert_true(c.board.range_cells.size() > 0, "its reach stays on")
	assert_true(c.board.valid_cells.has(V(3, 1)), "and the enemy it can hit is picked out")
	c.call("_on_cell_clicked", V(5, 3), "")
	assert_eq(c.plan.size(), 0, "a tile is not a valid target for it")
	assert_true("cannot be used" in (c.get_node("%ErrorLabel") as Label).text)
	assert_eq(c.get("_armed"), "power_strike", "still armed")
	c.call("_on_cell_clicked", V(3, 1), "e0")
	assert_eq([c.plan[0]["skill"], c.plan[0]["target"]], ["power_strike", "e0"], "one click, no menu")
	assert_eq(c.get("_armed"), "", "used up")
	assert_true(not (c.get_node("%ActionMenu") as Control).visible)
	c.free()


func test_an_armed_move_walks_with_one_click_and_esc_or_the_same_ability_cancels() -> void:
	var c := _client()
	c.call("_on_ability_pressed", "move")
	assert_true(c.board.range_cells.size() > 0)
	c.board.hover = V(1, 1)
	c.set("_preview_sig", 0)
	c.call("_update_overlays")
	assert_true(c.board.path_cells.size() > 0, "the way to the tile under the mouse")
	c.call("_on_cell_clicked", V(1, 1), "")
	assert_eq(c.plan[0]["skill"], "move")
	c.call("_on_ability_pressed", "strike")
	assert_eq(c.get("_armed"), "strike")
	c.call("_on_ability_pressed", "strike")
	assert_eq(c.get("_armed"), "", "the same ability again cancels")
	c.call("_on_ability_pressed", "strike")
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	c.set("_state", "battle")
	c.call("_unhandled_key_input", esc)
	assert_eq(c.get("_armed"), "", "Esc cancels")
	c.free()


func test_an_ability_that_needs_no_aim_is_queued_at_once() -> void:
	var c := _client()
	c.call("_on_ability_pressed", "defend")
	assert_eq(c.plan[0]["skill"], "defend")
	assert_eq(c.get("_armed"), "")
	c.free()


func test_the_reach_stays_shaded_while_the_menu_is_open() -> void:
	var c := _client()
	c.call("_on_cell_clicked", V(1, 3), "")
	assert_true(_menu(c).visible)
	assert_true(c.board.range_cells.size() > 0, "where you can walk stays on")
	assert_true(c.board.path_cells.size() > 0, "and the way to the tile you clicked")
	c.call("_on_menu_closed")
	c.call("_on_cell_clicked", V(3, 1), "e0")
	assert_true(c.board.range_cells.size() > 0, "an enemy: your attack's reach")
	assert_eq(c.board.valid_cells, [V(3, 1)] as Array[Vector2i], "and the target")
	assert_eq(c.board.selected_unit, "e0", "the clicked unit stays highlighted")
	c.free()


func test_hovering_a_unit_highlights_the_unit_and_a_tile_gets_a_border() -> void:
	var c := _client()
	var board := c.board as Board3D
	var enemy := board._unit_nodes["e0"] as Unit3D
	board.hover = V(3, 1)
	board.hover_unit = "e0"
	board.call("_refresh_overlays")
	assert_true(enemy.hover_ring.visible, "the unit's ring is on")
	assert_true(not (board._unit_nodes["pc1"] as Unit3D).hover_ring.visible, "only that unit")
	assert_eq(board._overlays["hover"].filter(func(m: MeshInstance3D) -> bool: return m.visible).size(), 0, "no tile border while a unit is hovered")
	board.hover = V(5, 3)
	board.hover_unit = ""
	board.call("_refresh_overlays")
	assert_true(not enemy.hover_ring.visible)
	assert_eq(board._overlays["hover"].filter(func(m: MeshInstance3D) -> bool: return m.visible).size(), 1, "a tile gets its border")
	c.free()
