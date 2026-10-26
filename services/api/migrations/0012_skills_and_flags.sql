-- Skills a character picked (ids) and event flags it has (strings). Both are lists of lower-case ids; empty = none.
-- The game server checks them against the class's unlock rules when it builds a battle; the API only checks the shape.
alter table characters add column if not exists learned_skills jsonb not null default '[]'::jsonb;
alter table characters add column if not exists flags jsonb not null default '[]'::jsonb;
