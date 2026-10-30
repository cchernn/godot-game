"""Gear and the bag: what a character owns, what it wears, and which consumables it brings into a battle.
Rules about what gear *does* live in the game; this only keeps ownership honest (slots, one piece in one place, no changes mid-run)."""
import uuid

from psycopg.types.json import Jsonb

from . import catalog
from .errors import Conflict, Invalid, NotFound


class GearMixin:
    # ---- reading ----

    def _seed_gear(self, conn, char: dict) -> None:
        """Gives a character its class's starting gear, worn, the first time anyone looks. Once per character."""
        claimed = conn.execute("update characters set gear_seeded = true where id=%s and not gear_seeded returning id", (char["id"],)).fetchone()
        if claimed is None:
            return
        free = list(catalog.places())
        for gear_id in catalog.starting_gear(char["class"]):
            kind = catalog.gear_kind(gear_id)
            place = next((p for p in free if catalog.place_kind(p) == kind), None)
            if place is not None:
                free.remove(place)
            conn.execute("insert into character_gear (character_id, gear_id, equipped_place, source) values (%s,%s,%s,'start')",
                         (char["id"], gear_id, place))

    def _attach_inventory(self, conn, chars: list[dict]) -> None:
        """Adds `gear` ([{id, gear_id, place}], worn first) and `battle_items` (null = automatic) to character dicts, seeding if needed."""
        for c in chars:
            self._seed_gear(conn, c)
        ids = [uuid.UUID(str(c["id"])) for c in chars]
        if not ids:
            return
        rows = conn.execute("select id, character_id, gear_id, equipped_place from character_gear where character_id = any(%s) "
                            "order by acquired_at, id", (ids,)).fetchall()
        chosen = {str(r["id"]): r["battle_items"] for r in conn.execute("select id, battle_items from characters where id = any(%s)", (ids,)).fetchall()}
        order = {p: i for i, p in enumerate(catalog.places())}
        by_char: dict[str, list[dict]] = {}
        for r in rows:
            by_char.setdefault(str(r["character_id"]), []).append(
                {"id": str(r["id"]), "gear_id": r["gear_id"], "place": r["equipped_place"]})
        for c in chars:
            mine = by_char.get(str(c["id"]), [])
            mine.sort(key=lambda g: (order.get(g["place"], len(order)) if g["place"] else len(order)))
            c["gear"] = mine
            c["battle_items"] = chosen.get(str(c["id"]))

    def inventory(self, user_id: uuid.UUID, character_id: uuid.UUID) -> dict:
        with self.pool.connection() as conn:
            return self._inventory(conn, self._own(conn, user_id, character_id, lock=False))

    def _inventory(self, conn, char: dict) -> dict:
        c = {"id": char["id"], "class": char["class"]}
        self._attach_inventory(conn, [c])
        items = conn.execute("select item_id, quantity from character_items where character_id=%s order by item_id", (char["id"],)).fetchall()
        return {"gear": c["gear"], "battle_items": c["battle_items"],
                "items": [{"item_id": i["item_id"], "quantity": i["quantity"]} for i in items], "locked": self._live_party_of(conn, char["id"]) is not None}

    def _own(self, conn, user_id: uuid.UUID, character_id: uuid.UUID, lock: bool = True) -> dict:
        char = conn.execute("select * from characters where id=%s" + (" for update" if lock else ""), (character_id,)).fetchone()
        if char is None or char["user_id"] != user_id or char["status"] != "active":
            raise NotFound("Character not found")
        return char

    def _unlocked(self, conn, char: dict) -> None:
        if self._live_party_of(conn, char["id"]) is not None:
            raise Conflict("You cannot change your gear or bag while an activity is running; finish or leave it first")

    # ---- changing gear ----

    def _piece(self, conn, char: dict, gear_row: uuid.UUID) -> dict:
        row = conn.execute("select * from character_gear where id=%s and character_id=%s for update", (gear_row, char["id"])).fetchone()
        if row is None:
            raise NotFound("You do not own that piece of gear")
        return row

    def equip_gear(self, user_id: uuid.UUID, character_id: uuid.UUID, gear_row: uuid.UUID, place: str) -> dict:
        """Wears a piece in a place of its kind. Whatever was there goes where the piece came from (the bag, or the other hand)."""
        kind = catalog.place_kind(place)
        if kind is None:
            raise Invalid("There is no place called %s" % place)
        with self.pool.connection() as conn:
            char = self._own(conn, user_id, character_id)
            self._unlocked(conn, char)
            self._seed_gear(conn, char)
            piece = self._piece(conn, char, gear_row)
            if catalog.gear_kind(piece["gear_id"]) != kind:
                raise Invalid("%s does not fit in %s" % (piece["gear_id"], place))
            came_from = piece["equipped_place"]
            if came_from != place:
                occupant = conn.execute("select id from character_gear where character_id=%s and equipped_place=%s for update",
                                        (char["id"], place)).fetchone()
                conn.execute("update character_gear set equipped_place = null where id=%s", (piece["id"],))
                if occupant is not None:  # it takes the place the piece came from (the bag, or the other hand)
                    conn.execute("update character_gear set equipped_place = null where id=%s", (occupant["id"],))
                    conn.execute("update character_gear set equipped_place=%s where id=%s", (came_from, occupant["id"]))
                conn.execute("update character_gear set equipped_place=%s where id=%s", (place, piece["id"]))
            return self._inventory(conn, char)

    def unequip_gear(self, user_id: uuid.UUID, character_id: uuid.UUID, gear_row: uuid.UUID) -> dict:
        with self.pool.connection() as conn:
            char = self._own(conn, user_id, character_id)
            self._unlocked(conn, char)
            self._seed_gear(conn, char)
            piece = self._piece(conn, char, gear_row)
            conn.execute("update character_gear set equipped_place = null where id=%s", (piece["id"],))
            return self._inventory(conn, char)

    def discard_gear(self, user_id: uuid.UUID, character_id: uuid.UUID, gear_row: uuid.UUID) -> dict:
        """Throws a piece away for good. It has to be out of the equipment slots first."""
        with self.pool.connection() as conn:
            char = self._own(conn, user_id, character_id)
            self._unlocked(conn, char)
            self._seed_gear(conn, char)
            piece = self._piece(conn, char, gear_row)
            if piece["equipped_place"] is not None:
                raise Conflict("Take it off before throwing it away")
            conn.execute("delete from character_gear where id=%s", (piece["id"],))
            return self._inventory(conn, char)

    # ---- consumables ----

    def set_battle_items(self, user_id: uuid.UUID, character_id: uuid.UUID, kinds: list[str] | None) -> dict:
        """Chooses which consumable kinds go into a battle (null = automatic). Only kinds the character holds, as many as a battle takes."""
        with self.pool.connection() as conn:
            char = self._own(conn, user_id, character_id)
            self._unlocked(conn, char)
            if kinds is not None:
                if len(set(kinds)) != len(kinds):
                    raise Invalid("Each kind can be chosen once")
                if len(kinds) > catalog.battle_slots():
                    raise Invalid("A battle takes at most %d kinds of item" % catalog.battle_slots())
                have = {r["item_id"] for r in conn.execute("select item_id from character_items where character_id=%s and quantity > 0",
                                                           (char["id"],)).fetchall()}
                for k in kinds:
                    if k not in have:
                        raise Invalid("You do not have %s" % k)
            conn.execute("update characters set battle_items=%s where id=%s", (None if kinds is None else Jsonb(kinds), char["id"]))
            return self._inventory(conn, char)

    def discard_items(self, user_id: uuid.UUID, character_id: uuid.UUID, item_id: str, quantity: int) -> dict:
        with self.pool.connection() as conn:
            char = self._own(conn, user_id, character_id)
            self._unlocked(conn, char)
            left = conn.execute("update character_items set quantity = quantity - %s where character_id=%s and item_id=%s and quantity >= %s "
                                "returning quantity", (quantity, char["id"], item_id, quantity)).fetchone()
            if left is None:
                raise Invalid("You do not have that many")
            if left["quantity"] == 0:
                conn.execute("delete from character_items where character_id=%s and item_id=%s", (char["id"], item_id))
                chosen = char["battle_items"]
                if chosen is not None and item_id in chosen:
                    conn.execute("update characters set battle_items=%s where id=%s", (Jsonb([k for k in chosen if k != item_id]), char["id"]))
            return self._inventory(conn, char)

    # ---- getting gear ----

    @staticmethod
    def add_gear(conn, character_id, gear_ids: list[str], source: str) -> None:
        """Puts new, separate pieces in the bag. Unknown ids are refused (the whole transaction rolls back)."""
        for gear_id in gear_ids:
            if catalog.gear_kind(gear_id) is None:
                raise Invalid("Unknown gear %s" % gear_id)
            conn.execute("insert into character_gear (character_id, gear_id, source) values (%s,%s,%s)", (character_id, gear_id, source))

    def grant_gear(self, character_id: uuid.UUID, gear_id: str) -> dict:
        """Dev/admin: gives a character one piece of gear."""
        with self.pool.connection() as conn:
            char = conn.execute("select * from characters where id=%s and status='active' for update", (character_id,)).fetchone()
            if char is None:
                raise NotFound("Character not found")
            self._seed_gear(conn, char)
            self.add_gear(conn, char["id"], [gear_id], "grant")
            return self._inventory(conn, char)
