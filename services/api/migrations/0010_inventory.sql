-- What each character carries. Item ids are defined by the game content (game/content/items), not by this database.
create table character_items (
    character_id uuid not null references characters (id) on delete cascade,
    item_id text not null,
    quantity integer not null check (quantity >= 0),
    primary key (character_id, item_id)
);
alter table character_items enable row level security;

-- Items a character used up in a battle, kept with the battle's result (the result is applied in one transaction).
alter table combat_result_participants add column items_used jsonb not null default '{}'::jsonb;
