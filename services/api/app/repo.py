import hashlib
import json
import uuid

import psycopg.errors
from psycopg.types.json import Jsonb
from psycopg_pool import ConnectionPool

from .errors import Conflict, Forbidden, Invalid, Locked, NotFound, RepoError  # noqa: F401
from .templates import TemplateError, TemplateStore
from .party_repo import PartyMixin
from .world_repo import WorldMixin


def _row(r: dict | None) -> dict | None:
    if r is None:
        return None
    return {k: (str(v) if isinstance(v, uuid.UUID) else v) for k, v in r.items()}


class Repository(PartyMixin, WorldMixin):
    """All durable reads/writes. Gameplay rules never live here."""

    def __init__(self, pool: ConnectionPool, templates: TemplateStore | None = None, presence_seconds: int = 30,
                 session_seconds: int = 30):
        self.pool = pool
        self.session_seconds = session_seconds
        self.presence_seconds = presence_seconds
        self.templates = templates or TemplateStore()

    # ---- login session ----

    def claim_session(self, user_id: uuid.UUID, session_id: str) -> None:
        """Takes (or refreshes) the account's single login. A different login holds it while it was heard from within
        `session_seconds`; then this raises Locked and nothing changes, so credentials alone never take a live login over."""
        with self.pool.connection() as conn:
            row = conn.execute(
                "insert into player_sessions (user_id, session_id) values (%s, %s) "
                "on conflict (user_id) do update set session_id = excluded.session_id, last_seen_at = now() "
                "where player_sessions.session_id = excluded.session_id "
                "or player_sessions.last_seen_at < now() - make_interval(secs => %s) returning user_id",
                (user_id, session_id, self.session_seconds)).fetchone()
        if row is None:
            raise Locked("This account is signed in on another device")

    def release_session(self, user_id: uuid.UUID, session_id: str) -> None:
        """Sign-out: frees the account at once, but only for the login that holds it."""
        with self.pool.connection() as conn:
            conn.execute("delete from player_sessions where user_id = %s and session_id = %s", (user_id, session_id))

    # ---- worlds ----

    def create_world(self, user_id: uuid.UUID, name: str, template_id: str = "prototype") -> dict:
        """Creates a world from the latest version of a template, exactly once. Initial conditions are
        copied into mutable state rows, so later template edits cannot change this world."""
        try:
            version = self.templates.latest_version(template_id)
            d = self.templates.load(template_id, version)
        except TemplateError as e:
            raise Invalid(str(e)) from e
        with self.pool.connection() as conn:
            w = conn.execute(
                "insert into worlds (name, template_id, definition_version, rules, created_by) values (%s,%s,%s,%s,%s) returning *",
                (name, template_id, version, Jsonb(d.rules), user_id)).fetchone()
            conn.execute("insert into world_members (world_id, user_id, role) values (%s, %s, 'host')", (w["id"], user_id))
            for kind, target in d.visible_by_default():
                conn.execute("insert into world_discoveries (world_id, kind, target_id, scope) values (%s,%s,%s,'world')",
                             (w["id"], kind, target))
            for a in d.activities.values():
                if a["class"] == "campaign":
                    conn.execute("insert into world_activities (world_id, activity_id) values (%s,%s)", (w["id"], a["id"]))
        return _row(w)

    def list_worlds(self, user_id: uuid.UUID) -> list[dict]:
        with self.pool.connection() as conn:
            rows = conn.execute(
                "select w.* from worlds w join world_members m on m.world_id = w.id where m.user_id = %s and m.status = 'active' order by w.created_at",
                (user_id,)).fetchall()
        return [_row(r) for r in rows]

    def is_member(self, world_id: uuid.UUID, user_id: uuid.UUID) -> bool:
        with self.pool.connection() as conn:
            return conn.execute("select 1 from world_members where world_id=%s and user_id=%s and status='active'", (world_id, user_id)).fetchone() is not None

    # ---- characters ----

    def create_character(self, world_id: uuid.UUID, user_id: uuid.UUID, name: str, cls: str) -> dict:
        if not self.is_member(world_id, user_id):
            raise Forbidden("Not a member of this world")
        start_node = self.definition(world_id).start_node
        try:
            with self.pool.connection() as conn:
                r = conn.execute(
                    "insert into characters (world_id, user_id, name, class, node_id) values (%s,%s,%s,%s,%s) returning *",
                    (world_id, user_id, name, cls, start_node)).fetchone()
                self._party_of(conn, r)  # every character starts in a party of one
        except psycopg.errors.UniqueViolation as e:
            raise Conflict("You already have an active character in this world") from e
        return _row(r)

    def active_character(self, world_id: uuid.UUID, user_id: uuid.UUID) -> dict | None:
        with self.pool.connection() as conn:
            c = _row(conn.execute(
                "select * from characters where world_id=%s and user_id=%s and status='active'", (world_id, user_id)).fetchone())
            if c is not None:
                c["items"] = self._loadouts(conn, [c["id"]]).get(c["id"], [])
        return c

    # ---- items ----

    @staticmethod
    def _loadouts(conn, character_ids: list) -> dict[str, list[dict]]:
        """character id -> [{item_id, quantity}], in item id order. The game server decides how many kinds go into a battle."""
        if not character_ids:
            return {}
        rows = conn.execute("select character_id, item_id, quantity from character_items where character_id = any(%s) "
                            "order by item_id", ([uuid.UUID(str(i)) for i in character_ids],)).fetchall()
        out: dict[str, list[dict]] = {}
        for r in rows:
            out.setdefault(str(r["character_id"]), []).append({"item_id": r["item_id"], "quantity": r["quantity"]})
        return out

    def grant_items(self, character_id: uuid.UUID, item_id: str, quantity: int, max_stack: int = 99) -> dict:
        """Adds copies of an item to an active character, never above `max_stack` (the item's own limit, from the game content).
        No shops, loot or crafting yet: this is the dev/admin way in."""
        with self.pool.connection() as conn:
            c = conn.execute("select id from characters where id=%s and status='active'", (character_id,)).fetchone()
            if c is None:
                raise NotFound("Character not found")
            row = conn.execute(
                "insert into character_items (character_id, item_id, quantity) values (%s,%s,%s) "
                "on conflict (character_id, item_id) do update set quantity = least(%s, character_items.quantity + excluded.quantity) "
                "returning quantity", (character_id, item_id, min(quantity, max_stack), max_stack)).fetchone()
        return {"character_id": str(character_id), "item_id": item_id, "quantity": row["quantity"]}

    def change_flags(self, character_id: uuid.UUID, add: list[str], remove: list[str]) -> dict:
        """Dev/admin (later: the game, on story events): sets and clears event flags on a character. Idempotent."""
        with self.pool.connection() as conn:
            row = conn.execute("select flags from characters where id=%s and status='active' for update", (character_id,)).fetchone()
            if row is None:
                raise NotFound("Character not found")
            flags = [f for f in row["flags"] if f not in remove]
            flags += [f for f in dict.fromkeys(add) if f not in flags]
            conn.execute("update characters set flags=%s where id=%s", (Jsonb(flags), character_id))
        return {"character_id": str(character_id), "flags": flags}

    def retire_character(self, character_id: uuid.UUID, user_id: uuid.UUID) -> dict:
        with self.pool.connection() as conn:
            r = conn.execute("select * from characters where id=%s for update", (character_id,)).fetchone()
            if r is None or r["user_id"] != user_id:
                raise NotFound("Character not found")
            if r["status"] == "retired":
                return _row(r)
            if self._live_party_of(conn, r["id"]):
                raise Conflict("Finish the activity before retiring this character")
            self._detach(conn, r["id"])
            # TODO(phase 6): refuse while committed to travel.
            r = conn.execute("update characters set status='retired', retired_at=now() where id=%s returning *", (character_id,)).fetchone()
        return _row(r)

    def get_profile(self, user_id: uuid.UUID) -> dict:
        with self.pool.connection() as conn:
            row = conn.execute("select display_name from profiles where user_id=%s", (user_id,)).fetchone()
        return {"display_name": row["display_name"] if row else None}

    def set_profile(self, user_id: uuid.UUID, display_name: str) -> dict:
        with self.pool.connection() as conn:
            conn.execute("insert into profiles (user_id, display_name) values (%s,%s) "
                         "on conflict (user_id) do update set display_name=excluded.display_name, updated_at=now()", (user_id, display_name))
        return {"display_name": display_name}

    def list_characters(self, world_id: uuid.UUID, user_id: uuid.UUID) -> list[dict]:
        """Every character in the world, active first, with the account that owns it (the join label, else a short id)."""
        if not self.is_member(world_id, user_id):
            raise Forbidden("Not a member of this world")
        with self.pool.connection() as conn:
            rows = conn.execute(
                "select c.id, c.user_id, c.name, c.class, c.status, c.retired_at, m.role, "
                "  (select r.requester_label from world_join_requests r where r.world_id = c.world_id and r.user_id = c.user_id "
                "     and r.requester_label is not null order by r.created_at desc limit 1) as label, "
                "  (select p.display_name from profiles p where p.user_id = c.user_id) as display_name "
                "from characters c join world_members m on m.world_id = c.world_id and m.user_id = c.user_id "
                "where c.world_id = %s order by (c.status = 'active') desc, c.created_at", (world_id,)).fetchall()
        out = []
        for r in rows:
            owner = r["display_name"] or (r["label"].split("@")[0] if r["label"] else
                                          "Host" if r["role"] == "host" else "Player %s" % str(r["user_id"])[:8])
            out.append({"id": str(r["id"]), "name": r["name"], "class": r["class"],
                        "status": r["status"], "owner": owner, "mine": r["user_id"] == user_id})
        return out

    def recent_battles(self, world_id: uuid.UUID, user_id: uuid.UUID, limit: int = 5) -> list[dict]:
        """The caller's active character's latest battles, newest first."""
        c = self.active_character(world_id, user_id)
        if c is None:
            raise NotFound("No active character")
        with self.pool.connection() as conn:
            rows = conn.execute(
                "select r.created_at, r.outcome as result, r.rounds, p.outcome "
                "from combat_result_participants p join combat_results r on r.id = p.result_id "
                "where p.character_id = %s order by r.created_at desc limit %s", (c["id"], limit)).fetchall()
        return [_row(r) for r in rows]

    # ---- combat results ----

    def commit_combat_result(self, key: str, world_id: uuid.UUID, outcome: str, rounds: int,
                             participants: list[dict], instance_id: uuid.UUID | None = None) -> tuple[dict, bool]:
        """Atomically records a finished encounter and what it earned (gold, items, flags).
        On a win, every participant who did not escape is paid the gold the game server computed (equal for all), and, when the result
        belongs to an activity run, that activity's authored rewards (flags, items) and its completion record. Idempotent per key: replaying the same
        payload returns the stored result; reusing a key for a different payload is a conflict."""
        canonical = json.dumps({"w": str(world_id), "o": outcome, "r": rounds, "i": str(instance_id or ""),
                                "p": sorted((str(p["character_id"]), p["outcome"],
                                             sorted((p.get("items_used") or {}).items()),
                                             sorted((p.get("items_gained") or {}).items()), sorted(set(p.get("flags_set") or [])),
                                             int(p.get("gold") or 0))
                                            for p in participants)})
        digest = hashlib.sha256(canonical.encode()).hexdigest()
        ids = [p["character_id"] for p in participants]
        if len(set(ids)) != len(ids):
            raise Invalid("Duplicate participant")
        with self.pool.connection() as conn:
            activity: dict | None = None
            if instance_id is not None:
                inst = conn.execute("select * from activity_instances where id=%s", (instance_id,)).fetchone()
                if inst is None or inst["world_id"] != world_id or inst["status"] not in ("active", "finished"):
                    raise Invalid("Unknown or closed activity run")
                activity = self.definition(world_id).activities[inst["activity_id"]]
            res = conn.execute(
                "insert into combat_results (idempotency_key, payload_hash, world_id, outcome, rounds, instance_id) "
                "values (%s,%s,%s,%s,%s,%s) on conflict (idempotency_key) do nothing returning *",
                (key, digest, world_id, outcome, rounds, instance_id)).fetchone()
            if res is None:
                existing = conn.execute("select * from combat_results where idempotency_key=%s", (key,)).fetchone()
                if existing["payload_hash"] != digest:
                    raise Conflict("Idempotency key was already used with a different result")
                return {**_row(existing), "rewards": self._stored_rewards(conn, existing["id"])}, True
            rewards: dict[str, dict] = {}
            for p in participants:
                ok = conn.execute(
                    "select id, flags from characters where id=%s and world_id=%s and status='active' for update",
                    (p["character_id"], world_id)).fetchone()
                if ok is None:  # rolls the whole transaction back: no partial outcomes
                    raise Invalid("Unknown or inactive character %s" % p["character_id"])
                paid = outcome == "players_win" and p["outcome"] != "escaped"
                reward = {"gold": int(p.get("gold") or 0) if paid else 0, "items": {}, "flags": []}
                if paid and activity is not None:
                    for it in activity.get("rewards", {}).get("items", []):
                        reward["items"][it["id"]] = reward["items"].get(it["id"], 0) + it["count"]
                    reward["flags"] = list(activity.get("rewards", {}).get("flags", []))
                    reward["gold"] += int(activity.get("rewards", {}).get("gold", 0))
                    conn.execute("insert into activity_completions (world_id, activity_id, character_id, instance_id) values (%s,%s,%s,%s) "
                                 "on conflict do nothing", (world_id, activity["id"], p["character_id"], instance_id))
                if reward["gold"]:
                    conn.execute("update characters set gold = gold + %s where id=%s", (reward["gold"], p["character_id"]))
                gained = {k: v for k, v in (p.get("items_gained") or {}).items() if v > 0}
                for k, v in reward["items"].items():
                    gained[k] = gained.get(k, 0) + v
                p = {**p, "flags_set": list(p.get("flags_set") or []) + reward["flags"]}
                rewards[str(p["character_id"])] = reward
                for item_id, n in gained.items():  # picked up in the battle: added before the used ones are taken off
                    conn.execute("insert into character_items (character_id, item_id, quantity) values (%s,%s,%s) "
                                 "on conflict (character_id, item_id) do update set quantity = least(99, character_items.quantity + excluded.quantity)",
                                 (p["character_id"], item_id, n))
                new_flags = [f for f in dict.fromkeys(p.get("flags_set") or []) if f not in ok["flags"]]
                if new_flags:
                    conn.execute("update characters set flags=%s where id=%s", (Jsonb(list(ok["flags"]) + new_flags), p["character_id"]))
                used = {k: v for k, v in (p.get("items_used") or {}).items() if v > 0}
                for item_id, n in used.items():
                    left = conn.execute(
                        "update character_items set quantity = quantity - %s where character_id=%s and item_id=%s and quantity >= %s "
                        "returning quantity", (n, p["character_id"], item_id, n)).fetchone()
                    if left is None:  # more used than carried: refuse the whole result
                        raise Invalid("%s used more %s than it carries" % (p["character_id"], item_id))
                    if left["quantity"] == 0:
                        conn.execute("delete from character_items where character_id=%s and item_id=%s", (p["character_id"], item_id))
                conn.execute("insert into combat_result_participants (result_id, character_id, outcome, items_used, rewards) "
                             "values (%s,%s,%s,%s,%s)", (res["id"], p["character_id"], p["outcome"], Jsonb(used), Jsonb(reward)))
        return {**_row(res), "rewards": rewards}, False

    @staticmethod
    def _stored_rewards(conn, result_id) -> dict[str, dict]:
        return {str(r["character_id"]): r["rewards"] for r in conn.execute(
            "select character_id, rewards from combat_result_participants where result_id=%s", (result_id,)).fetchall()}
