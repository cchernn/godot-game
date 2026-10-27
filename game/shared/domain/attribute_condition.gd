class_name AttributeCondition
extends UnlockCondition
## Met once the character's attribute (class base + earned grants; not statuses or items) is at least this value.

@export_enum("might", "dexterity", "agility", "vitality") var attribute: String = "might"
@export_range(1, 99) var min_value: int = 10


func met(ctx: Dictionary) -> bool:
	return int((ctx.get("attributes", {}) as Dictionary).get(attribute, 0)) >= min_value


func problem() -> String:
	return "" if attribute in Attributes.NAMES else "'%s' is not an attribute" % attribute
