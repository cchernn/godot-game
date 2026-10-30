"""World chat: what players type in the overworld. It lives in this process's memory only (nothing is stored), so it is gone when the API
restarts and a player who opens the chat sees only what is said from then on. One API process is assumed; a second one would need a shared
store. Activity (party) chat is carried by the game server, not here.

The limits (length, messages per window) come from the game's balance file through catalog.json, and the same text rules apply on the
game server (game/shared/domain/chat_rules.gd)."""
import threading
import time
import unicodedata
import uuid
from collections import deque


class ChatError(Exception):
    def __init__(self, message: str, status: int):
        super().__init__(message)
        self.status = status


def clean(text: str, max_length: int) -> str:
    """One line of plain text: control characters and runs of spaces become one space, cut to `max_length`; "" if nothing is left."""
    out: list[str] = []
    last_space = True
    for ch in text:
        if ch.isspace() or unicodedata.category(ch) == "Cc":
            if not last_space:
                out.append(" ")
            last_space = True
        else:
            out.append(ch)
            last_space = False
    return "".join(out).strip()[:max_length].strip()


class ChatBoard:
    def __init__(self, max_length: int, rate_messages: int, rate_seconds: float, keep: int = 100, clock=time.monotonic):
        self.max_length = max_length
        self.rate_messages = rate_messages
        self.rate_seconds = rate_seconds
        self.keep = keep
        self._clock = clock
        self._lock = threading.Lock()
        self._worlds: dict[uuid.UUID, deque] = {}
        self._seq: dict[uuid.UUID, int] = {}
        self._sent: dict[tuple[uuid.UUID, uuid.UUID], deque] = {}

    def post(self, world_id: uuid.UUID, user_id: uuid.UUID, sender: str, text: str) -> dict:
        text = clean(text, self.max_length)
        if not text:
            raise ChatError("Write something first", 422)
        now = self._clock()
        with self._lock:
            sent = self._sent.setdefault((world_id, user_id), deque())
            while sent and now - sent[0] >= self.rate_seconds:
                sent.popleft()
            if len(sent) >= self.rate_messages:
                raise ChatError("You are sending messages too fast", 429)
            sent.append(now)
            seq = self._seq.get(world_id, 0) + 1
            self._seq[world_id] = seq
            msg = {"seq": seq, "from": sender, "text": text, "at": int(time.time()), "user": user_id}
            self._worlds.setdefault(world_id, deque(maxlen=self.keep)).append(msg)
        return self._view(msg, user_id)

    def since(self, world_id: uuid.UUID, user_id: uuid.UUID, after: int | None) -> dict:
        """What was said after message `after`, and the number of the latest message. Without `after` (a first look) nothing from before is shown."""
        with self._lock:
            last = self._seq.get(world_id, 0)
            if after is None:
                return {"messages": [], "last": last}
            found = [m for m in self._worlds.get(world_id, ()) if m["seq"] > after]
        return {"messages": [self._view(m, user_id) for m in found], "last": last}

    def forget(self, world_id: uuid.UUID) -> None:
        """A deleted world's chat goes with it."""
        with self._lock:
            self._worlds.pop(world_id, None)
            self._seq.pop(world_id, None)
            for key in [k for k in self._sent if k[0] == world_id]:
                del self._sent[key]

    @staticmethod
    def _view(m: dict, viewer: uuid.UUID) -> dict:
        return {"seq": m["seq"], "from": m["from"], "text": m["text"], "at": m["at"], "mine": m["user"] == viewer}
