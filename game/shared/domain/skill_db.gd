class_name SkillDb
extends RefCounted
## The skills in the game, looked up by id. Loaded from the SkillSet resource (provisional values).
## Every load returns its own copies, so a test (or a mod) can change one without touching the shared files.

const DEFAULT_PATH := "res://game/content/skills/skill_set.tres"
const ITEMS_PATH := "res://game/content/items/item_set.tres"

var skills: Dictionary = {}
## Ids of the basic actions every player character gets (from the skill set's Basic list).
var basic_ids: Array[String] = []
## item id -> ItemDef. Each item's use skill is also in `skills` under "item:<id>", so plans and the rules treat it like any skill.
var items: Dictionary = {}


static func load_file(path: String = DEFAULT_PATH) -> SkillDb:
	var set := load(path) as SkillSet
	assert(set != null, "Cannot load the skill set: %s" % path)
	var db := SkillDb.new()
	for s in set.skills:
		var copy := s.duplicate(true) as SkillDef
		db.skills[copy.id] = copy
	for b in set.basic:
		db.basic_ids.append(b.id)
	var item_set := load(ITEMS_PATH) as ItemSet
	assert(item_set != null, "Cannot load the item set: %s" % ITEMS_PATH)
	for it in item_set.items:
		db.add_item(it.duplicate(true) as ItemDef)
	return db


## Registers an item and its use skill (also how tests add throwaway items).
func add_item(item: ItemDef) -> void:
	items[item.id] = item
	var sk := item.make_skill()
	skills[sk.id] = sk


## Registers the skills of a map object's actions ("ctx:<object id>:<action id>"). The battle and the client both do this for the
## objects on the map, so plans and the rules treat context actions like any skill.
func add_context(object_id: String, def: ContextObjectDef) -> void:
	for a in def.actions:
		if a != null and a.use != null:
			var sk := a.make_skill(object_id)
			skills[sk.id] = sk


func get_skill(id: String) -> SkillDef:
	return skills.get(id) as SkillDef
