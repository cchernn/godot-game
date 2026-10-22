"""The API's class list (rules.CLASSES) must match the class resources the battle server uses, or a player could
create a character whose class has no stats."""
from pathlib import Path

from app import rules

CLASSES_DIR = Path(__file__).resolve().parents[3] / "game" / "content" / "stats" / "classes"


def test_every_api_class_has_a_stat_resource_and_vice_versa():
    on_disk = {p.stem for p in CLASSES_DIR.glob("*.tres")}
    assert on_disk == set(rules.CLASSES), "game/content/stats/classes and services/api/app/rules.py disagree"
