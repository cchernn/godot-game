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
            if a["node"] not in nodes or a["kind"] not in ("minor", "major"):
                raise TemplateError(f"activity {a['id']} is invalid")
            if not re.fullmatch(r"[a-z0-9_]+", str(a.get("encounter", ""))):
                raise TemplateError(f"activity {a['id']} needs an encounter id")
            if not isinstance(a.get("max_players"), int) or a["max_players"] < 1:
                raise TemplateError(f"activity {a['id']} needs max_players")
            if a.get("one_time") and a["kind"] != "major":
                raise TemplateError("only major activities can be one-time")
            for rv in a.get("on_complete", {}).get("reveal", []):
                if rv["id"] not in {"node": nodes, "route": routes}.get(rv["kind"], {}):
                    raise TemplateError(f"activity {a['id']} reveals unknown {rv}")
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
