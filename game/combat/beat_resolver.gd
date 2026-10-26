class_name BeatResolver
extends RefCounted
## Executes one beat: orders pending steps by skill speed (ties by a server-generated priority fixed
## for the beat), runs one step per combatant, re-validates at execution, and processes
## interruptions and reactions. Reaction effects never begin skills, so reactions cannot chain.

var b: Battle
var _rank: Dictionary = {}


func _init(battle: Battle) -> void:
	b = battle


func run_beat() -> void:
	var st := b.state
	for c: Combatant in st.combatants.values():
		if not c.reaction.is_empty() and (b.beat > (c.reaction["expires_beat"] as int) or c.has_condition("stunned")):
			c.reaction = {}
	var ids: Array = st.combatants.keys()
	ids.sort()
	for i in range(ids.size() - 1, 0, -1):
		var j := b.rng.randi_range(0, i)
		var tmp: Variant = ids[i]
		ids[i] = ids[j]
		ids[j] = tmp
	_rank.clear()
	for i in ids.size():
		_rank[ids[i]] = i
	var speeds := {}
	var order: Array[Combatant] = []
	for id: String in ids:
		var c := st.get_c(id)
		var sp := _pending_speed(c)
		if c.is_active(st.round_number) and sp >= 0:
			speeds[id] = sp
			order.append(c)
	order.sort_custom(func(x: Combatant, y: Combatant) -> bool:
		if speeds[x.id] != speeds[y.id]:
			return (speeds[x.id] as int) > (speeds[y.id] as int)
		return (_rank[x.id] as int) < (_rank[y.id] as int))
	for c in order:
		if c.is_active(st.round_number): # may have been defeated earlier this beat
			_step(c)


func _pending_speed(c: Combatant) -> int:
	var a: PlannedAction = c.current
	if a == null and c.queue_index < c.plan.size():
		a = c.plan[c.queue_index]
	if a == null:
		return -1
	var sk := b.skills.get_skill(a.skill_id)
	return sk.speed if sk != null else -1


func _step(c: Combatant) -> void:
	if c.has_condition("stunned"):
		_stunned(c)
		return
	if c.current == null:
		while c.queue_index < c.plan.size():
			var a := c.plan[c.queue_index]
			c.queue_index += 1
			var sk := b.skills.get_skill(a.skill_id)
			var reason := _can_begin(c, a, sk)
			if reason == "":
				c.current = a
				c.current_stage = 0
				c.move_index = 0
				c.interrupt_points = 0
				# Usage is consumed when the skill begins executing. Reaction preparation does not consume it.
				if sk.frequency == Enums.Frequency.ONCE_PER_TURN and sk.kind != Enums.SkillKind.REACTION:
					c.skills_used[sk.id] = true
				if a.item_id != "": # an item is used up when it begins, never when it was skipped
					c.items_used[a.item_id] = int(c.items_used.get(a.item_id, 0)) + 1
				break
			b.emit("skip", "{a}'s %s is skipped (%s)." % [sk.display_name, reason], c.id)
			forfeit(c, a)
		if c.current == null:
			return
	_run_stage(c)


## A stunned combatant loses its current skill and whatever is left of its queue.
func _stunned(c: Combatant) -> void:
	c.reaction = {}
	if c.current != null or c.queue_index < c.plan.size():
		b.emit("stunned", "{a} is stunned and cannot act.", c.id)
		clear_queue(c)


func _can_begin(c: Combatant, a: PlannedAction, sk: SkillDef) -> String:
	if a.object_id != "":
		var why := _context_problem(c, a, true)
		if why != "":
			return why
	elif a.item_id != "":
		if sk == null or c.items.get(a.item_id, 0) - c.items_used.get(a.item_id, 0) <= 0:
			return "no item left"
	elif sk == null or not c.skills.has(a.skill_id):
		return "unknown skill"
	if sk.frequency == Enums.Frequency.ONCE_PER_TURN and c.skills_used.has(sk.id):
		return "already used this round"
	if sk.kind == Enums.SkillKind.MOVE:
		if c.has_condition("rooted"):
			return "rooted"
		if a.path.is_empty() or not b.bf.can_step(c.cell, a.path[0], b.cfg.get_value("combat", "max_step_height")):
			return "path no longer valid"
		if b.state.at_cell(a.path[0]) != null:
			return "path blocked"
		var first := 1 + (b.cfg.get_value("movement", "difficult_terrain_surcharge") as int if b.bf.is_difficult(a.path[0]) else 0)
		if a.reserved_left < first:
			return "not enough AP"
		return ""
	return _stage_problem(c, a, sk, 0)


