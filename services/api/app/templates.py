"""World templates: immutable, versioned blueprints. A world pins (template_id, definition_version);
new versions are new files, so editing the latest template can never silently change an existing world."""
import json
import re
from dataclasses import dataclass
from pathlib import Path

from . import catalog

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
ACTIVITY_TYPES = ("battle", "story", "shop", "event")
STEP_TYPES = ("battle", "story")  # what an event chains; an event cannot contain a shop or another event
_ID = r"[a-z0-9_]+"


def _check_rewards(name: str, rewards: dict, nodes: dict, routes: dict) -> None:
    gold = rewards.get("gold", 0)
    if not isinstance(gold, int) or isinstance(gold, bool) or gold < 0:
        raise TemplateError(f"{name} has a bad reward gold {gold!r}")
    for flag in rewards.get("flags", []):
        if not re.fullmatch(_ID, str(flag)):
            raise TemplateError(f"{name} has a bad reward flag {flag!r}")
    for it in rewards.get("items", []):
        if not re.fullmatch(_ID, str(it.get("id", ""))) or not isinstance(it.get("count"), int) or it["count"] < 1:
            raise TemplateError(f"{name} has a bad reward item {it!r}")
    for gear_id in rewards.get("gear", []):
        if catalog.gear_kind(str(gear_id)) is None:
            raise TemplateError(f"{name} rewards unknown gear {gear_id!r}")
    for rv in rewards.get("reveal", []):
        if rv["id"] not in {"node": nodes, "route": routes}.get(rv["kind"], {}):
            raise TemplateError(f"{name} reveals unknown {rv}")


def _check_content(name: str, part: dict, allowed: tuple) -> None:
    kind = part.get("type")
    if kind not in allowed:
        raise TemplateError(f"{name} needs a type: {', '.join(allowed)}")
    content = "encounter" if kind == "battle" else "story"
    if not re.fullmatch(_ID, str(part.get(content, ""))):
        raise TemplateError(f"{name} needs a {content} id")


ENDINGS = ("end", "fail")  # "end" pays the event's rewards, "fail" pays nothing


def step_edges(steps: list[dict]) -> dict[str, list[str]]:
    """Where each step can lead (step ids or endings). A missing `on_win` or `next` goes to the following step in the list (the last goes
    to "end"); a missing `on_lose` is "fail". A story with `choices` leads wherever its choices do."""
    out: dict[str, list[str]] = {}
    for i, step in enumerate(steps):
        after = steps[i + 1]["id"] if i + 1 < len(steps) else "end"
        if step["type"] == "battle":
            out[step["id"]] = [step.get("on_win", after), step.get("on_lose", "fail")]
        elif step.get("choices"):
            out[step["id"]] = [c["next"] for c in step["choices"]]
        else:
            out[step["id"]] = [step.get("next", after)]
    return out


def _check_steps(name: str, steps: list[dict], nodes: dict, routes: dict) -> None:
    ids: set[str] = set()
    for i, step in enumerate(steps):
        where = f"{name} step {i + 1}"
        _check_content(where, step, STEP_TYPES)
        sid = str(step.get("id", ""))
        if not re.fullmatch(_ID, sid) or sid in ENDINGS or sid in ids:
            raise TemplateError(f"{where} needs a unique id (not {' or '.join(ENDINGS)})")
        ids.add(sid)
        _check_rewards(where, step.get("rewards", {}), nodes, routes)
        if "lose_rewards" in step and step["type"] != "battle":
            raise TemplateError(f"{where}: only a battle can be lost")
        _check_rewards(where + " (lost)", step.get("lose_rewards", {}), nodes, routes)
        if step["type"] == "battle" and ("next" in step or "choices" in step):
            raise TemplateError(f"{where}: a battle leads on with on_win and on_lose")
        if step["type"] == "story" and ("on_win" in step or "on_lose" in step):
            raise TemplateError(f"{where}: a story leads on with next or choices")
        if "choices" in step:
            choices = step["choices"]
            if not isinstance(choices, list) or len(choices) < 2 or "next" in step:
                raise TemplateError(f"{where}: choices need two or more options and replace next")
            seen: set[str] = set()
            for c in choices:
                cid = str(c.get("id", ""))
                if not re.fullmatch(_ID, cid) or cid in seen or "next" not in c:
                    raise TemplateError(f"{where} has a bad choice {c!r}")
                seen.add(cid)
                if not all(re.fullmatch(_ID, str(f)) for f in c.get("flags", [])):
                    raise TemplateError(f"{where} choice {cid} has a bad flag")
    edges = step_edges(steps)
    for sid, targets in edges.items():
        for t in targets:
            if t not in ids and t not in ENDINGS:
                raise TemplateError(f"{name}: step {sid} leads to unknown {t!r}")
    state: dict[str, int] = {}  # 1 = on the current path, 2 = done

    def visit(sid: str) -> None:
        if state.get(sid) == 1:
            raise TemplateError(f"{name}: the steps loop back to {sid}")
        if state.get(sid) == 2:
            return
        state[sid] = 1
        for t in edges[sid]:
            if t in ids:
                visit(t)
        state[sid] = 2
    first = steps[0]["id"]
    visit(first)
    unreachable = ids - set(state)
    if unreachable:
        raise TemplateError(f"{name}: steps {sorted(unreachable)} cannot be reached from the first step")
    if not any("end" in edges[s] for s in state):
        raise TemplateError(f"{name}: no path ends the event")


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
    if kind == "shop":
        if a["class"] != "job":
            raise TemplateError(f"{name}: a shop is a job (it is entered alone, any time)")
        stock = a.get("stock")
        if not isinstance(stock, list) or not stock:
            raise TemplateError(f"{name} needs a stock list")
        for line in stock:
            if not re.fullmatch(_ID, str(line.get("item", ""))) or not isinstance(line.get("price"), int) or line["price"] < 1:
                raise TemplateError(f"{name} has a bad stock line {line!r}")
    elif kind == "event":
        steps = a.get("steps")
        if not isinstance(steps, list) or len(steps) < 2:
            raise TemplateError(f"{name} needs at least two steps")
        _check_steps(name, steps, nodes, routes)
        if a.get("on_fail", "restart") not in ("restart", "end"):
            raise TemplateError(f"{name}: on_fail is restart or end")
    else:
        _check_content(name, a, ("battle", "story"))
    if kind != "shop" and (not isinstance(a.get("max_players"), int) or a["max_players"] < 1):
        raise TemplateError(f"{name} needs max_players")
    if "audience" in a and (a["class"] != "quest" or not re.fullmatch(_ID, str(a["audience"]))):
        raise TemplateError(f"{name}: only a quest can name an audience (a class id)")
    _check_rewards(name, a.get("rewards", {}), nodes, routes)


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
