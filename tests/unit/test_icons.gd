extends TestCase
## Icons on skills, gear and items: they reach the inventory lists and the battle's buttons.


func _icon() -> ImageTexture:
	return ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGBA8))


func test_an_items_skill_takes_the_items_icon_unless_the_skill_has_its_own() -> void:
	var item := ItemDef.new()
	item.id = "potion"
	item.display_name = "Potion"
	item.icon = _icon()
	item.use = SkillDef.new()
	assert_true(item.make_skill().icon == item.icon)
	var own := load("res://icon.svg") as Texture2D # a file on disk, as a real icon is (an embedded one is copied along with the skill)
	item.use.icon = own
	assert_true(item.make_skill().icon == own)


func test_the_inventory_lists_show_gear_and_item_icons() -> void:
	var s := (load("res://game/client/screens/inventory_screen.tscn") as PackedScene).instantiate() as InventoryScreen
	(Engine.get_main_loop() as SceneTree).root.add_child(s)
	var icon := _icon()
	var gear_set := GearSet.new()
	var g := GearDef.new()
	g.id = "test_sword"
	g.display_name = "Test sword"
	g.icon = icon
	gear_set.gear = [g] as Array[GearDef]
	s._gear_set = gear_set
	var db := SkillDb.new()
	var potion := ItemDef.new()
	potion.id = "potion"
	potion.display_name = "Potion"
	potion.icon = icon
	db.items["potion"] = potion
	s._skills = db
	s.show_inventory({"gear": [{"id": "a", "gear_id": "test_sword", "place": "weapon_1"}, {"id": "b", "gear_id": "test_sword", "place": null}],
		"items": [{"item_id": "potion", "quantity": 2}], "battle_items": null})
	assert_true(s.worn_list.get_item_icon(0) == icon, "worn")
	assert_true(s.worn_list.get_item_icon(1) == null, "an empty place has none")
	assert_true(s.gear_list.get_item_icon(0) == icon, "bag")
	assert_true(s.items_list.get_item_icon(0) == icon, "consumables")
	assert_true((s.battle_box.get_child(0) as CheckBox).icon == icon, "the battle check box")
	s.queue_free()


func test_an_action_option_and_its_menu_button_carry_the_skills_icon() -> void:
	var sk := SkillDef.new()
	sk.id = "slash"
	sk.display_name = "Slash"
	sk.icon = _icon()
	var ctx := {"me": {}, "cfg": GameConfig.load_file(), "planned": [], "ap_left": 4}
	var opt := ActionOptions._option(ctx, sk, "Slash", "", 0, Vector2i(1, 1), "e")
	assert_true(opt["icon"] == sk.icon)
	var menu := (load("res://game/content/ui/action_menu.tscn") as PackedScene).instantiate() as ActionMenu
	(Engine.get_main_loop() as SceneTree).root.add_child(menu)
	menu.open([opt] as Array[Dictionary], "Test", Vector2.ZERO, Rect2(0, 0, 800, 600))
	assert_true((menu.entries.get_child(0) as Button).icon == sk.icon)
	menu.queue_free()
