-- Presence: when a character's player was last seen in the world (a heartbeat from the client).
alter table characters add column last_seen_at timestamptz;

-- Escape: a battle can end with the party getting away, and a character can leave it.
alter table combat_results drop constraint combat_results_outcome_check;
alter table combat_results add constraint combat_results_outcome_check
    check (outcome in ('players_win', 'players_lose', 'draw', 'escaped'));
alter table combat_result_participants drop constraint combat_result_participants_outcome_check;
alter table combat_result_participants add constraint combat_result_participants_outcome_check
    check (outcome in ('survived', 'downed', 'eliminated', 'escaped'));
