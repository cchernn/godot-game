import hashlib
import json
import uuid

import psycopg.errors
from psycopg.types.json import Jsonb
from psycopg_pool import ConnectionPool

from .errors import Conflict, Forbidden, Invalid, NotFound, RepoError  # noqa: F401
from .templates import TemplateError, TemplateStore
from .world_repo import WorldMixin


def _row(r: dict | None) -> dict | None:
    if r is None:
        return None
    return {k: (str(v) if isinstance(v, uuid.UUID) else v) for k, v in r.items()}


class Repository(WorldMixin):
    """All durable reads/writes. Gameplay rules never live here."""

    def __init__(self, pool: ConnectionPool, templates: TemplateStore | None = None):
        self.pool = pool
        self.templates = templates or TemplateStore()

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
                if a.get("one_time"):
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

    def create_character(self, world_id: uuid.UUID, user_id: uuid.UUID, name: str, origin: str, cls: str) -> dict:
        if not self.is_member(world_id, user_id):
            raise Forbidden("Not a member of this world")
        start_node = self.definition(world_id).start_node
        try:
            with self.pool.connection() as conn:
                r = conn.execute(
                    "insert into characters (world_id, user_id, name, origin, class, node_id) values (%s,%s,%s,%s,%s,%s) returning *",
                    (world_id, user_id, name, origin, cls, start_node)).fetchone()
        except psycopg.errors.UniqueViolation as e:
            raise Conflict("You already have an active character in this world") from e
        return _row(r)

    def active_character(self, world_id: uuid.UUID, user_id: uuid.UUID) -> dict | None:
        with self.pool.connection() as conn:
            return _row(conn.execute(
                "select * from characters where world_id=%s and user_id=%s and status='active'", (world_id, user_id)).fetchone())

    def retire_character(self, character_id: uuid.UUID, user_id: uuid.UUID) -> dict:
        with self.pool.connection() as conn:
            r = conn.execute("select * from characters where id=%s for update", (character_id,)).fetchone()
            if r is None or r["user_id"] != user_id:
                raise NotFound("Character not found")
            if r["status"] == "retired":
                return _row(r)
            # TODO(phase 6): refuse while committed to travel or an active activity.
            r = conn.execute("update characters set status='retired', retired_at=now() where id=%s returning *", (character_id,)).fetchone()
        return _row(r)

    # ---- combat results ----

    def commit_combat_result(self, key: str, world_id: uuid.UUID, outcome: str, rounds: int,
                             participants: list[dict]) -> tuple[dict, bool]:
        """Atomically records a finished encounter and applies XP. Idempotent per key: replaying the same
        payload returns the stored result; reusing a key for a different payload is a conflict."""
        canonical = json.dumps({"w": str(world_id), "o": outcome, "r": rounds,
                                "p": sorted((str(p["character_id"]), p["outcome"], p["xp"]) for p in participants)})
        digest = hashlib.sha256(canonical.encode()).hexdigest()
        ids = [p["character_id"] for p in participants]
        if len(set(ids)) != len(ids):
            raise Invalid("Duplicate participant")
        with self.pool.connection() as conn:
            res = conn.execute(
                "insert into combat_results (idempotency_key, payload_hash, world_id, outcome, rounds) "
                "values (%s,%s,%s,%s,%s) on conflict (idempotency_key) do nothing returning *",
                (key, digest, world_id, outcome, rounds)).fetchone()
            if res is None:
                existing = conn.execute("select * from combat_results where idempotency_key=%s", (key,)).fetchone()
                if existing["payload_hash"] != digest:
                    raise Conflict("Idempotency key was already used with a different result")
                return _row(existing), True
            for p in participants:
                ok = conn.execute(
                    "update characters set xp = xp + %s where id=%s and world_id=%s and status='active' returning id",
                    (p["xp"], p["character_id"], world_id)).fetchone()
                if ok is None:  # rolls the whole transaction back: no partial outcomes
                    raise Invalid("Unknown or inactive character %s" % p["character_id"])
                conn.execute("insert into combat_result_participants (result_id, character_id, outcome, xp_awarded) values (%s,%s,%s,%s)",
                             (res["id"], p["character_id"], p["outcome"], p["xp"]))
        return _row(res), False
