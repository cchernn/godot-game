class_name Attributes
extends Resource
## The four primary attributes of a character or enemy. Used for a class's growth per level and for the value of one
## allocated point (see UnitTemplate); a class's own starting attributes are plain fields on the template.
## Battle numbers (HP, damage, hit chance, AP, movement) are worked out from them by CharacterBuild using config/balance.json "stats".

const NAMES: Array[String] = ["might", "dexterity", "agility", "vitality"]

## Damage and healing dealt (both physical and magical).
@export_range(-99, 99) var might: int = 0
## Action points and accuracy.
@export_range(-99, 99) var dexterity: int = 0
## Tiles moved per AP and evasion.
@export_range(-99, 99) var agility: int = 0
## Max HP.
@export_range(-99, 99) var vitality: int = 0


func get_attr(attr: String) -> int:
	return int(get(attr)) if attr in NAMES else 0


func is_zero() -> bool:
	return might == 0 and dexterity == 0 and agility == 0 and vitality == 0


func to_dict() -> Dictionary:
	return {"might": might, "dexterity": dexterity, "agility": agility, "vitality": vitality}
