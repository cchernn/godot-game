-- Gold: one purse per character. Rewards: what a finished encounter paid each participant, kept with the result so a replayed
-- commit returns the same thing. A result may belong to an activity run (instance_id), whose authored rewards it then applies.
alter table characters add column if not exists gold integer not null default 0 check (gold >= 0);
alter table combat_results add column if not exists instance_id uuid references activity_instances(id) on delete set null;
alter table combat_result_participants add column if not exists rewards jsonb not null default '{}'::jsonb;
