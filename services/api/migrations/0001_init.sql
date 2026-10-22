-- Durable game records. Access is only through the FastAPI service (RLS on, no policies: deny-all
-- for Supabase anon/authenticated roles; the service connects as a privileged role).
-- user_id values are Supabase auth user ids (uuid); no FK so the schema also runs on plain Postgres.

create table worlds (
    id uuid primary key default gen_random_uuid(),
    name text not null check (length(name) between 1 and 64),
    template_id text not null default 'prototype',
    definition_version integer not null default 1,   -- static world definition version
    state_revision bigint not null default 0,        -- bumps once per atomic shared-world change
    created_by uuid not null,
    created_at timestamptz not null default now()
);

create table world_members (
    world_id uuid not null references worlds(id) on delete cascade,
    user_id uuid not null,
    role text not null default 'member' check (role in ('host', 'member')),
    joined_at timestamptz not null default now(),
    primary key (world_id, user_id)
);

create table characters (
    id uuid primary key default gen_random_uuid(),
    world_id uuid not null,
    user_id uuid not null,
    name text not null check (length(name) between 1 and 32),
    origin text not null,
    class text not null,                             -- permanent
    level integer not null default 1,
    xp bigint not null default 0,
    status text not null default 'active' check (status in ('active', 'retired')),
    created_at timestamptz not null default now(),
    retired_at timestamptz,
    foreign key (world_id, user_id) references world_members(world_id, user_id)
);
-- Exactly one active character per player per world; retired ones stay as history.
create unique index characters_one_active on characters (world_id, user_id) where status = 'active';

create table combat_results (
    id uuid primary key default gen_random_uuid(),
    idempotency_key text not null unique,
    payload_hash text not null,
    world_id uuid not null references worlds(id),
    outcome text not null check (outcome in ('players_win', 'players_lose', 'draw')),
    rounds integer not null,
    created_at timestamptz not null default now()
);

create table combat_result_participants (
    result_id uuid not null references combat_results(id) on delete cascade,
    character_id uuid not null references characters(id),
    outcome text not null check (outcome in ('survived', 'downed', 'eliminated')),
    xp_awarded integer not null default 0 check (xp_awarded >= 0),
    primary key (result_id, character_id)
);

alter table worlds enable row level security;
alter table world_members enable row level security;
alter table characters enable row level security;
alter table combat_results enable row level security;
alter table combat_result_participants enable row level security;
