-- Points a character has put into its attributes: {"might": 2, "agility": 1}. Empty = none.
-- The game server checks them against the class's budget when it builds a battle; the API only checks the shape.
alter table characters add column if not exists allocated jsonb not null default '{}'::jsonb;
