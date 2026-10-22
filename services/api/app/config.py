from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="GAME_API_", env_file=".env", extra="ignore")

    environment: str = "local"  # local | shared | production
    allow_guests: bool = False  # honoured only when environment == "local"

    database_url: str = "postgresql://postgres@localhost:5432/postgres"

    # Supabase JWT validation. New projects sign with asymmetric keys published as a JWKS;
    # legacy projects use a shared HS256 secret. Configure whichever the project uses.
    jwks_url: str | None = None
    jwt_secret: str | None = None
    jwt_audience: str = "authenticated"
    jwt_issuer: str | None = None
    jwt_leeway_seconds: int = 10  # tolerated clock skew between Supabase and this host

    # Browser origins allowed to call the API (the web build's origin). Empty = no CORS headers.
    cors_origins: list[str] = []

    templates_dir: str | None = None  # default: services/api/templates

    # Shared secret for service-to-service calls from the Godot server.
    server_api_key: str | None = None

    @property
    def guests_enabled(self) -> bool:
        # Server-side enforcement: guests can never be enabled outside local development.
        return self.environment == "local" and self.allow_guests


def get_settings() -> Settings:
    return Settings()