## Why a map object's action cannot happen right now, or "". The state is only required when it begins (a later stage
## carries on after the action's own state change).
func _context_problem(c: Combatant, a: PlannedAction, beginning: bool) -> String:
	var o := b.objects.get(a.object_id) as ContextObject
	var act: ContextAction = o.def.action(a.action_id) if o != null else null
	if o == null or act == null:
		return "object gone"
	if not o.in_reach(c.cell):
		return "out of reach"
	if beginning and not o.offers(act):
		return "not possible now"
	return ""


## "" if the stage can execute right now.
func _stage_problem(c: Combatant, a: PlannedAction, sk: SkillDef, stage_index: int) -> String:
	if a.reserved_left < (sk.stages[stage_index]["ap"] as int):
		return "not enough AP"
	if a.object_id != "" and stage_index > 0:
		return _context_problem(c, a, false)
	match sk.kind:
		Enums.SkillKind.ATTACK, Enums.SkillKind.REVIVE, Enums.SkillKind.SUPPORT:
			if sk.targeting == Enums.Targeting.SELF:
				return ""
			var from := c.cell
			var to: Vector2i
			if sk.targeting == Enums.Targeting.CHARACTER:
				var t := b.state.get_c(a.target_id)
				if t == null or not t.is_present():
					return "target gone"
				if sk.kind == Enums.SkillKind.REVIVE:
					if t.life_state != Enums.LifeState.DOWNED or t.revived_this_encounter:
						return "target cannot be revived"
				elif not b.team_can_see_combatant(c.team, t):
					return "target out of sight"
				to = t.cell
			else:
				to = a.target_cell
			if Enums.manhattan(from, to) > sk.attack_range:
				return "out of range"
			if not b.bf.has_los(from, to):
				return "no line of sight"
	return ""


func _run_stage(c: Combatant) -> void:
	var a := c.current
	var sk := b.skills.get_skill(a.skill_id)
	if sk.kind == Enums.SkillKind.MOVE:
		_move_step(c, a)
		return
	if c.current_stage > 0:
		var problem := _stage_problem(c, a, sk, c.current_stage)
		if problem != "":
			b.emit("cancel", "{a}'s %s is cancelled (%s)." % [sk.display_name, problem], c.id)
			forfeit(c, a)
			c.current = null
			return
	var stage: Dictionary = sk.stages[c.current_stage]
	_spend(c, a, stage["ap"] as int)
	match sk.kind:
		Enums.SkillKind.ATTACK, Enums.SkillKind.SUPPORT:
			if a.object_id != "":
				_run_context(c, a, sk, stage)
			else:
				_run_effects(c, a, sk, stage)
		Enums.SkillKind.REVIVE:
			_revive(c, a)
		Enums.SkillKind.REACTION:
			c.reaction = {"skill": sk.id, "expires_beat": b.beat + (sk.reaction["duration_beats"] as int)}
			b.emit("reaction_ready", "{a} prepares %s." % sk.display_name, c.id)
	if c.current == null: # e.g. the actor was defeated by its own side effects
		return
	var began := c.current_stage == 0
	c.current_stage += 1
	if began and sk.kind == Enums.SkillKind.ATTACK and sk.is_multistage():
		_check_reactions(c)
	if c.current != null and c.current_stage >= sk.stages.size():
		forfeit(c, a)
		c.current = null


func _move_step(c: Combatant, a: PlannedAction) -> void:
	var tpa := b.cfg.tiles_per_ap(c.stat("agility"))
	var sur: int = b.cfg.get_value("movement", "difficult_terrain_surcharge")
	var max_step: int = b.cfg.get_value("combat", "max_step_height")
	var moved := 0
	while moved < tpa and c.move_index < a.path.size():
		var nxt := a.path[c.move_index]
		var cost := (1 if moved == 0 else 0) + (sur if b.bf.is_difficult(nxt) else 0)
		var why := ""
		if c.has_condition("rooted"):
			why = "rooted"
		elif not b.bf.can_step(c.cell, nxt, max_step):
			why = "terrain"
		elif b.state.at_cell(nxt) != null:
			why = "the way is blocked"
		elif cost > a.reserved_left:
			why = "out of AP"
		if why != "":
			b.emit("move_stop", "{a} stops (%s)." % why, c.id)
			forfeit(c, a)
			c.current = null
			return
		_spend(c, a, cost)
		var old := c.cell
		c.cell = nxt
		c.move_index += 1
		moved += 1
		var seen := Visibility.team_sees(b.state, b.bf, Enums.Team.PLAYERS, old, b.sight)
		b.emit("move", "{a} moves.", c.id, "", {"from": old, "to": nxt}, seen)
	if c.move_index >= a.path.size():
		if a.facing >= 0:
			c.facing = a.facing
		forfeit(c, a)
		c.current = null


