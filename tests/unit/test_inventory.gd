extends TestCase
## Inventory and gear: the gear set, what a character wears, the battle's consumables and the encounter drops.


func _warrior() -> UnitTemplate:
	return load("res://game/content/stats/classes/warrior.tres") as UnitTemplate


func _character(gear: Array, extra: Dictionary = {}) -> Dictionary:
	var rows: Array = []
	for g: Array in gear:
		rows.append({"id": "row-%d" % rows.size(), "gear_id": g[0], "place": g[1]})
	return {"gear": rows}.merged(extra, true)


func test_the_gear_set_lists_every_gear_file_once_and_is_sound() -> void:
	var set := GearSet.load_file()
	assert_eq(set.problems(SkillDb.load_file()), [] as Array[String])
	var on_disk := []
	for f in DirAccess.get_files_at("res://game/content/gear"):
		if f.ends_with(".tres") and f != "gear_set.tres":
			on_disk.append(f.get_basename())
	var listed := []
	for g in set.gear:
		listed.append(g.id)
		assert_eq(g.id, (g.resource_path.get_file() as String).get_basename(), "the id is the file name")
	on_disk.sort()
	listed.sort()
	assert_eq(listed, on_disk, "every gear file is in gear_set.tres")


func test_a_character_wears_two_weapons_one_armor_and_one_accessory_at_most() -> void:
	var set := GearSet.load_file()
	var worn := set.worn(["iron_longsword", "bow", "iron_dagger", "iron_chainmail", "leather_armor", "bone_charm", "ghost_item"])
	var ids := worn.map(func(g: GearDef) -> String: return g.id)
	assert_eq(ids, ["iron_longsword", "bow", "iron_chainmail", "bone_charm"], "third weapon, second armor and unknown gear are ignored")


func test_what_is_worn_decides_armor_and_the_attack_list() -> void:
	var cfg := GameConfig.load_file()
	var skills := SkillDb.load_file()
	var b := CharacterBuild.compose(_warrior(), cfg, [], ["troll_club", "dragon_scale_vest", "bone_charm"])
	assert_eq(b["stats"]["armor"], 5, "vest 4 + charm 1")
	assert_eq(b["gear"], ["troll_club", "dragon_scale_vest", "bone_charm"] as Array[String])
	assert_true("heavy_swing" in b["skills"] and not "slash" in b["skills"], "the club's attack replaces the sword's")
	var bare := CharacterBuild.compose(_warrior(), cfg, [], [])
	assert_eq(bare["stats"]["armor"], 0)
	assert_true(not "slash" in bare["skills"])
	var start := CharacterBuild.compose(_warrior(), cfg)
	assert_eq(start["stats"]["armor"], 4, "no gear information = the class's starting gear")
	var made := Encounter.build(cfg, skills, 1, 1, ["warrior"], null, [{"flags": [], "gear": ["troll_club"]}])
	assert_true("heavy_swing" in made.state.get_c("pc0").skills)
	assert_true(not "strike" in made.state.get_c("pc0").skills, "armed, so no bare-handed fallback")
	var bare_made := Encounter.build(cfg, skills, 1, 1, ["warrior"], null, [{"flags": [], "gear": []}])
	assert_true("strike" in bare_made.state.get_c("pc0").skills, "nothing worn = bare hands")


func test_the_worn_ids_follow_the_places_not_the_order_the_api_listed_them() -> void:
	var c := _character([["iron_chainmail", "armor"], ["bow", null], ["wooden_shield", "weapon_2"], ["iron_longsword", "weapon_1"]])
	assert_eq(Loadout.worn_ids(c), ["iron_longsword", "wooden_shield", "iron_chainmail"])
	assert_eq(Loadout.worn_ids({}), [])


