"""World templates: immutable, versioned blueprints. A world pins (template_id, definition_version);
new versions are new files, so editing the latest template can never silently change an existing world."""
import json
import re
from dataclasses import dataclass
from pathlib import Path

DEFAULT_DIR = Path(__file__).resolve().parent.parent / "templates"
_NAME = re.compile(r"^([a-z0-9_]+)@(\d+)\.json$")


class TemplateError(Exception):
    pass


@dataclass(frozen=True)
class WorldDefinition:
    id: str
    version: int
    start_node: str
    rules: dict
    nodes: dict
    routes: dict
    activities: dict

    def visible_by_default(self) -> list[tuple[str, str]]:
        out = [("node", n["id"]) for n in self.nodes.values() if n.get("initially_visible")]
        out += [("route", r["id"]) for r in self.routes.values() if r.get("initially_visible")]
        return out

    def exists(self, kind: str, target_id: str) -> bool:
        return target_id in {"node": self.nodes, "route": self.routes}.get(kind, {})


def _unique(items: list[dict], what: str) -> dict:
    out: dict = {}
    for i in items:
        if i["id"] in out:
            raise TemplateError(f"duplicate {what} id {i['id']}")
        out[i["id"]] = i
    return out


ACTIVITY_CLASSES = ("campaign", "quest", "job")
ACTIVITY_TYPES = ("battle", "story")
_ID = r"[a-z0-9_]+"


def _check_activity(a: dict, nodes: dict, routes: dict) -> None:
    """An activity has a type (what is played: battle, story) and a class (its role in the world: campaign = once per world,
    quest = once per character, optionally only for one class, job = repeatable). `rewards` is authored per activity."""
    name = f"activity {a['id']}"
    if a["node"] not in nodes:
        raise TemplateError(f"{name} is invalid")
    if a.get("class") not in ACTIVITY_CLASSES:
        raise TemplateError(f"{name} needs a class: {', '.join(ACTIVITY_CLASSES)}")
    kind = a.get("type")
    if kind not in ACTIVITY_TYPES:
        raise TemplateError(f"{name} needs a type: {', '.join(ACTIVITY_TYPES)}")
    content = "encounter" if kind == "battle" else "story"
    if not re.fullmatch(_ID, str(a.get(content, ""))):
        raise TemplateError(f"{name} needs a {content} id")
    if not isinstance(a.get("max_players"), int) or a["max_players"] < 1:
        raise TemplateError(f"{name} needs max_players")
    if "audience" in a and (a["class"] != "quest" or not re.fullmatch(_ID, str(a["audience"]))):
        raise TemplateError(f"{name}: only a quest can name an audience (a class id)")
    rewards = a.get("rewards", {})
    for flag in rewards.get("flags", []):
        if not re.fullmatch(_ID, str(flag)):
            raise TemplateError(f"{name} has a bad reward flag {flag!r}")
    for it in rewards.get("items", []):
        if not re.fullmatch(_ID, str(it.get("id", ""))) or not isinstance(it.get("count"), int) or it["count"] < 1:
            raise TemplateError(f"{name} has a bad reward item {it!r}")
    for rv in rewards.get("reveal", []):
        if rv["id"] not in {"node": nodes, "route": routes}.get(rv["kind"], {}):
            raise TemplateError(f"{name} reveals unknown {rv}")


def parse(raw: dict) -> WorldDefinition:
    try:
        nodes = _unique(raw["nodes"], "node")
        routes = _unique(raw["routes"], "route")
        activities = _unique(raw["activities"], "activity")
        if raw["start_node"] not in nodes:
            raise TemplateError("start_node is not a node")
        for r in routes.values():
            if r["from"] not in nodes or r["to"] not in nodes or r["travel_days"] <= 0:
                raise TemplateError(f"route {r['id']} is invalid")
        for a in activities.values():
            _check_activity(a, nodes, routes)
        return WorldDefinition(raw["id"], int(raw["version"]), raw["start_node"], raw.get("rules", {}), nodes, routes, activities)
    except KeyError as e:
        raise TemplateError(f"missing field {e}") from e


class TemplateStore:
    def __init__(self, directory: Path | None = None):
        self.dir = Path(directory or DEFAULT_DIR)

    def _versions(self, template_id: str) -> dict[int, Path]:
        found = {}
        for f in self.dir.glob("*.json"):
            m = _NAME.match(f.name)
            if m and m.group(1) == template_id:
                found[int(m.group(2))] = f
        return found

    def latest_version(self, template_id: str) -> int:
        v = self._versions(template_id)
        if not v:
            raise TemplateError(f"unknown template {template_id}")
        return max(v)

    def load(self, template_id: str, version: int) -> WorldDefinition:
        path = self._versions(template_id).get(version)
        if path is None:
            raise TemplateError(f"template {template_id}@{version} not found")
        d = parse(json.loads(path.read_text()))
        if d.id != template_id or d.version != version:
            raise TemplateError("template file name and contents disagree")
        return d