## One stage of a map object's action: the effects land on the actor, and the object changes state when the action begins.
func _run_context(c: Combatant, a: PlannedAction, sk: SkillDef, stage: Dictionary) -> void:
	var o := b.objects[a.object_id] as ContextObject
	var act := o.def.action(a.action_id)
	if o.cell != c.cell:
		c.facing = Enums.facing_from_delta(o.cell - c.cell)
	if c.current_stage == 0:
		b.emit("context", "{a} uses %s on the %s." % [act.display_name, o.def.display_name], c.id)
	if not (stage.get("effects", []) as Array).is_empty():
		_run_effects(c, a, sk, stage)
	if c.current_stage == 0 and act.sets_state != "" and c.current != null:
		b.set_object_state(o, act.sets_state)
		b.emit("object_state", "The %s is now %s." % [o.def.display_name, act.sets_state], c.id)


## Runs a stage's effects, in order, on whoever it is aimed at (and `on = CASTER` effects on the caster). Anyone can be the
## target, friend or foe, and the caster too. A stage with no effects is only a preparation step.
func _run_effects(c: Combatant, a: PlannedAction, sk: SkillDef, stage: Dictionary) -> void:
	var victim: Combatant = null
	var aim := c.cell
	match sk.targeting:
		Enums.Targeting.CHARACTER:
			victim = b.state.get_c(a.target_id)
			aim = victim.cell
		Enums.Targeting.TILE:
			aim = a.target_cell
			victim = b.state.at_cell(a.target_cell)
		Enums.Targeting.SELF:
			victim = c
	if aim != c.cell:
		c.facing = Enums.facing_from_delta(aim - c.cell)
	var effects: Array = stage.get("effects", [])
	if effects.is_empty():
		b.emit("windup", "{a} begins %s%s." % [sk.display_name, " on {t}" if victim else ""],
			c.id, victim.id if victim else "")
		return
	# Who is hit: the one target, or everyone on the covered tiles (found now, so it follows a target that moved).
	var victims: Array[Combatant] = []
	if sk.is_area():
		victims = _area_victims(c, sk, aim)
		if not victims.is_empty():
			b.emit("area", "{a}'s %s covers %d target%s." % [sk.display_name, victims.size(), "" if victims.size() == 1 else "s"], c.id)
	elif victim != null:
		victims.append(victim)
	var landed := {} # victim id -> whether the damage before the current effect connected (default yes)
	var any_landed := true
	for e: Dictionary in effects:
		if (e["on"] as int) == SkillEffect.On.CASTER:
			_apply_effect(c, sk, e, c, any_landed or e["type"] != "interrupt")
			continue
		var any := false
		for v in victims:
			var ok := _apply_effect(c, sk, e, v, landed.get(v.id, true))
			if e["type"] == "damage":
				landed[v.id] = ok
				any = any or ok
		if e["type"] == "damage" and not victims.is_empty():
			any_landed = any
	if victims.is_empty() and sk.targeting == Enums.Targeting.TILE:
		var hurts := effects.any(func(e: Dictionary) -> bool: return e["type"] == "damage")
		b.emit("miss", "{a}'s %s %s." % [sk.display_name, "strikes empty ground" if hurts else "finds no one there"], c.id)


## Everyone standing on the skill's covered tiles, caster included, in id order so that rolls come out the same every time.
func _area_victims(c: Combatant, sk: SkillDef, aim: Vector2i) -> Array[Combatant]:
	var out: Array[Combatant] = []
	for cell in sk.area.cells(b.bf, c.cell, aim, c.facing):
		var who := b.state.at_cell(cell)
		if who != null and not out.has(who):
			out.append(who)
	out.sort_custom(func(x: Combatant, y: Combatant) -> bool: return x.id < y.id)
	return out


