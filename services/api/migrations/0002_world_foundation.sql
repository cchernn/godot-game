alter table worlds add column rules jsonb not null default '{}';
alter table worlds add column initialized_at timestamptz not null default now();

-- Removal revokes access but keeps all data; reapproval restores the same membership row.
alter table world_members add column status text not null default 'active' check (status in ('active', 'removed'));

alter table characters add column node_id text;  -- current overworld node (physical presence for activities)

create table world_join_requests (
    id uuid primary key default gen_random_uuid(),
    world_id uuid not null references worlds(id) on delete cascade,
    user_id uuid not null,
    status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
    created_at timestamptz not null default now(),
    decided_at timestamptz,
    decided_by uuid
);
create unique index join_requests_one_pending on world_join_requests (world_id, user_id) where status = 'pending';

-- Discoveries: 'world' scope reveals to everyone; 'character' scope only to that character.
create table world_discoveries (
    id uuid primary key default gen_random_uuid(),
    world_id uuid not null references worlds(id) on delete cascade,
    kind text not null check (kind in ('node', 'route')),
    target_id text not null,
    scope text not null check (scope in ('world', 'character')),
    character_id uuid references characters(id),
    created_at timestamptz not null default now(),
    check ((scope = 'world') = (character_id is null))
);
create unique index discoveries_world_once on world_discoveries (world_id, kind, target_id) where scope = 'world';
create unique index discoveries_character_once on world_discoveries (world_id, kind, target_id, character_id) where scope = 'character';

-- Mutable per-world state of one-time activities (static definitions live in the template).
create table world_activities (
    world_id uuid not null references worlds(id) on delete cascade,
    activity_id text not null,
    status text not null default 'available' check (status in ('available', 'completed')),
    completed_by_instance uuid,
    completed_at timestamptz,
    primary key (world_id, activity_id)
);

create table activity_instances (
    id uuid primary key default gen_random_uuid(),
    world_id uuid not null references worlds(id) on delete cascade,
    activity_id text not null,
    kind text not null check (kind in ('minor', 'major')),
    leader_character_id uuid not null references characters(id),
    status text not null default 'forming' check (status in ('forming', 'active', 'finished', 'cancelled')),
    created_at timestamptz not null default now(),
    ended_at timestamptz
);
-- Atomic reservations: the database itself prevents duplicate instances.
create unique index instance_one_live_per_activity on activity_instances (world_id, activity_id) where status in ('forming', 'active');
create unique index instance_one_live_major on activity_instances (world_id) where kind = 'major' and status in ('forming', 'active');

create table activity_roster (
    instance_id uuid not null references activity_instances(id) on delete cascade,
    character_id uuid not null references characters(id),
    joined_at timestamptz not null default now(),
    primary key (instance_id, character_id)
);

alter table world_join_requests enable row level security;
alter table world_discoveries enable row level security;
alter table world_activities enable row level security;
alter table activity_instances enable row level security;
alter table activity_roster enable row level security;
