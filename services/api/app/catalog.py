"""What the API knows about the game's content: which gear fits which slot, what a class starts with, how many kinds of item go into a
battle. The file is generated from the Godot content (tools/export_catalog.gd) and a game test checks it is current."""
import json
from functools import lru_cache
from pathlib import Path

FILE = Path(__file__).with_name("catalog.json")


@lru_cache(maxsize=1)
def load() -> dict:
    return json.loads(FILE.read_text())


def places() -> list[str]:
    return load()["worn_places"]


_KIND_OF_PLACE = {"weapon_1": "weapon", "weapon_2": "weapon", "armor": "armor", "accessory": "accessory"}


def place_kind(place: str) -> str | None:
    """The kind of gear a worn place takes ("weapon_2" -> "weapon"), or None for a place that does not exist."""
    return _KIND_OF_PLACE.get(place)


def gear_kind(gear_id: str) -> str | None:
    g = load()["gear"].get(gear_id)
    return None if g is None else g["slot"]


def battle_slots() -> int:
    return int(load()["battle_slots"])


def starting_gear(cls: str) -> list[str]:
    return list(load()["classes"].get(cls, {}).get("gear", []))
