-- Gear a character owns: every piece is its own row (a drop is a unique copy). Gear ids are defined by the game content
-- (game/content/gear), the slots by services/api/app/catalog.json. `equipped_place` is null while the piece is in the bag.
create table character_gear (
    id uuid primary key default gen_random_uuid(),
    character_id uuid not null references characters (id) on delete cascade,
    gear_id text not null,
    equipped_place text check (equipped_place in ('weapon_1', 'weapon_2', 'armor', 'accessory')),
    source text not null default '',
    acquired_at timestamptz not null default now()
);
create index character_gear_by_character on character_gear (character_id);
create unique index character_gear_one_per_place on character_gear (character_id, equipped_place) where equipped_place is not null;
alter table character_gear enable row level security;

-- A character gets its class's starting gear the first time it is read; `gear_seeded` makes that happen once.
-- `battle_items` = the consumable kinds the player chose to bring into a battle (null = the first kinds, automatically).
alter table characters add column gear_seeded boolean not null default false;
alter table characters add column battle_items jsonb;

-- What each participant earned from the encounter's drops, kept with the result's rewards (rewards already holds it per character).
