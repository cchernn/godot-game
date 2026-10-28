"""Parties: a leader, a roster and a place on the map. A character is always in exactly one party (a lone
character is a party of one). The leader travels the party and starts activities from it; an activity run
(activity_instances) takes the party's roster and, when it ends, the party is idle again at the same node."""
import uuid

import psycopg.errors

from .errors import Conflict, Forbidden, Invalid, NotFound
from .world_repo import _row, _s

# PROVISIONAL: the template rule `max_party_size` overrides this.
DEFAULT_MAX_PARTY_SIZE = 4


class PartyMixin:
    def _char_for(self, conn, world_id, user_id) -> dict:
        c = conn.execute("select * from characters where world_id=%s and user_id=%s and status='active' for update", (world_id, user_id)).fetchone()
        if c is None:
            raise Forbidden("You need an active character in this world")
        return c

    def _max_party_size(self, world_id) -> int:
        return int(self.definition(world_id).rules.get("max_party_size", DEFAULT_MAX_PARTY_SIZE))

    @staticmethod
    def _live_run(conn, party_id) -> dict | None:
        """The activity the party is playing right now, if any."""
        return conn.execute("select * from activity_instances where party_id=%s and status in ('forming','active')", (party_id,)).fetchone()

    @staticmethod
    def _live_party_of(conn, character_id) -> dict | None:
        """The running activity this character is part of, if any (it holds them in place)."""
        return conn.execute("select i.* from activity_instances i join activity_roster r on r.instance_id = i.id "
                            "where r.character_id=%s and i.status in ('forming','active')", (character_id,)).fetchone()

    def _party_of(self, conn, char: dict) -> dict:
        """The character's party, made on the spot (at their node) if they have none yet."""
        p = conn.execute("select p.* from parties p join party_members m on m.party_id = p.id where m.character_id=%s and p.status='open'",
                         (char["id"],)).fetchone()
        if p is not None:
            return p
        node = char["node_id"] or self.definition(char["world_id"]).start_node
        conn.execute("update characters set node_id=%s where id=%s", (node, char["id"]))
        p = conn.execute("insert into parties (world_id, leader_character_id, node_id) values (%s,%s,%s) returning *",
                         (char["world_id"], char["id"], node)).fetchone()
        conn.execute("insert into party_members (party_id, character_id) values (%s,%s)", (p["id"], char["id"]))
        return p

    def ensure_party(self, conn, char: dict) -> dict:
        return self._party_of(conn, char)

    def _detach(self, conn, character_id) -> None:
        """Takes a character out of their party. The longest-standing member leads on; an empty party closes."""
        row = conn.execute("delete from party_members where character_id=%s returning party_id", (character_id,)).fetchone()
        if row is None:
            return
        pid = row["party_id"]
        p = conn.execute("select * from parties where id=%s for update", (pid,)).fetchone()
        if p["leader_character_id"] == character_id:
            nxt = conn.execute("select character_id from party_members where party_id=%s order by joined_at limit 1", (pid,)).fetchone()
            if nxt is None:
                conn.execute("update parties set status='closed', closed_at=now() where id=%s", (pid,))
                conn.execute("update party_join_requests set status='cancelled', decided_at=now() where party_id=%s and status='pending'", (pid,))
            else:
                conn.execute("update parties set leader_character_id=%s where id=%s", (nxt["character_id"], pid))

    def _leader_party(self, conn, party_id, user_id) -> dict:
        p = conn.execute("select p.*, c.user_id leader_user from parties p join characters c on c.id = p.leader_character_id "
                         "where p.id=%s for update of p", (party_id,)).fetchone()
        if p is None or p["status"] != "open":
            raise NotFound("Party not found")
        if p["leader_user"] != user_id:  # the server validates every leader decision
            raise Forbidden("Only the party leader can do that")
        return p

    def _members(self, conn, party_id) -> list[dict]:
        return conn.execute("select c.id, c.user_id, c.name, c.class from party_members m join characters c on c.id = m.character_id "
                            "where m.party_id=%s order by m.joined_at", (party_id,)).fetchall()

    # ---- presence ----

    def _online(self, conn, character_id) -> bool:
        """Seen within the presence window. A character that has never reported in (no heartbeat yet) is given the benefit of the doubt."""
        return conn.execute("select coalesce(last_seen_at > now() - make_interval(secs => %s), true) as online from characters where id=%s",
                            (self.presence_seconds, character_id)).fetchone()["online"]

    def _dissolve(self, conn, party) -> None:
        """Everyone in an idle party goes their own way (each into a party of one at the node they stood at); the leader keeps the old one."""
        members = self._members(conn, party["id"])
        for m in members:
            if m["id"] != party["leader_character_id"]:
                self._detach(conn, m["id"])
                self._party_of(conn, {**m, "world_id": party["world_id"], "node_id": party["node_id"]})
        conn.execute("update party_join_requests set status='cancelled', decided_at=now() where party_id=%s and status='pending'", (party["id"],))

    def touch_presence(self, world_id: uuid.UUID, user_id: uuid.UUID) -> None:
        """The client's heartbeat. A player who was away longer than the presence window is on a new session: if nobody else
        in their idle party is still online, they leave it (a party of one, at the same place). A party that is running an
        activity is left alone; the game server ends that when nobody is connected."""
        if not self.is_member(world_id, user_id):
            raise Forbidden("Not a member of this world")
        with self.pool.connection() as conn:
            char = conn.execute("select * from characters where world_id=%s and user_id=%s and status='active' for update", (world_id, user_id)).fetchone()
            if char is None:
                return
            fresh = self._online(conn, char["id"])
            conn.execute("update characters set last_seen_at=now() where id=%s", (char["id"],))
            if fresh:
                return
            p = self._party_of(conn, char)
            others = [m for m in self._members(conn, p["id"]) if m["id"] != char["id"]]
            if others and self._live_run(conn, p["id"]) is None and not any(self._online(conn, m["id"]) for m in others):
                self._detach(conn, char["id"])
                self._party_of(conn, char)

    def _sweep_offline_parties(self, conn, world_id) -> None:
        """Disbands idle parties of two or more where every member is offline."""
        for p in conn.execute("select p.* from parties p where p.world_id=%s and p.status='open' "
                              "and (select count(*) from party_members m where m.party_id=p.id) > 1", (world_id,)).fetchall():
            if self._live_run(conn, p["id"]) is None and not any(self._online(conn, m["id"]) for m in self._members(conn, p["id"])):
                self._dissolve(conn, p)

    # ---- the player's own party ----

    def my_party(self, world_id: uuid.UUID, user_id: uuid.UUID) -> dict:
        if not self.is_member(world_id, user_id):
            raise Forbidden("Not a member of this world")
        with self.pool.connection() as conn:
            char = self._char_for(conn, world_id, user_id)
            p = self._party_of(conn, char)
            return self._party_rows(conn, [p], world_id, user_id)[0]

    def request_party(self, party_id: uuid.UUID, user_id: uuid.UUID) -> dict:
        """Asks the party's leader to let this player's character in. Only possible from the party's own node."""
        with self.pool.connection() as conn:
            p = conn.execute("select * from parties where id=%s for update", (party_id,)).fetchone()
            if p is None or p["status"] != "open":
                raise NotFound("Party not found")
            if not self.is_member(p["world_id"], user_id):
                raise Forbidden("Not a member of this world")
            char = self._char_for(conn, p["world_id"], user_id)
            mine = self._party_of(conn, char)
            if mine["id"] == p["id"]:
                raise Conflict("Already in this party")
            if len(self._members(conn, mine["id"])) > 1:
                raise Conflict("Leave your party first")
            if self._live_run(conn, mine["id"]) or self._live_run(conn, p["id"]):
                raise Conflict("A party is in the middle of an activity")
            if char["node_id"] != p["node_id"]:
                raise Forbidden("You must be at the party's location to join it")
            if len(self._members(conn, p["id"])) >= self._max_party_size(p["world_id"]):
                raise Conflict("The party is full")
            try:
                req = conn.execute("insert into party_join_requests (party_id, character_id, user_id) values (%s,%s,%s) returning *",
                                   (party_id, char["id"], user_id)).fetchone()
            except psycopg.errors.UniqueViolation as e:
                raise Conflict("You have already asked to join this party") from e
        return _row(req)

    def cancel_party_request(self, party_id: uuid.UUID, user_id: uuid.UUID) -> None:
        with self.pool.connection() as conn:
            done = conn.execute("update party_join_requests set status='cancelled', decided_at=now() "
                                "where party_id=%s and user_id=%s and status='pending' returning id", (party_id, user_id)).fetchone()
        if done is None:
            raise NotFound("No pending request")

    def list_party_requests(self, party_id: uuid.UUID, user_id: uuid.UUID) -> list[dict]:
        with self.pool.connection() as conn:
            p = self._leader_party(conn, party_id, user_id)
            rows = conn.execute("select q.id, q.character_id, q.created_at, c.name, c.class from party_join_requests q "
                                "join characters c on c.id = q.character_id where q.party_id=%s and q.status='pending' order by q.created_at",
                                (p["id"],)).fetchall()
        return [_row(r) for r in rows]

    def decide_party_request(self, party_id: uuid.UUID, user_id: uuid.UUID, request_id: uuid.UUID, approve: bool) -> dict:
        with self.pool.connection() as conn:
            p = self._leader_party(conn, party_id, user_id)
            req = conn.execute("select * from party_join_requests where id=%s and party_id=%s for update", (request_id, party_id)).fetchone()
            if req is None:
                raise NotFound("Request not found")
            if req["status"] != "pending":
                raise Conflict("Request already decided")
            if approve:
                if self._live_run(conn, party_id):
                    raise Conflict("The party is in the middle of an activity")
                if len(self._members(conn, party_id)) >= self._max_party_size(p["world_id"]):
                    raise Conflict("The party is full")
                char = conn.execute("select * from characters where id=%s for update", (req["character_id"],)).fetchone()
                if char["status"] != "active" or char["node_id"] != p["node_id"]:
                    raise Conflict("That player is no longer here")
                theirs = self._party_of(conn, char)
                if self._live_run(conn, theirs["id"]) or len(self._members(conn, theirs["id"])) > 1:
                    raise Conflict("That player has joined another party")
                self._detach(conn, char["id"])
                conn.execute("insert into party_members (party_id, character_id) values (%s,%s)", (party_id, char["id"]))
                # They are in now; any other pending asks of theirs no longer apply.
                conn.execute("update party_join_requests set status='cancelled', decided_at=now() "
                             "where user_id=%s and status='pending' and id<>%s", (req["user_id"], request_id))
            req = conn.execute("update party_join_requests set status=%s, decided_at=now() where id=%s returning *",
                               ("approved" if approve else "rejected", request_id)).fetchone()
        return _row(req)

    def leave_party(self, party_id: uuid.UUID, user_id: uuid.UUID) -> None:
        """Leaves a party for a party of one. Not possible while the party is playing an activity."""
        with self.pool.connection() as conn:
            p = conn.execute("select * from parties where id=%s for update", (party_id,)).fetchone()
            if p is None or p["status"] != "open":
                raise NotFound("Party not found")
            char = self._char_for(conn, p["world_id"], user_id)
            if conn.execute("select 1 from party_members where party_id=%s and character_id=%s", (party_id, char["id"])).fetchone() is None:
                raise NotFound("You are not in this party")
            if self._live_run(conn, party_id):
                raise Conflict("Cannot leave in the middle of an activity")
            if len(self._members(conn, party_id)) == 1:
                raise Conflict("You are already on your own")
            self._detach(conn, char["id"])
            self._party_of(conn, char)

    def set_party_leader(self, party_id: uuid.UUID, user_id: uuid.UUID, character_id: uuid.UUID) -> None:
        """The leader hands the party to another member, while it is not playing an activity."""
        with self.pool.connection() as conn:
            self._leader_party(conn, party_id, user_id)
            if self._live_run(conn, party_id):
                raise Conflict("The party is in the middle of an activity")
            if conn.execute("select 1 from party_members where party_id=%s and character_id=%s", (party_id, character_id)).fetchone() is None:
                raise NotFound("That character is not in this party")
            conn.execute("update parties set leader_character_id=%s where id=%s", (character_id, party_id))

    def travel_party(self, party_id: uuid.UUID, user_id: uuid.UUID, node_id: str) -> dict:
        """Moves the whole party along a discovered route to a neighbouring node. Instant for now: the route's
        travel_days are not used until the campaign clock exists."""
        with self.pool.connection() as conn:
            p = self._leader_party(conn, party_id, user_id)
            if self._live_run(conn, party_id):
                raise Conflict("The party is in the middle of an activity")
            d = self.definition(p["world_id"])
            if node_id not in d.nodes:
                raise Invalid("Unknown location")
            if node_id == p["node_id"]:
                raise Conflict("The party is already there")
            leader = conn.execute("select id from characters where id=%s", (p["leader_character_id"],)).fetchone()
            vis = self._visible(conn, p["world_id"], leader["id"])
            if ("node", node_id) not in vis:
                raise Forbidden("You have not discovered this location")
            linked = any(("route", r["id"]) in vis and {r["from"], r["to"]} == {p["node_id"], node_id} for r in d.routes.values())
            if not linked:
                raise Conflict("There is no known route from here")
            conn.execute("update parties set node_id=%s where id=%s", (node_id, party_id))
            conn.execute("update characters set node_id=%s where id in (select character_id from party_members where party_id=%s)", (node_id, party_id))
            p = conn.execute("select * from parties where id=%s", (party_id,)).fetchone()
            return self._party_rows(conn, [p], p["world_id"], user_id)[0]

    def start_instance(self, party_id: uuid.UUID, user_id: uuid.UUID, activity_id: str) -> dict:
        """The leader starts an activity at the party's node; the run takes the party's roster."""
        try:
            with self.pool.connection() as conn:
                p = self._leader_party(conn, party_id, user_id)
                d = self.definition(p["world_id"])
                act = d.activities.get(activity_id)
                if act is None:
                    raise NotFound("Unknown activity")
                if act["type"] == "shop":
                    raise Conflict("A shop is entered alone, not as a party")
                if self._live_run(conn, party_id):
                    raise Conflict("The party is already playing an activity")
                if d.rules.get("require_location", True) and p["node_id"] != act["node"]:
                    raise Forbidden("The party must be at the activity's location")
                if ("node", act["node"]) not in self._visible(conn, p["world_id"], p["leader_character_id"]):
                    raise Forbidden("You have not discovered this location")
                members = self._members(conn, party_id)
                if len(members) > act["max_players"]:
                    raise Conflict("The party is too big for this activity")
                if conn.execute("select 1 from world_activities where world_id=%s and activity_id=%s and status='completed'",
                                (p["world_id"], activity_id)).fetchone():
                    raise Conflict("This activity is no longer available")
                if act["class"] == "quest":
                    ids = [m["id"] for m in members]
                    if act.get("audience") and any(m["class"] != act["audience"] for m in members):
                        raise Forbidden(f"This quest is for the {act['audience']} class")
                    if conn.execute("select 1 from activity_completions where world_id=%s and activity_id=%s and character_id = any(%s)",
                                    (p["world_id"], activity_id, ids)).fetchone():
                        raise Conflict("A member of the party has already completed this quest")
                inst = conn.execute("insert into activity_instances (world_id, activity_id, kind, leader_character_id, party_id, status) "
                                    "values (%s,%s,%s,%s,%s,'active') returning *",
                                    (p["world_id"], activity_id, "major" if act["class"] == "campaign" else "minor", p["leader_character_id"], party_id)).fetchone()
                for m in members:
                    conn.execute("insert into activity_roster (instance_id, character_id) values (%s,%s)", (inst["id"], m["id"]))
                conn.execute("update party_join_requests set status='cancelled', decided_at=now() where party_id=%s and status='pending'", (party_id,))
        except psycopg.errors.UniqueViolation as e:
            raise Conflict("Another major instance is already active in this world") from e
        return _row(inst)

    # ---- views ----

    def _party_rows(self, conn, rows: list[dict], world_id, user_id) -> list[dict]:
        if not rows:
            return []
        d = self.definition(world_id)
        ids = [r["id"] for r in rows]
        roster = conn.execute("select m.party_id, c.id, c.user_id, c.name, c.class from party_members m join characters c on c.id = m.character_id "
                              "where m.party_id = any(%s) order by m.joined_at", (ids,)).fetchall()
        asked = {r["party_id"] for r in conn.execute("select party_id from party_join_requests where user_id=%s and status='pending'",
                                                      (user_id,)).fetchall()}
        runs = {r["party_id"]: r for r in conn.execute("select * from activity_instances where party_id = any(%s) and status in ('forming','active')",
                                                       (ids,)).fetchall()}
        here = conn.execute("select node_id from characters where world_id=%s and user_id=%s and status='active'", (world_id, user_id)).fetchone()
        cap = self._max_party_size(world_id)
        out = []
        for p in rows:
            members = [{"id": _s(m["id"]), "name": m["name"], "class": m["class"]} for m in roster if m["party_id"] == p["id"]]
            mine = [m for m in roster if m["party_id"] == p["id"] and m["user_id"] == user_id]
            if mine:
                relation = "leader" if mine[0]["id"] == p["leader_character_id"] else "member"
            else:
                relation = "pending" if p["id"] in asked else "none"
            leader = next((m for m in members if m["id"] == _s(p["leader_character_id"])), None)
            run = runs.get(p["id"])
            instance = None
            if run is not None:
                instance = {"id": _s(run["id"]), "activity_id": run["activity_id"], "activity_name": d.activities[run["activity_id"]]["name"],
                            "status": run["status"]}
            at_node = bool(here) and here["node_id"] == p["node_id"]
            out.append({"id": _s(p["id"]), "node_id": p["node_id"], "node_name": d.nodes[p["node_id"]]["name"],
                        "leader": leader, "members": members, "relation": relation, "max_size": cap,
                        "instance": instance, "here": at_node,
                        "open": instance is None and len(members) < cap})
        return out

    def list_parties(self, world_id: uuid.UUID, user_id: uuid.UUID) -> list[dict]:
        """Every party in the world with someone about (and the caller's own), with the caller's relation to each (leader | member | pending | none)."""
        if not self.is_member(world_id, user_id):
            raise Forbidden("Not a member of this world")
        with self.pool.connection() as conn:
            char = conn.execute("select * from characters where world_id=%s and user_id=%s and status='active' for update", (world_id, user_id)).fetchone()
            mine = self._party_of(conn, char)["id"] if char is not None else None  # the caller's own party exists before they look at the list
            self._sweep_offline_parties(conn, world_id)
            rows = conn.execute("select * from parties where world_id=%s and status='open' order by created_at", (world_id,)).fetchall()
            # Nobody to ask in a party whose members are all away (a closed tab, a sign-out): it is left out until one of them comes back.
            rows = [p for p in rows if p["id"] == mine or self._live_run(conn, p["id"]) is not None
                    or any(self._online(conn, m["id"]) for m in self._members(conn, p["id"]))]
            return self._party_rows(conn, rows, world_id, user_id)

    def get_party(self, party_id: uuid.UUID, user_id: uuid.UUID) -> dict:
        with self.pool.connection() as conn:
            p = conn.execute("select * from parties where id=%s", (party_id,)).fetchone()
            if p is None or p["status"] != "open":
                raise NotFound("Party not found")
            if not self.is_member(p["world_id"], user_id):
                raise Forbidden("Not a member of this world")
            return self._party_rows(conn, [p], p["world_id"], user_id)[0]
