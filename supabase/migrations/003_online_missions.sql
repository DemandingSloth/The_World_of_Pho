-- ============================================================================
-- Marketplace Task 6: online_missions table + get_online_missions (read-only)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Server-defined "Online Special Missions". This step is READ-ONLY on the
-- client: the game fetches and displays active missions. Accepting / verifying /
-- rewarding comes in a later milestone.
--
-- A mission is "active" when now() is within [window_start, window_end) and
-- is_active = true. reward_tokens is the fixed marketplace-token payout.
-- ============================================================================

create table if not exists public.online_missions (
    id            uuid        primary key default gen_random_uuid(),
    title         text        not null,
    description   text        not null,
    objective_type text       not null,          -- e.g. 'make_sale', 'list_item', 'purchase'
    target        int         not null default 1, -- how many of the objective
    reward_tokens int         not null default 0,
    window_start  timestamptz not null default now(),
    window_end    timestamptz not null default (now() + interval '7 days'),
    is_active     boolean     not null default true,
    created_at    timestamptz not null default now()
);

-- Read-only for clients: RLS on, with a SELECT policy limited to currently
-- active missions. No insert/update/delete policies => clients can't modify.
alter table public.online_missions enable row level security;

drop policy if exists "read active online missions" on public.online_missions;
create policy "read active online missions"
    on public.online_missions
    for select
    to anon, authenticated
    using (is_active and now() >= window_start and now() < window_end);

-- Convenience RPC returning active missions as a JSON array, newest window
-- first. (Clients could also select the table directly thanks to the policy,
-- but an RPC keeps the client contract stable as the schema evolves.)
create or replace function public.get_online_missions()
returns json
language sql
security definer
set search_path = public
as $$
    select coalesce(json_agg(m order by m.window_end asc), '[]'::json)
    from (
        select id, title, description, objective_type, target, reward_tokens,
               window_start, window_end
        from public.online_missions
        where is_active and now() >= window_start and now() < window_end
    ) m;
$$;

grant execute on function public.get_online_missions() to anon, authenticated;

-- ── Seed a few sample missions (idempotent-ish: only if table is empty) ──────
insert into public.online_missions (title, description, objective_type, target, reward_tokens, window_end)
select * from (values
    ('First Sale',       'Sell any item on the marketplace.',            'make_sale', 1, 250,  now() + interval '30 days'),
    ('Market Stocker',   'Create 3 marketplace listings.',               'list_item', 3, 500,  now() + interval '30 days'),
    ('Big Spender',      'Complete 5 marketplace purchases.',            'purchase',  5, 750,  now() + interval '30 days')
) as v(title, description, objective_type, target, reward_tokens, window_end)
where not exists (select 1 from public.online_missions);
