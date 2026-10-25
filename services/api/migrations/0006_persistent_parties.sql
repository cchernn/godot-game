-- Parties exist on their own: a leader, a roster and a place on the map. An activity run (activity_instances)
-- is started from a party and takes its roster; when the run ends the party is idle again at the same node.
-- A character is always in exactly one party (a lone character is a party of one); parties are made lazily
-- for characters that predate this migration.
create table parties (
    id uuid primary key default gen_random_uuid(),
    world_id uuid not null references worlds(id) on delete cascade,
    leader_character_id uuid not null references characters(id),
    node_id text not null,
    status text not null default 'open' check (status in ('open', 'closed')),
    created_at timestamptz not null default now(),
    closed_at timestamptz
);
create index parties_world on parties (world_id) where status = 'open';

create table party_members (
    party_id uuid not null references parties(id) on delete cascade,
    character_id uuid not null unique references characters(id),
    joined_at timestamptz not null default now(),
    primary key (party_id, character_id)
);

create table party_join_requests (
    id uuid primary key default gen_random_uuid(),
    party_id uuid not null references parties(id) on delete cascade,
    character_id uuid not null references characters(id),
    user_id uuid not null,
    status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled')),
    created_at timestamptz not null default now(),
    decided_at timestamptz
);
create unique index party_requests_one_pending on party_join_requests (party_id, user_id) where status = 'pending';

alter table activity_instances add column party_id uuid references parties(id);
-- A party starts an activity directly, so a run is never "forming" any more; old rows are left as they were.
drop table instance_join_requests;

alter table parties enable row level security;
alter table party_members enable row level security;
alter table party_join_requests enable row level security;
