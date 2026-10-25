from pathlib import Path

from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

MIGRATIONS = Path(__file__).resolve().parent.parent / "migrations"


def make_pool(url: str) -> ConnectionPool:
    # prepare_threshold=None: no server-side prepared statements. Supabase's poolers (transaction mode, port 6543,
    # and Supavisor generally) hand out connections that do not keep them, which otherwise fails with
    # "prepared statement already exists" after a few repeats of a query.
    # check: a connection is tested when it is handed out and replaced if the server (Supabase closes idle ones) dropped it;
    # without it the first request after a quiet spell fails with "SSL error: unexpected eof". max_idle recycles idle ones sooner.
    return ConnectionPool(url, min_size=1, max_size=10, max_idle=120, check=ConnectionPool.check_connection,
                          kwargs={"row_factory": dict_row, "prepare_threshold": None}, open=True)


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
