import logging
import time
import uuid
from typing import Annotated, Literal

import jwt
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field, field_validator

from . import rules
from .auth import AuthError, Identity, TokenVerifier, server_key_ok
from .config import Settings, get_settings
from .db import make_pool, migrate
from .repo import Conflict, Forbidden, Invalid, Locked, NotFound, Repository, RepoError
from .templates import TemplateStore


class WorldIn(BaseModel):
    name: str = Field(min_length=1, max_length=64)
    template_id: str = Field(default="prototype", max_length=64)


class LeaderIn(BaseModel):
    character_id: uuid.UUID


class TravelIn(BaseModel):
    node_id: str = Field(min_length=1, max_length=64)


class StartActivityIn(BaseModel):
    activity_id: str = Field(min_length=1, max_length=64)


class WorldRenameIn(BaseModel):
    name: str = Field(min_length=1, max_length=64)


class WorldDeleteIn(BaseModel):
    confirm_name: str


class RevealIn(BaseModel):
    kind: Literal["node", "route"]
    target_id: str = Field(max_length=64)
    scope: Literal["world", "character"]
    character_id: uuid.UUID | None = None


class CharacterIn(BaseModel):
    name: str = Field(min_length=1, max_length=32)
    cls: str = Field(alias="class")


class SessionIn(BaseModel):
    token: str = Field(max_length=4096)
    world_id: uuid.UUID
    instance_id: uuid.UUID | None = None  # set when entering a party's battle: the roster is checked too


class ProfileIn(BaseModel):
    display_name: str

    @field_validator("display_name")
    @classmethod
    def _clean(cls, v: str) -> str:
        v = " ".join(v.split())  # trims and collapses whitespace, including tabs and newlines
        if not 1 <= len(v) <= 24 or not v.isprintable():
            raise ValueError("A name is 1 to 24 characters")
        return v


class ParticipantIn(BaseModel):
    character_id: uuid.UUID
    outcome: Literal["survived", "downed", "eliminated", "escaped"]
    xp: int = Field(ge=0, le=100_000)


class CombatResultIn(BaseModel):
    idempotency_key: str = Field(min_length=8, max_length=128)
    world_id: uuid.UUID
    outcome: Literal["players_win", "players_lose", "draw", "escaped"]
    rounds: int = Field(ge=1, le=10_000)
    participants: list[ParticipantIn] = Field(max_length=16)