func test_the_players_chosen_consumables_go_in_and_nothing_else() -> void:
	var db := SkillDb.load_file()
	var held := [{"item_id": "fire_flask", "quantity": 2}, {"item_id": "health_potion", "quantity": 3}]
	assert_eq(Loadout.battle_items({"items": held}, db, 4), {"fire_flask": 2, "health_potion": 3}, "no choice = what is held")
	assert_eq(Loadout.battle_items({"items": held, "battle_items": ["health_potion"]}, db, 4), {"health_potion": 3})
	assert_eq(Loadout.battle_items({"items": held, "battle_items": []}, db, 4), {}, "chose to bring none")
	assert_eq(Loadout.battle_items({"items": held, "battle_items": ["health_potion", "fire_flask"]}, db, 1), {"health_potion": 3}, "slot limit")
	assert_eq(Loadout.battle_items({"items": held, "battle_items": ["ghost", "health_potion"]}, db, 4), {"health_potion": 3}, "unknown ignored")
	assert_eq(Loadout.battle_items({"items": [{"item_id": "health_potion", "quantity": 0}], "battle_items": ["health_potion"]}, db, 4), {})


func test_every_encounters_drops_are_sound() -> void:
	var db := SkillDb.load_file()
	var dir := "res://game/content/encounters"
	var count := 0
	for f in DirAccess.get_files_at(dir):
		if not f.ends_with(".tres"):
			continue
		var def := load("%s/%s" % [dir, f]) as EncounterDef
		assert_eq(def.problems(db), [] as Array[String], f)
		for d in def.drops:
			count += 1
			if d.is_gear():
				assert_true(GearSet.load_file().get_gear(d.gear.id) != null, "%s drops gear that is in the gear set" % f)
			else:
				assert_true(db.items.has(d.item.id), "%s drops an item the game knows" % f)
	assert_true(count > 0, "some encounter drops something")
	var bad := DropEntry.new()
	assert_true(not bad.problems().is_empty(), "a drop with neither gear nor item")


func test_drop_rolls_are_repeatable_and_follow_the_chances() -> void:
	var db := SkillDb.load_file()
	var def := EncounterDef.new()
	var always := DropEntry.new()
	always.gear = GearSet.load_file().get_gear("bone_charm")
	always.chance_percent = 100
	var never_much := DropEntry.new()
	never_much.item = db.items["health_potion"]
	never_much.chance_percent = 1
	never_much.count = 3
	def.drops = [always, never_much] as Array[DropEntry]
	var a := Loadout.roll_drops(def, "battle-x" + "char-1", db)
	assert_eq(a, Loadout.roll_drops(def, "battle-x" + "char-1", db), "the same seed gives the same loot")
	assert_eq(a["gear"], ["bone_charm"])
	var potions := 0
	for i in 400:
		potions += int(Loadout.roll_drops(def, "k%d" % i, db)["items"].get("health_potion", 0))
	assert_true(potions > 0 and potions < 60, "about 1 in 100 rolls a drop (got %d copies)" % potions)


func test_the_api_catalog_matches_the_game_content() -> void:
	var f := FileAccess.open(ContentCatalog.FILE, FileAccess.READ)
	assert_true(f != null, "services/api/app/catalog.json exists")
	if f == null:
		return
	assert_eq(f.get_as_text(), ContentCatalog.to_json(ContentCatalog.build(GameConfig.load_file())),
		"catalog.json is out of date: run  scripts/godot.sh --headless --path . --script res://tools/export_catalog.gd")


# ---------- the Inventory screen ----------

func _inventory(extra: Dictionary = {}) -> Dictionary:
	return {
		"gear": [
			{"id": "r1", "gear_id": "iron_longsword", "place": "weapon_1"},
			{"id": "r2", "gear_id": "wooden_shield", "place": "weapon_2"},
			{"id": "r3", "gear_id": "iron_chainmail", "place": "armor"},
			{"id": "r4", "gear_id": "troll_club", "place": null},
			{"id": "r5", "gear_id": "bone_charm", "place": null}],
		"items": [{"item_id": "fire_flask", "quantity": 2}, {"item_id": "health_potion", "quantity": 3}],
		"battle_items": null, "locked": false}.merged(extra, true)


