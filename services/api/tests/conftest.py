import pathlib
import sys
import time
import uuid

import jwt
import pgserver
import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(pathlib.Path(__file__).parent.parent))

from app.config import Settings  # noqa: E402
from app.db import make_pool, migrate  # noqa: E402
from app.main import create_app  # noqa: E402

SECRET = "test-secret-test-secret-test-secret-123"
SERVER_KEY = "svc-key-for-tests"


@pytest.fixture(scope="session")
def pg(tmp_path_factory):
    server = pgserver.get_server(tmp_path_factory.mktemp("pgdata"))
    yield server
    server.cleanup()


@pytest.fixture()
def pool(pg):
    """Fresh schema per test."""
    uri = pg.get_uri()
    base = make_pool(uri)
    with base.connection() as c:
        c.execute("drop schema public cascade")
        c.execute("create schema public")
    base.close()
    p = make_pool(uri)
    migrate(p)
    yield p
    p.close()


def make_settings(**kw) -> Settings:
    d = dict(environment="local", allow_guests=True, jwt_secret=SECRET, server_api_key=SERVER_KEY)
    d.update(kw)
    return Settings(_env_file=None, **d)  # never pick up a developer's real .env


@pytest.fixture()
def settings() -> Settings:
    return make_settings()


@pytest.fixture()
def client(pool, settings):
    return TestClient(create_app(settings, pool))


@pytest.fixture()
def keep_xp_client(pool, tmp_path):
    """Like `client`, but the world keeps the XP it awards (the prototype template resets it after every battle)."""
    import json
    from app.templates import DEFAULT_DIR
    d = json.loads((DEFAULT_DIR / "prototype@1.json").read_text())
    d["rules"]["reset_xp_after_battle"] = False
    (tmp_path / "prototype@1.json").write_text(json.dumps(d))
    return TestClient(create_app(make_settings(templates_dir=str(tmp_path)), pool))


def token_for(user_id=None, secret=SECRET, **claims) -> tuple[str, str]:
    uid = str(user_id or uuid.uuid4())
    now = int(time.time())
    payload = {"sub": uid, "aud": "authenticated", "iat": now, "exp": now + 600, **claims}
    return jwt.encode(payload, secret, algorithm="HS256"), uid


def auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


SERVER = {"Authorization": f"Bearer {SERVER_KEY}"}
