extends TestCase

func test_ap_capacity_milestones_and_cap() -> void:
	var cfg := GameConfig.load_file()
	assert_eq(cfg.ap_capacity(8), 3)
	assert_eq(cfg.ap_capacity(10), 4)
	assert_eq(cfg.ap_capacity(16), 5)
	assert_eq(cfg.ap_capacity(99), 5, "capped")


func test_dexterity_movement_bonus_capped_at_two() -> void:
	var cfg := GameConfig.load_file()
	assert_eq(cfg.tiles_per_ap(5), 1)
	assert_eq(cfg.tiles_per_ap(12), 2)
	assert_eq(cfg.tiles_per_ap(99), 3)


func test_revived_combatant_inactive_rest_of_round() -> void:
	var c := Combatant.new()
	c.inactive_until_round = 3
	assert_true(not c.is_active(2))
	assert_true(c.is_active(3))
