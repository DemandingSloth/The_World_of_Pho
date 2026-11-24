-- ============================================================================
-- Marketplace Option B (Task 1/7): mission_templates pool
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- The AUTHORING POOL for per-player rotating online missions. You write many
-- templates here once; the rotation logic (later migration) assigns each
-- account 3 of them at a time, refreshing every 48h.
--
-- IMPORTANT — objective_type must stay SERVER-OBSERVABLE so rewards can't be
-- spoofed. Only these are verifiable from real tables today:
--     make_sale  -> count of the account's sales   (purchases.seller_id = me)
--     purchase   -> count of the account's buys     (purchases.buyer_id  = me)
--     list_item  -> count of listings the account created (listings.seller_id)
-- Add new objective_types ONLY once the server can verify them.
--
-- This migration is ADDITIVE: it does not touch online_missions (the currently
-- shipped 3-mission build keeps working until the rotation swap-over).
-- ============================================================================

create table if not exists public.mission_templates (
    id             uuid        primary key default gen_random_uuid(),
    title          text        not null,
    description    text        not null,
    objective_type text        not null,           -- make_sale | purchase | list_item
    target         int         not null default 1 check (target >= 1),
    reward_tokens  int         not null default 0 check (reward_tokens >= 0),
    weight         int         not null default 100 check (weight >= 1), -- selection weight
    is_enabled     boolean     not null default true,
    created_at     timestamptz not null default now(),
    -- Guard: only allow objective types the server can actually verify.
    constraint mission_templates_objective_ck
        check (objective_type in ('make_sale', 'purchase', 'list_item'))
);

-- Functions only; no client policies (clients never read templates directly,
-- they only ever see their 3 assigned missions via get_mission_status).
alter table public.mission_templates enable row level security;

-- ── Seed a varied starter pool (idempotent: only if the pool is empty) ────────
insert into public.mission_templates (title, description, objective_type, target, reward_tokens, weight)
select * from (values
    -- make_sale tier
    ('First Sale',        'Sell any 1 item on the marketplace.',        'make_sale', 1,  200, 120),
    ('Steady Seller',     'Complete 3 marketplace sales.',              'make_sale', 3,  450, 100),
    ('Merchant''s Hustle','Complete 6 marketplace sales.',              'make_sale', 6,  900,  70),
    ('Trade Baron',       'Complete 10 marketplace sales.',             'make_sale', 10, 1500, 40),
    -- purchase tier
    ('Window Shopper',    'Make 1 marketplace purchase.',               'purchase',  1,  150, 120),
    ('Supply Run',        'Make 4 marketplace purchases.',              'purchase',  4,  500, 100),
    ('Big Spender',       'Make 8 marketplace purchases.',              'purchase',  8, 1100,  60),
    -- list_item tier
    ('Set Up Shop',       'Create 2 marketplace listings.',             'list_item', 2,  300, 120),
    ('Market Stocker',    'Create 5 marketplace listings.',             'list_item', 5,  650, 100),
    ('Full Shelves',      'Create 9 marketplace listings.',             'list_item', 9, 1200,  55)
) as v(title, description, objective_type, target, reward_tokens, weight)
where not exists (select 1 from public.mission_templates);
