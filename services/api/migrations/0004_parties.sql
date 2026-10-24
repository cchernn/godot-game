-- Parties are activity instances with a leader and a roster. Several parties may run the same activity at
-- once; the one-live-major-instance-per-world reservation (instance_one_live_major) stays.
drop index instance_one_live_per_activity;

-- A player asks to join a forming party; the party's leader decides.
create table instance_join_requests (
    id uuid primary key default gen_random_uuid(),
    instance_id uuid not null references activity_instances(id) on delete cascade,
    character_id uuid not null references characters(id),
    user_id uuid not null,
    status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled')),
    created_at timestamptz not null default now(),
    decided_at timestamptz
);
create unique index instance_requests_one_pending on instance_join_requests (instance_id, user_id) where status = 'pending';
alter table instance_join_requests enable row level security;