## Runs one effect on one receiver. `connected` = whether the damage before it landed on this receiver (interrupts and statuses
## need it). Returns whether a damage effect connected (true for every other kind).
func _apply_effect(c: Combatant, sk: SkillDef, e: Dictionary, who: Combatant, connected: bool) -> bool:
	match e["type"] as String:
		"damage":
			return _damage(c, sk.display_name, e, who)
		"heal":
			_heal(c, sk.display_name, e, who)
		"shield":
			_shield(c, sk.display_name, e, who)
		"interrupt":
			if connected and who.life_state == Enums.LifeState.ALIVE:
				_add_interrupt(who, e["points"] as int)
		"apply_status":
			if connected and who.life_state == Enums.LifeState.ALIVE:
				_apply_status(c, e, who)
		"remove_status":
			_remove_status(c, e, who)
		"grant_item":
			_grant_item(c, e, who)
		"set_flag":
			_set_flag(c, e, who)
	return true


## Copies go to the receiver, never above the item's own limit; reported with the result so they are saved.
func _grant_item(c: Combatant, e: Dictionary, who: Combatant) -> void:
	var id: String = e["item"]
	var def := b.skills.items.get(id) as ItemDef
	if def == null:
		b.emit("no_effect", "{a} finds nothing usable.", c.id, who.id)
		return
	var carried: int = int(who.items.get(id, 0)) - int(who.items_used.get(id, 0))
	var n := mini(e["count"] as int, def.max_stack - carried)
	if n <= 0:
		b.emit("no_effect", "{t} cannot carry any more %s." % def.display_name, c.id, who.id)
		return
	who.items[id] = int(who.items.get(id, 0)) + n
	who.items_gained[id] = int(who.items_gained.get(id, 0)) + n
	b.emit("grant_item", "{t} gets %d %s." % [n, def.display_name], c.id, who.id)


func _set_flag(c: Combatant, e: Dictionary, who: Combatant) -> void:
	var flag: String = e["flag"]
	if not who.flags_gained.has(flag):
		who.flags_gained.append(flag)
	b.emit("set_flag", "{t} has earned something (%s)." % flag, c.id, who.id)


## Returns true when the damage connected (a miss returns false, so a following interrupt effect does not land).
func _damage(c: Combatant, label: String, e: Dictionary, victim: Combatant) -> bool:
	if victim.life_state == Enums.LifeState.DOWNED:
		b.emit("hit", "{a}'s %s finishes {t}." % label, c.id, victim.id)
		_defeat(victim)
		return true
	if not victim.is_present() or victim.life_state != Enums.LifeState.ALIVE:
		return false
	if e["can_miss"] as bool:
		var per: float = b.cfg.get_value("combat", "accuracy_per_point")
		var chance := clampf((b.cfg.get_value("combat", "base_hit_chance") as float) + (c.stat("accuracy") - victim.stat("evasion")) * per, 0.05, 1.0)
		if b.rng.randf() >= chance:
			b.emit("miss", "{a}'s %s misses {t}." % label, c.id, victim.id)
			return false
	var mult := 1.0
	var note := ""
	if e["can_crit"] as bool:
		if victim != c:
			var rel := _relative_facing(c, victim)
			if rel == 2:
				mult *= b.cfg.get_value("combat", "rear_multiplier") as float
				note = " (rear attack)"
			elif rel == 1:
				mult *= b.cfg.get_value("combat", "side_multiplier") as float
				note = " (flanking)"
		if b.rng.randf() < (b.cfg.get_value("combat", "crit_chance") as float):
			mult *= b.cfg.get_value("combat", "crit_multiplier") as float
			note += " CRITICAL"
	var raw: int = e["base"] as int
	if e["uses_power"] as bool:
		raw += c.stat("power")
	var dmg := maxi(1, roundi(raw * mult) - victim.stat("armor"))
	var absorbed := mini(victim.shield, dmg)
	victim.shield -= absorbed
	victim.hp = maxi(0, victim.hp - (dmg - absorbed))
	if absorbed > 0:
		note += " (%d absorbed by the shield)" % absorbed
	b.emit("hit", "{a}'s %s hits {t} for %d%s." % [label, dmg, note], c.id, victim.id, {"amount": dmg, "absorbed": absorbed})
	if victim.hp == 0:
		_defeat(victim)
		return false # nothing left to interrupt
	return true


