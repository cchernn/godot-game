import hmac
import uuid
from dataclasses import dataclass

import jwt
from jwt import PyJWKClient

from .config import Settings

ASYMMETRIC = ["ES256", "RS256", "EdDSA"]


class AuthError(Exception):
    pass


@dataclass(frozen=True)
class Identity:
    user_id: uuid.UUID
    is_guest: bool = False


class TokenVerifier:
    """Validates Supabase access tokens. The accepted algorithm family is decided by server
    configuration, never by the token header, which prevents algorithm-confusion attacks."""

    def __init__(self, settings: Settings, jwks_client: PyJWKClient | None = None):
        self.settings = settings
        self.jwks = jwks_client or (PyJWKClient(settings.jwks_url, cache_keys=True) if settings.jwks_url else None)

    def verify(self, token: str) -> Identity:
        try:
            alg = jwt.get_unverified_header(token).get("alg", "")
            if alg == "HS256" and self.settings.jwt_secret:
                key, algs = self.settings.jwt_secret, ["HS256"]
            elif alg in ASYMMETRIC and self.jwks is not None:
                key, algs = self.jwks.get_signing_key_from_jwt(token).key, ASYMMETRIC
            else:
                raise AuthError("Unsupported token")
            claims = jwt.decode(
                token, key, algorithms=algs, audience=self.settings.jwt_audience,
                issuer=self.settings.jwt_issuer, leeway=self.settings.jwt_leeway_seconds, options={"require": ["exp", "sub"]},
            )
            user_id = uuid.UUID(str(claims["sub"]))
        except AuthError:
            raise
        except (jwt.PyJWTError, ValueError, KeyError) as e:
            raise AuthError("Invalid token") from e
        guest = bool(claims.get("guest"))
        if guest and not self.settings.guests_enabled:
            raise AuthError("Guest tokens are not accepted by this server")
        return Identity(user_id=user_id, is_guest=guest)


def server_key_ok(settings: Settings, presented: str | None) -> bool:
    expected = settings.server_api_key
    if not expected or not presented:
        return False
    return hmac.compare_digest(presented.encode(), expected.encode())
