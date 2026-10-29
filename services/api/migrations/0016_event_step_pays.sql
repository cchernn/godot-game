-- What an event step has already paid a character, so replaying a step (a restarted event, a retried request) never pays it twice.
-- step_key is the step id, with ":lose" added for the lose route's payout.
create table event_step_pays (
    instance_id uuid not null references activity_instances(id) on delete cascade,
    step_key text not null,
    character_id uuid not null references characters(id) on delete cascade,
    paid_at timestamptz not null default now(),
    primary key (instance_id, step_key, character_id)
);
alter table event_step_pays enable row level security;