def create_app(settings: Settings | None = None, pool=None, verifier: TokenVerifier | None = None) -> FastAPI:
    settings = settings or get_settings()
    app = FastAPI(title="Unnamed API")
    app.state.settings = settings

    @app.middleware("http")
    async def keep_errors_inside_cors(request: Request, call_next):
        """Turns an unexpected exception into a JSON 500 *inside* the CORS layer, so a browser sees the real
        status instead of a blocked cross-origin request. (Added before CORS so CORS wraps it.)"""
        try:
            return await call_next(request)
        except Exception:
            logging.getLogger("uvicorn.error").exception("Unhandled error on %s %s", request.method, request.url.path)
            from fastapi.responses import JSONResponse
            return JSONResponse({"detail": "Internal server error"}, status_code=500)

    if settings.cors_origins:
        app.add_middleware(CORSMiddleware, allow_origins=settings.cors_origins,
                           allow_methods=["GET", "POST"], allow_headers=["Authorization", "Content-Type"])
    app.state.verifier = verifier or TokenVerifier(settings)
    if pool is None:
        pool = make_pool(settings.database_url)
        migrate(pool)
    app.state.repo = Repository(pool, TemplateStore(settings.templates_dir), presence_seconds=settings.presence_seconds,
                               session_seconds=settings.session_seconds)

    def repo(request: Request) -> Repository:
        return request.app.state.repo

    def current_user(request: Request, authorization: Annotated[str | None, Header()] = None) -> Identity:
        if not authorization or not authorization.lower().startswith("bearer "):
            raise HTTPException(401, "Missing bearer token")
        try:
            ident = request.app.state.verifier.verify(authorization[7:].strip())
        except AuthError as e:
            raise HTTPException(401, str(e)) from e
        if ident.session_id:  # every call keeps the login alive, and a second login is refused (423) while it is
            request.app.state.repo.claim_session(ident.user_id, ident.session_id)
        return ident

    def server_only(authorization: Annotated[str | None, Header()] = None) -> None:
        presented = authorization[7:].strip() if authorization and authorization.lower().startswith("bearer ") else None
        if not server_key_ok(settings, presented):
            raise HTTPException(401, "Invalid service credentials")

    @app.exception_handler(RepoError)
    def repo_error(_: Request, e: RepoError):
        from fastapi.responses import JSONResponse
        code = {NotFound: 404, Forbidden: 403, Conflict: 409, Locked: 423, Invalid: 422}.get(type(e), 400)
        return JSONResponse({"detail": str(e)}, status_code=code)

    @app.get("/health")
    def health() -> dict:
        return {"status": "ok", "environment": settings.environment, "guests_enabled": settings.guests_enabled}

    @app.post("/dev/guest")
    def dev_guest() -> dict:
        """Local development only: mints a throwaway identity. 404 everywhere else."""
        if not settings.guests_enabled or not settings.jwt_secret:
            raise HTTPException(404)
        uid = uuid.uuid4()
        now = int(time.time())
        claims = {"sub": str(uid), "aud": settings.jwt_audience, "iat": now, "exp": now + 86400, "guest": True}
        if settings.jwt_issuer:
            claims["iss"] = settings.jwt_issuer
        token = jwt.encode(claims, settings.jwt_secret, algorithm="HS256")
        return {"user_id": str(uid), "access_token": token}

    # ---- player-facing (Supabase JWT) ----

    @app.get("/worlds/available")
    def available_worlds(user: Identity = Depends(current_user), r: Repository = Depends(repo)) -> list[dict]:
        return r.browse_worlds(user.user_id)

    @app.post("/worlds", status_code=201)
    def create_world(body: WorldIn, user: Identity = Depends(current_user), r: Repository = Depends(repo)) -> dict:
        return r.create_world(user.user_id, body.name, body.template_id)

    @app.post("/me/session", status_code=204)
    def claim_session(user: Identity = Depends(current_user)) -> None:
        """Claims the account's login (current_user already did) and keeps it alive: the client's heartbeat between worlds."""

    @app.post("/me/session/release", status_code=204)
    def release_session(request: Request, authorization: Annotated[str | None, Header()] = None) -> None:
        """Sign-out. Verifies the token without claiming, so a refused login cannot release the one that holds the account."""
        if not authorization or not authorization.lower().startswith("bearer "):
            raise HTTPException(401, "Missing bearer token")
        try:
            ident = request.app.state.verifier.verify(authorization[7:].strip())
        except AuthError as e:
            raise HTTPException(401, str(e)) from e
        if ident.session_id:
            request.app.state.repo.release_session(ident.user_id, ident.session_id)

    @app.get("/me/profile")
    def get_profile(user: Identity = Depends(current_user), r: Repository = Depends(repo)) -> dict:
        return r.get_profile(user.user_id)

    @app.put("/me/profile")
    def set_profile(body: ProfileIn, user: Identity = Depends(current_user), r: Repository = Depends(repo)) -> dict:
        return r.set_profile(user.user_id, body.display_name)

    @app.get("/worlds")
    def list_worlds(user: Identity = Depends(current_user), r: Repository = Depends(repo)) -> list[dict]:
        return r.list_worlds(user.user_id)

    @app.post("/worlds/{world_id}/characters", status_code=201)
    def create_character(world_id: uuid.UUID, body: CharacterIn, user: Identity = Depends(current_user),
                         r: Repository = Depends(repo)) -> dict:
        if body.cls not in rules.CLASSES:
            raise HTTPException(422, "Unknown class")
        return r.create_character(world_id, user.user_id, body.name, body.cls)

    @app.get("/worlds/{world_id}/characters/me")
    def my_character(world_id: uuid.UUID, user: Identity = Depends(current_user), r: Repository = Depends(repo)) -> dict:
        if not r.is_member(world_id, user.user_id):
            raise HTTPException(403, "Not a member of this world")
        c = r.active_character(world_id, user.user_id)
        if c is None:
            raise HTTPException(404, "No active character")
        return c

    @app.get("/worlds/{world_id}/characters")
    def world_characters(world_id: uuid.UUID, user: Identity = Depends(current_user), r: Repository = Depends(repo)) -> list[dict]:
        return r.list_characters(world_id, user.user_id)

    @app.get("/worlds/{world_id}/characters/me/battles")
    def my_battles(world_id: uuid.UUID, user: Identity = Depends(current_user), r: Repository = Depends(repo)) -> list[dict]:
        return r.recent_battles(world_id, user.user_id)

    @app.post("/characters/{character_id}/retire")
    def retire(character_id: uuid.UUID, user: Identity = Depends(current_user), r: Repository = Depends(repo)) -> dict:
        return r.retire_character(character_id, user.user_id)

    # ---- service-to-service (Godot server) ----

    @app.post("/internal/auth/session", dependencies=[Depends(server_only)])
    def auth_session(body: SessionIn, request: Request, r: Repository = Depends(repo)) -> dict:
        """Godot server forwards the client's access token; identity and world access are decided here."""
        try:
            ident = request.app.state.verifier.verify(body.token)
        except AuthError as e:
            raise HTTPException(401, str(e)) from e
        if ident.session_id:
            r.claim_session(ident.user_id, ident.session_id)
        if not r.is_member(body.world_id, ident.user_id):
            raise HTTPException(403, "Not a member of this world")
        out = {"user_id": str(ident.user_id), "guest": ident.is_guest,
               "character": r.active_character(body.world_id, ident.user_id)}
        if body.instance_id is not None:
            party = r.party_seat(body.instance_id, ident.user_id)
            if party["world_id"] != str(body.world_id):
                raise HTTPException(403, "That party belongs to another world")
            out["instance"] = party
        return out

    @app.post("/internal/combat-results", dependencies=[Depends(server_only)])
    def combat_result(body: CombatResultIn, r: Repository = Depends(repo)) -> dict:
        res, dup = r.commit_combat_result(
            body.idempotency_key, body.world_id, body.outcome, body.rounds,
            [p.model_dump() for p in body.participants])
        return {"result": res, "duplicate": dup}

    # ---- membership ----

    @app.get("/worlds/{world_id}/membership")
    def membership(world_id: uuid.UUID, user: Identity = Depends(current_user), r: Repository = Depends(repo)) -> dict:
        return r.membership(world_id, user.user_id)

    @app.post("/worlds/{world_id}/requests", status_code=201)
    def request_join(world_id: uuid.UUID, user: Identity = Depends(current_user), r: Repository = Depends(repo)) -> dict:
        return r.request_join(world_id, user.user_id, user.email)

    @app.get("/worlds/{world_id}/requests")
    def list_requests(world_id: uuid.UUID, user: Identity = Depends(current_user), r: Repository = Depends(repo)) -> list[dict]:
        return r.list_requests(world_id, user.user_id)

    @app.post("/worlds/{world_id}/requests/{request_id}/{decision}")
    def decide(world_id: uuid.UUID, request_id: uuid.UUID, decision: Literal["approve", "reject"],
               user: Identity = Depends(current_user), r: Repository = Depends(repo)) -> dict:
        return r.decide_request(world_id, user.user_id, request_id, decision == "approve")

    @app.post("/worlds/{world_id}/members/{member_id}/remove", status_code=204)
    def remove_member(world_id: uuid.UUID, member_id: uuid.UUID, user: Identity = Depends(current_user),
                      r: Repository = Depends(repo)) -> None:
        r.remove_member(world_id, user.user_id, member_id)

    @app.get("/worlds/{world_id}/members")
    def members(world_id: uuid.UUID, user: Identity = Depends(current_user), r: Repository = Depends(repo)) -> list[dict]:
        return r.list_members(world_id, user.user_id)

    @app.get("/worlds/{world_id}/info")
    def world_info(world_id: uuid.UUID, user: Identity = Depends(current_user), r: Repository = Depends(repo)) -> dict:
        return r.world_info(world_id, user.user_id)

    @app.post("/worlds/{world_id}/rename")
    def rename_world(world_id: uuid.UUID, body: WorldRenameIn, user: Identity = Depends(current_user),
                     r: Repository = Depends(repo)) -> dict:
        return r.rename_world(world_id, user.user_id, body.name)

    @app.post("/worlds/{world_id}/delete", status_code=204)
    def delete_world(world_id: uuid.UUID, body: WorldDeleteIn, user: Identity = Depends(current_user),
                     r: Repository = Depends(repo)) -> None:
        r.delete_world(world_id, user.user_id, body.confirm_name)

    # ---- world view & activities ----

    @app.get("/worlds/{world_id}/overview")
    def overview(world_id: uuid.UUID, user: Identity = Depends(current_user), r: Repository = Depends(repo)) -> dict:
        return r.overview(world_id, user.user_id)

    @app.get("/worlds/{world_id}/parties")
    def list_parties(world_id: uuid.UUID, user: Identity = Depends(current_user), r: Repository = Depends(repo)) -> list[dict]:
        return r.list_parties(world_id, user.user_id)

    @app.post("/worlds/{world_id}/presence", status_code=204)
    def presence(world_id: uuid.UUID, user: Identity = Depends(current_user), r: Repository = Depends(repo)) -> None:
        r.touch_presence(world_id, user.user_id)

    @app.get("/worlds/{world_id}/parties/me")
    def my_party(world_id: uuid.UUID, user: Identity = Depends(current_user), r: Repository = Depends(repo)) -> dict:
        return r.my_party(world_id, user.user_id)

    @app.get("/parties/{party_id}")
    def get_party(party_id: uuid.UUID, user: Identity = Depends(current_user), r: Repository = Depends(repo)) -> dict:
        return r.get_party(party_id, user.user_id)

    @app.post("/parties/{party_id}/requests", status_code=201)
    def request_party(party_id: uuid.UUID, user: Identity = Depends(current_user), r: Repository = Depends(repo)) -> dict:
        return r.request_party(party_id, user.user_id)

    @app.post("/parties/{party_id}/requests/cancel", status_code=204)
    def cancel_party_request(party_id: uuid.UUID, user: Identity = Depends(current_user), r: Repository = Depends(repo)) -> None:
        r.cancel_party_request(party_id, user.user_id)

    @app.get("/parties/{party_id}/requests")
    def list_party_requests(party_id: uuid.UUID, user: Identity = Depends(current_user), r: Repository = Depends(repo)) -> list[dict]:
        return r.list_party_requests(party_id, user.user_id)

    @app.post("/parties/{party_id}/requests/{request_id}/{decision}")
    def decide_party_request(party_id: uuid.UUID, request_id: uuid.UUID, decision: Literal["approve", "reject"],
                             user: Identity = Depends(current_user), r: Repository = Depends(repo)) -> dict:
        return r.decide_party_request(party_id, user.user_id, request_id, decision == "approve")

    @app.post("/parties/{party_id}/leader", status_code=204)
    def set_leader(party_id: uuid.UUID, body: LeaderIn, user: Identity = Depends(current_user), r: Repository = Depends(repo)) -> None:
        r.set_party_leader(party_id, user.user_id, body.character_id)

    @app.post("/parties/{party_id}/leave", status_code=204)
    def leave_party(party_id: uuid.UUID, user: Identity = Depends(current_user), r: Repository = Depends(repo)) -> None:
        r.leave_party(party_id, user.user_id)

    @app.post("/parties/{party_id}/travel")
    def travel_party(party_id: uuid.UUID, body: TravelIn, user: Identity = Depends(current_user), r: Repository = Depends(repo)) -> dict:
        return r.travel_party(party_id, user.user_id, body.node_id)

    @app.post("/parties/{party_id}/start", status_code=201)
    def start_activity(party_id: uuid.UUID, body: StartActivityIn, user: Identity = Depends(current_user), r: Repository = Depends(repo)) -> dict:
        return r.start_instance(party_id, user.user_id, body.activity_id)

    # ---- service-to-service: world changes ----

    @app.get("/internal/instances/{instance_id}", dependencies=[Depends(server_only)])
    def internal_instance(instance_id: uuid.UUID, r: Repository = Depends(repo)) -> dict:
        return r.get_instance(instance_id)

    @app.post("/internal/instances/{instance_id}/complete", dependencies=[Depends(server_only)])
    def internal_complete(instance_id: uuid.UUID, r: Repository = Depends(repo)) -> dict:
        res, dup = r.complete_instance(instance_id)
        return {**res, "duplicate": dup}

    @app.post("/internal/instances/{instance_id}/cancel", dependencies=[Depends(server_only)])
    def internal_cancel(instance_id: uuid.UUID, r: Repository = Depends(repo)) -> dict:
        return r.cancel_instance(instance_id)

    @app.post("/internal/worlds/{world_id}/reveal", dependencies=[Depends(server_only)])
    def internal_reveal(world_id: uuid.UUID, body: RevealIn, r: Repository = Depends(repo)) -> dict:
        return r.reveal(world_id, body.kind, body.target_id, body.scope, body.character_id)

    return app


def _default_app() -> FastAPI:
    return create_app()


# `uvicorn app.main:app` for deployments; tests use create_app() with explicit settings.
def __getattr__(name: str):
    if name == "app":
        return _default_app()
    raise AttributeError(name)