func _screen() -> InventoryScreen:
	var root := (Engine.get_main_loop() as SceneTree).root
	var s := (load("res://game/client/screens/inventory_screen.tscn") as PackedScene).instantiate() as InventoryScreen
	root.add_child(s)
	return s


func test_the_inventory_screen_lists_what_is_worn_carried_and_held() -> void:
	var s := _screen()
	s.show_inventory(_inventory())
	assert_eq(s.worn_list.item_count, 4)
	assert_eq(s.worn_list.get_item_text(0), "Weapon: Iron longsword")
	assert_eq(s.worn_list.get_item_text(3), "Accessory: (empty)")
	assert_eq(s.gear_list.item_count, 2)
	assert_eq(s.gear_list.get_item_text(0), "Troll club")
	assert_eq(s.items_list.get_item_text(1), "Health potion x3")
	s.gear_list.select(0)
	s.gear_list.item_selected.emit(0)
	assert_true("Heavy swing" in s.details.text, "the details name what the gear lets you use")
	s.free()


func test_equip_unequip_and_discard_report_the_row_and_place() -> void:
	var s := _screen()
	var got: Array = []
	s.equip_requested.connect(func(row: String, place: String) -> void: got.append(["equip", row, place]))
	s.unequip_requested.connect(func(row: String) -> void: got.append(["unequip", row]))
	s.discard_gear_requested.connect(func(row: String) -> void: got.append(["discard", row]))
	s.discard_item_requested.connect(func(id: String) -> void: got.append(["throw", id]))
	s.show_inventory(_inventory())
	assert_true(s.equip_button.disabled and s.unequip_button.disabled, "nothing selected yet")
	s.gear_list.select(0)
	s.gear_list.item_selected.emit(0)
	assert_eq(s.place_option.item_count, 2, "a weapon can go in either hand")
	s.place_option.select(1)
	s.equip_button.pressed.emit()
	s.discard_button.pressed.emit()
	s.worn_list.select(2)
	s.worn_list.item_selected.emit(2)
	s.unequip_button.pressed.emit()
	s.items_list.select(0)
	s.items_list.item_selected.emit(0)
	s.discard_item_button.pressed.emit()
	assert_eq(got, [["equip", "r4", "weapon_2"], ["discard", "r4"], ["unequip", "r3"], ["throw", "fire_flask"]])
	s.gear_list.select(1)
	s.gear_list.item_selected.emit(1)
	assert_eq(s.place_option.item_count, 1, "an accessory has one place")
	s.free()


func test_a_locked_bag_cannot_be_changed() -> void:
	var s := _screen()
	s.show_inventory(_inventory({"locked": true}))
	s.gear_list.select(0)
	s.gear_list.item_selected.emit(0)
	assert_true(s.equip_button.disabled and s.discard_button.disabled)
	assert_true(s.status_label.text != "", "it says why")
	s.free()


func test_the_battle_items_are_chosen_by_ticking_kinds_up_to_the_slots() -> void:
	var s := _screen()
	var got: Array = []
	s.battle_items_changed.connect(func(kinds: Variant) -> void: got.append(kinds))
	s.show_inventory(_inventory())
	assert_true(s.auto_check.button_pressed, "automatic until the player chooses")
	s.auto_check.button_pressed = false
	assert_eq(got.back(), [] as Array[String], "choosing by hand starts from nothing")
	var box := s.battle_box.get_child(1) as CheckBox
	box.button_pressed = true
	assert_eq(got.back(), ["health_potion"] as Array[String])
	s.auto_check.button_pressed = true
	assert_eq(got.back(), null)
	s.show_inventory(_inventory({"battle_items": ["fire_flask"]}))
	assert_true(not s.auto_check.button_pressed and (s.battle_box.get_child(0) as CheckBox).button_pressed, "shows the saved choice")
	s.free()
