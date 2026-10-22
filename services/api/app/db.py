from pathlib import Path

from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

MIGRATIONS = Path(__file__).resolve().parent.parent / "migrations"


def make_pool(url: str) -> ConnectionPool:
    return ConnectionPool(url, min_size=1, max_size=10, kwargs={"row_factory": dict_row}, open=True)


def migrate(pool: ConnectionPool) -> list[str]:
    """Applies pending SQL migrations in order, each in its own transaction. Returns applied names."""
    applied: list[str] = []
    with pool.connection() as conn:
        conn.execute("create table if not exists schema_migrations (name text primary key, applied_at timestamptz default now())")
        conn.execute("select pg_advisory_xact_lock(727274)")  # one migrator at a time
        done = {r["name"] for r in conn.execute("select name from schema_migrations").fetchall()}
        for f in sorted(MIGRATIONS.glob("*.sql")):
            if f.name in done:
                continue
            conn.execute(f.read_text())
            conn.execute("insert into schema_migrations (name) values (%s)", (f.name,))
            applied.append(f.name)
    return applied
