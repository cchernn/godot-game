class_name Loadout
extends RefCounted
## What a character takes into a battle, worked out from what the API holds for it: the gear it wears, the consumables it chose, and the
## loot it rolls when it wins. Pure functions, so the game server and the tests use the same rules. Never trusts its input.


## The ids of the gear a character wears, in the order of the worn places (weapon 1, weapon 2, armor, accessory).
## `character.gear` = [{id, gear_id, place}] as the API sends it (place is null while a piece is in the bag).
static func worn_ids(character: Dictionary) -> Array:
	var by_place := {}
	for g: Variant in character.get("gear", []):
		if g is Dictionary and g.get("place") != null:
			by_place[str(g["place"])] = str(g.get("gear_id", ""))
	var out: Array = []
	for place in GearDef.WORN_PLACES:
		if by_place.has(place):
			out.append(by_place[place])
	return out


## The consumables taken into the battle {item id: copies}: the kinds the player chose (`battle_items`), or with no choice the first
## `slots` kinds the API listed (in item id order). Only kinds the game knows and the character still holds.
static func battle_items(character: Dictionary, db: SkillDb, slots: int) -> Dictionary:
	var held := {}
	for it: Variant in character.get("items", []):
		if it is Dictionary:
			held[str(it.get("item_id", ""))] = int(it.get("quantity", 0))
	var order: Array = held.keys()
	var chosen: Variant = character.get("battle_items")
	if chosen is Array:
		order = chosen
	var out := {}
	for id: Variant in order:
		if out.size() < slots and db.items.has(str(id)) and int(held.get(str(id), 0)) > 0:
			out[str(id)] = int(held[str(id)])
	return out


## What one player's rolls on an encounter's drops gave: {gear: [ids], items: {id: copies}}. Seeded by `seed_text` (the battle key and the
## character), so a retried commit sends exactly the same loot.
static func roll_drops(def: EncounterDef, seed_text: String, db: SkillDb) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(seed_text)
	var loot := {"gear": [], "items": {}}
	for d in def.drops:
		if rng.randi_range(1, 100) > d.chance_percent:
			continue
		if d.is_gear():
			(loot["gear"] as Array).append(d.drop_id())
		elif db.items.has(d.drop_id()):
			loot["items"][d.drop_id()] = int(loot["items"].get(d.drop_id(), 0)) + d.count
	return loot
