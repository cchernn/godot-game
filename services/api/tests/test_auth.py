import time
import uuid

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi.testclient import TestClient

from app.auth import AuthError, TokenVerifier
from app.config import Settings
from app.main import create_app
from conftest import SECRET, auth, make_settings, token_for


def test_guests_only_in_local():
    assert Settings(environment="local", allow_guests=True).guests_enabled
    assert not Settings(environment="production", allow_guests=True).guests_enabled
    assert not Settings(environment="shared", allow_guests=True).guests_enabled


def test_dev_guest_endpoint_disabled_outside_local(pool):
    c = TestClient(create_app(make_settings(environment="production"), pool))
    assert c.post("/dev/guest").status_code == 404


def test_dev_guest_token_works_locally_and_is_rejected_when_guests_off(pool):
    local = TestClient(create_app(make_settings(), pool))
    tok = local.post("/dev/guest").json()["access_token"]
    assert local.get("/worlds", headers=auth(tok)).status_code == 200
    prod = TestClient(create_app(make_settings(environment="production"), pool))
    assert prod.get("/worlds", headers=auth(tok)).status_code == 401, "leaked dev token must not work in production"


def test_missing_expired_wrong_audience_and_bad_signature_rejected(client):
    assert client.get("/worlds").status_code == 401
    expired, _ = token_for(exp=int(time.time()) - 60)
    assert client.get("/worlds", headers=auth(expired)).status_code == 401
    wrong_aud, _ = token_for(aud="someone-else")
    assert client.get("/worlds", headers=auth(wrong_aud)).status_code == 401
    forged, _ = token_for(secret="x" * 40)
    assert client.get("/worlds", headers=auth(forged)).status_code == 401
    none_alg = jwt.encode({"sub": str(uuid.uuid4()), "aud": "authenticated", "exp": int(time.time()) + 60}, None, algorithm="none")
    assert client.get("/worlds", headers=auth(none_alg)).status_code == 401
    ok, _ = token_for()
    assert client.get("/worlds", headers=auth(ok)).status_code == 200


def test_small_clock_skew_is_tolerated_but_large_is_not(client):
    near, _ = token_for(iat=int(time.time()) + 3)  # Supabase's clock slightly ahead of ours
    assert client.get("/worlds", headers=auth(near)).status_code == 200
    far, _ = token_for(iat=int(time.time()) + 120)
    assert client.get("/worlds", headers=auth(far)).status_code == 401


def test_client_supplied_user_id_is_never_trusted(client):
    tok, uid = token_for()
    w = client.post("/worlds", json={"name": "W", "created_by": str(uuid.uuid4())}, headers=auth(tok)).json()
    assert w["created_by"] == uid


def test_asymmetric_tokens_verified_against_jwks_only(settings):
    key = ec.generate_private_key(ec.SECP256R1())

    class FakeJwks:
        def get_signing_key_from_jwt(self, _):
            class K:
                pass
            k = K()
            k.key = key.public_key()
            return k

    v = TokenVerifier(make_settings(jwt_secret=None), jwks_client=FakeJwks())
    now = int(time.time())
    good = jwt.encode({"sub": str(uuid.uuid4()), "aud": "authenticated", "exp": now + 60}, key, algorithm="ES256")
    assert v.verify(good).user_id
    # HS256 token is refused when no shared secret is configured (algorithm confusion guard)
    hs = jwt.encode({"sub": str(uuid.uuid4()), "aud": "authenticated", "exp": now + 60}, "x" * 40, algorithm="HS256")
    with pytest.raises(AuthError):
        v.verify(hs)
    other = ec.generate_private_key(ec.SECP256R1())
    bad = jwt.encode({"sub": str(uuid.uuid4()), "aud": "authenticated", "exp": now + 60}, other, algorithm="ES256")
    with pytest.raises(AuthError):
        v.verify(bad)


def test_internal_endpoints_require_service_key(client):
    body = {"token": "x", "world_id": str(uuid.uuid4())}
    assert client.post("/internal/auth/session", json=body).status_code == 401
    assert client.post("/internal/auth/session", json=body, headers=auth("wrong")).status_code == 401
    tok, _ = token_for()
    assert client.post("/internal/auth/session", json=body, headers=auth(tok)).status_code == 401, "a player token is not a service credential"


def test_cors_headers_only_for_configured_origins(pool):
    c = TestClient(create_app(make_settings(cors_origins=["https://play.example"]), pool))
    ok = c.options("/worlds", headers={"Origin": "https://play.example", "Access-Control-Request-Method": "GET",
                                       "Access-Control-Request-Headers": "authorization"})
    assert ok.headers.get("access-control-allow-origin") == "https://play.example"
    bad = c.options("/worlds", headers={"Origin": "https://evil.example", "Access-Control-Request-Method": "GET"})
    assert "access-control-allow-origin" not in bad.headers
