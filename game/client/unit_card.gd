class_name UnitCard
extends PanelContainer
## One combatant on the strip under the board (game/content/ui/unit_card.tscn): name, class, HP bar, and for allies AP and
## whether they are Ready. It only displays the snapshot's unit dictionary; the server decides what each player may see.

const READY_COLOR := Color(0.55, 0.9, 0.6)
const WAITING_COLOR := Color(1.0, 0.85, 0.5)
const DOWN_COLOR := Color(1.0, 0.5, 0.45)

@onready var _name: Label = %NameLabel
@onready var _bar: ProgressBar = %HpBar
@onready var _hp: Label = %HpLabel
@onready var _status: Label = %StatusLabel


## u: a unit from the snapshot. phase: the Enums.RoundPhase. is_you marks the player's own card.
func show_unit(u: Dictionary, phase: int, is_you: bool) -> void:
	var cls := str(u.get("visual", "")).capitalize()
	var who := str(u["name"])
	_name.text = "%s%s%s" % [who, " (you)" if is_you else "", " - %s" % cls if u["team"] == Enums.Team.PLAYERS and cls != "" else ""]
	_bar.max_value = maxi(1, int(u["max_hp"]))
	_bar.value = int(u["hp"])
	_hp.text = "HP %d/%d" % [u["hp"], u["max_hp"]]
	var parts: Array[String] = []
	if u.has("ap_capacity"):
		var ap := "AP %d" % u["ap_capacity"]
		if int(u.get("ap_reserved", 0)) > 0:
			ap += " (%d reserved)" % u["ap_reserved"]
		parts.append(ap)
	var color := Color.WHITE
	if u["life"] == Enums.LifeState.DOWNED:
		parts.append("Downed")
		color = DOWN_COLOR
	elif not u["active"]:
		parts.append("Resting")
	elif u["team"] == Enums.Team.PLAYERS and phase == Enums.RoundPhase.PLANNING:
		parts.append("Ready" if u["ready"] else "Planning")
		color = READY_COLOR if u["ready"] else WAITING_COLOR
	_status.text = " - ".join(parts)
	_status.modulate = color
