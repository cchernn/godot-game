-- Who has completed which activity. A campaign activity is also claimed once per world (world_activities); a quest is done once
-- per character; a plain activity repeats, and still leaves a record here. The list is the roster of the finished run for now.
create table activity_completions (
    world_id uuid not null references worlds(id) on delete cascade,
    activity_id text not null,
    character_id uuid not null references characters(id) on delete cascade,
    instance_id uuid not null references activity_instances(id) on delete cascade,
    completed_at timestamptz not null default now(),
    primary key (world_id, activity_id, character_id, instance_id)
);
create index activity_completions_by_character on activity_completions (character_id);
alter table activity_completions enable row level security;