func _heal(c: Combatant, label: String, e: Dictionary, victim: Combatant) -> void:
	if victim.life_state != Enums.LifeState.ALIVE:
		b.emit("no_effect", "{a}'s %s has no effect on {t}." % label, c.id, victim.id)
		return
	var gained := mini(e["amount"] as int, victim.max_hp - victim.hp)
	victim.hp += gained
	b.emit("heal", "{a}'s %s heals {t} for %d." % [label, gained], c.id, victim.id, {"amount": gained})


func _shield(c: Combatant, label: String, e: Dictionary, victim: Combatant) -> void:
	if victim.life_state != Enums.LifeState.ALIVE:
		b.emit("no_effect", "{a}'s %s has no effect on {t}." % label, c.id, victim.id)
		return
	victim.shield = maxi(victim.shield, e["amount"] as int) # does not stack: only a higher shield replaces it
	b.emit("shield", "{a}'s %s shields {t} (%d)." % [label, victim.shield], c.id, victim.id, {"amount": victim.shield})


## 0 = front, 1 = side, 2 = rear.
func _relative_facing(attacker: Combatant, target: Combatant) -> int:
	var dir := Enums.facing_from_delta(attacker.cell - target.cell)
	if dir == target.facing:
		return 0
	if dir == (target.facing + 2) % 4:
		return 2
	return 1


func _revive(c: Combatant, a: PlannedAction) -> void:
	var t := b.state.get_c(a.target_id)
	t.hp = maxi(1, int(t.max_hp * (b.cfg.get_value("combat", "revive_hp_fraction") as float)))
	t.life_state = Enums.LifeState.ALIVE
	t.revived_this_encounter = true
	t.inactive_until_round = b.state.round_number + 1
	b.emit("revived", "{a} revives {t}.", c.id, t.id)


func _defeat(v: Combatant) -> void:
	clear_queue(v)
	v.shield = 0
	v.statuses.clear()
	if v.team == Enums.Team.ENEMIES or v.life_state == Enums.LifeState.DOWNED or v.revived_this_encounter:
		v.life_state = Enums.LifeState.ELIMINATED
		v.hp = 0
		b.emit("eliminated", "{t} is eliminated!", "", v.id)
	else:
		v.life_state = Enums.LifeState.DOWNED
		b.emit("downed", "{t} is downed!", "", v.id)


## A defeated character loses the current skill and the whole remaining queue.
func clear_queue(v: Combatant) -> void:
	forfeit_all(v)
	v.queue_index = v.plan.size()
	v.current = null


func _add_interrupt(v: Combatant, pts: int) -> void:
	if pts <= 0 or v.current == null:
		return
	v.interrupt_points += pts
	var sk := b.skills.get_skill(v.current.skill_id)
	if v.interrupt_points >= sk.stability:
		b.emit("interrupt", "{t}'s %s is interrupted!" % sk.display_name, "", v.id)
		forfeit(v, v.current)
		v.current = null # completed effects remain; the rest of this skill is cancelled


# ---------- Statuses (counted in turns) ----------

## Start of a turn's resolution: each status runs its each-turn effects on its bearer, in a fixed order.
func run_turn_start() -> void:
	var ids: Array = b.state.combatants.keys()
	ids.sort()
	for id: String in ids:
		var c := b.state.get_c(id)
		for s in c.statuses.duplicate():
			if c.life_state != Enums.LifeState.ALIVE:
				break
			var d: Dictionary = s["def"]
			for tick: Dictionary in d["ticks"]:
				var times: int = s["stacks"] if tick["type"] != "shield" else 1
				for i in times:
					match tick["type"] as String:
						"damage":
							_damage(c, d["name"] as String, tick, c)
						"heal":
							_heal(c, d["name"] as String, tick, c)
						"shield":
							_shield(c, d["name"] as String, tick, c)
					if c.life_state != Enums.LifeState.ALIVE:
						break


## End of a turn: every status loses a turn and the finished ones fade.
func run_turn_end() -> void:
	var ids: Array = b.state.combatants.keys()
	ids.sort()
	for id: String in ids:
		var c := b.state.get_c(id)
		for s in c.statuses.duplicate():
			s["turns_left"] = (s["turns_left"] as int) - 1
			if (s["turns_left"] as int) <= 0:
				c.statuses.erase(s)
				if c.is_present():
					b.emit("status_end", "%s fades from {t}." % s["def"]["name"], "", c.id, {"status": s["id"]})


