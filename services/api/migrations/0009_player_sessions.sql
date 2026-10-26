-- One live login per account. The holder is the Supabase auth session (the `session_id` claim in the access token);
-- a different session is refused while the holder has been heard from recently.
create table player_sessions (
    user_id uuid primary key,
    session_id text not null,
    last_seen_at timestamptz not null default now()
);
alter table player_sessions enable row level security;
