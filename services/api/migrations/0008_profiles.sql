-- A player's chosen name, shown to other players instead of the email address.
create table profiles (
    user_id uuid primary key,
    display_name text not null check (char_length(display_name) between 1 and 24),
    updated_at timestamptz not null default now()
);
alter table profiles enable row level security;