func _apply_status(c: Combatant, e: Dictionary, who: Combatant) -> void:
	var d: Dictionary = e["status"]
	if d.is_empty():
		return
	var turns: int = e["duration"] if (e["duration"] as int) > 0 else d["duration"]
	var cur := who.status_of(d["id"])
	if cur.is_empty():
		who.statuses.append({"id": d["id"], "def": d, "turns_left": turns, "stacks": 1})
		b.emit("status_apply", "{t} is afflicted by %s (%d turn%s)." % [d["name"], turns, "" if turns == 1 else "s"],
			c.id, who.id, {"status": d["id"]})
		return
	match d["stacking"] as int:
		StatusDef.Stacking.IGNORE:
			b.emit("no_effect", "%s is already on {t}." % d["name"], c.id, who.id)
		StatusDef.Stacking.REFRESH:
			cur["turns_left"] = maxi(cur["turns_left"] as int, turns)
			b.emit("status_apply", "%s on {t} is renewed (%d turns)." % [d["name"], cur["turns_left"]], c.id, who.id, {"status": d["id"]})
		StatusDef.Stacking.STACK:
			cur["stacks"] = mini(cur["stacks"] as int + 1, d["max_stacks"] as int)
			cur["turns_left"] = maxi(cur["turns_left"] as int, turns)
			b.emit("status_apply", "%s on {t} grows to x%d (%d turns)." % [d["name"], cur["stacks"], cur["turns_left"]],
				c.id, who.id, {"status": d["id"]})


func _remove_status(c: Combatant, e: Dictionary, who: Combatant) -> void:
	var mode: int = e["mode"]
	var removed := 0
	for s in who.statuses.duplicate():
		var kind: int = s["def"]["kind"]
		var hit := false
		match mode:
			RemoveStatusEffect.Mode.ONE: hit = s["id"] == e["status_id"]
			RemoveStatusEffect.Mode.BUFFS: hit = kind == StatusDef.Kind.BUFF
			RemoveStatusEffect.Mode.DEBUFFS: hit = kind == StatusDef.Kind.DEBUFF
			RemoveStatusEffect.Mode.ALL: hit = true
		if hit:
			who.statuses.erase(s)
			removed += 1
			b.emit("status_end", "%s is removed from {t}." % s["def"]["name"], c.id, who.id, {"status": s["id"]})
	if removed == 0:
		b.emit("no_effect", "Nothing to remove from {t}.", c.id, who.id)


func _check_reactions(actor: Combatant) -> void:
	var reactors: Array[Combatant] = []
	for r: Combatant in b.state.combatants.values():
		if r.team != actor.team and r.is_active(b.state.round_number) and not r.reaction.is_empty() and not r.has_condition("stunned"):
			reactors.append(r)
	reactors.sort_custom(func(x: Combatant, y: Combatant) -> bool: return (_rank[x.id] as int) < (_rank[y.id] as int))
	for r in reactors:
		if actor.current == null:
			return
		var sk := b.skills.get_skill(r.reaction["skill"] as String)
		var rng_: int = sk.reaction["range"]
		if Enums.manhattan(r.cell, actor.cell) > rng_ or not b.bf.has_los(r.cell, actor.cell) \
				or not b.team_can_see_combatant(r.team, actor):
			continue
		r.skills_used[sk.id] = true # consumed when the reaction executes
		r.reaction = {}
		b.emit("reaction", "{a}'s %s triggers against {t}!" % sk.display_name, r.id, actor.id)
		_add_interrupt(actor, sk.reaction["interrupt"] as int)


func _spend(c: Combatant, a: PlannedAction, n: int) -> void:
	a.reserved_left -= n
	a.spent += n
	c.ap_reserved -= n
	c.ap_spent += n


## Unused reservation is forfeited for the round; it is never reassigned to later actions.
func forfeit(c: Combatant, a: PlannedAction) -> void:
	c.ap_reserved -= a.reserved_left
	c.ap_forfeited += a.reserved_left
	a.reserved_left = 0


func forfeit_all(c: Combatant) -> void:
	for a in c.plan:
		forfeit(c, a)
