-- ============================================================================
-- Migration 103: Sell your guild on the online marketplace
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Rules:
--   • Only the LEADER can list, and only when they are the guild's ONLY member.
--   • Score = (total upgrade levels bought) × (upgrade points available).
--     A guild needs score >= 50 to be listed (stops brand-new guilds being sold).
--   • Price floor (tokens):
--       total levels <= 5   -> score × 1,000
--       total levels <= 10  -> score × 5,000
--       total levels >= 11  -> score × 10,000
--     The seller may ask more, never less.
--   • Listing removes the seller from the guild (no perks; free to join another
--     guild). While they have a guild listed they cannot CREATE a guild, and
--     they cannot BUY another listed guild.
--   • A listed guild is hidden from search / recommendations / leaderboard and
--     cannot be joined.
--   • Everything goes with the guild (upgrades, points, stockpile, warehouse,
--     silo, jewelry pool, store listings, bank, links, garden/mine). The
--     seller's horses are taken out of the guild paddock (they still own them).
--   • Buying: only a player who is NOT in a guild and has no guild listed. The
--     buyer pays tokens to the seller, becomes leader with perks active at once,
--     and every active guild mission is rerolled (free).
--   • Reclaim: a seller who is not in a guild can pay 10,000 tokens to move back
--     in as leader; this removes the listing. (The fee is a token sink.)
-- ============================================================================


-- ── Schema ──────────────────────────────────────────────────────────────────

-- Who has this guild up for sale (NULL = not for sale). The seller keeps
-- ownership (leader_id) while it's listed but is not an active member.
alter table public.guilds
    add column if not exists for_sale_by uuid references public.accounts(id) on delete set null;

create table if not exists public.guild_sale_listings (
    id          uuid        primary key default gen_random_uuid(),
    guild_id    uuid        not null references public.guilds(id) on delete cascade,
    seller_id   uuid        not null references public.accounts(id) on delete cascade,
    price       bigint      not null check (price > 0),
    floor_price bigint      not null,
    status      text        not null default 'active'
                            check (status in ('active', 'sold', 'reclaimed')),
    buyer_id    uuid        references public.accounts(id) on delete set null,
    created_at  timestamptz not null default now(),
    closed_at   timestamptz
);
-- At most one ACTIVE listing per guild and per seller.
create unique index if not exists guild_sale_active_guild_idx
    on public.guild_sale_listings (guild_id) where status = 'active';
create unique index if not exists guild_sale_active_seller_idx
    on public.guild_sale_listings (seller_id) where status = 'active';
alter table public.guild_sale_listings enable row level security;  -- RPCs only


-- ── Helpers ─────────────────────────────────────────────────────────────────

-- Fee to take a listed guild back.
create or replace function public._guild_reclaim_fee() returns bigint
language sql immutable as $$ select 10000::bigint; $$;

-- Minimum score to be allowed to list.
create or replace function public._guild_sale_min_score() returns bigint
language sql immutable as $$ select 50::bigint; $$;

-- { levels, points, score, floor } for a guild.
create or replace function public._guild_sale_quote(p_guild_id uuid)
returns table (levels bigint, points bigint, score bigint, floor_price bigint)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_levels bigint;
    v_points bigint;
    v_score  numeric;
    v_mult   numeric;
begin
    select coalesce(sum(level), 0) into v_levels
    from public.guild_upgrade_levels where guild_id = p_guild_id;
    select coalesce(upgrade_points, 0) into v_points
    from public.guilds where id = p_guild_id;

    v_score := v_levels::numeric * v_points::numeric;
    v_mult  := case when v_levels <= 5  then 1000
                    when v_levels <= 10 then 5000
                    else 10000 end;

    levels      := v_levels;
    points      := v_points;
    score       := least(v_score, 9000000000000000000)::bigint;
    floor_price := least(v_score * v_mult, 9000000000000000000)::bigint;
    return next;
end;
$$;
revoke all on function public._guild_sale_quote(uuid) from anon, authenticated;

-- Makes p_account the active LEADER of p_guild with perks active immediately.
-- Re-uses an existing (guild, account) row if there is one (the table has
-- unique(guild_id, account_id), so a plain insert would fail for a returning
-- player).
create or replace function public._guild_install_leader(p_guild_id uuid, p_account uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.guild_members (guild_id, account_id, role, perks_active_at, joined_at, left_at)
    values (p_guild_id, p_account, 'leader', null, now(), null)
    on conflict (guild_id, account_id) do update
        set role = 'leader', perks_active_at = null, joined_at = now(), left_at = null;
    update public.guilds set leader_id = p_account, for_sale_by = null where id = p_guild_id;
end;
$$;
revoke all on function public._guild_install_leader(uuid, uuid) from anon, authenticated;

-- Rerolls every active mission of a guild for free: refund itemized deposits,
-- drop the old missions, spawn a fresh easy/medium/hard set.
create or replace function public._guild_reroll_all_missions(p_guild_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_id uuid;
begin
    for v_id in
        select id from public.guild_missions
        where guild_id = p_guild_id and status = 'active'
        for update
    loop
        perform public._guild_refund_contributions(v_id);
        delete from public.guild_contributions where mission_id = v_id;
        delete from public.guild_missions where id = v_id;
    end loop;
    perform public._spawn_guild_missions(p_guild_id);
end;
$$;
revoke all on function public._guild_reroll_all_missions(uuid) from anon, authenticated;


-- ── get_guild_sale_quote (leader: what can I list for?) ──────────────────────
-- { ok, levels, points, score, floor, min_score, eligible, others, reason }
create or replace function public.get_guild_sale_quote(p_device_hash text, p_guild_id uuid)
returns json
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_member  public.guild_members%rowtype;
    q         record;
    v_others  int;
    v_reason  text := '';
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;
    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;

    select * into q from public._guild_sale_quote(p_guild_id);
    select count(*) into v_others from public.guild_members
    where guild_id = p_guild_id and account_id <> v_account and left_at is null;

    if v_member.role <> 'leader' then
        v_reason := 'not_guild_leader';
    elsif v_others > 0 then
        v_reason := 'guild_not_empty';
    elsif q.score < public._guild_sale_min_score() then
        v_reason := 'score_too_low';
    end if;

    return json_build_object(
        'ok', true,
        'levels', q.levels, 'points', q.points, 'score', q.score,
        'floor', q.floor_price, 'min_score', public._guild_sale_min_score(),
        'others', v_others, 'eligible', v_reason = '', 'reason', v_reason);
end;
$$;
grant execute on function public.get_guild_sale_quote(text, uuid) to anon, authenticated;


-- ── list_guild_for_sale ─────────────────────────────────────────────────────
-- Errors: account_not_found, not_in_guild, not_guild_leader, guild_not_empty,
--         score_too_low, price_below_floor (+floor), already_listed
create or replace function public.list_guild_for_sale(
    p_device_hash text,
    p_guild_id    uuid,
    p_price       bigint
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_member  public.guild_members%rowtype;
    v_guild   public.guilds%rowtype;
    q         record;
    v_others  int;
    v_id      uuid;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;
    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;

    select * into v_guild from public.guilds where id = p_guild_id for update;
    if v_member.role <> 'leader' or v_guild.leader_id is distinct from v_account then
        return json_build_object('error', 'not_guild_leader');
    end if;
    if v_guild.for_sale_by is not null then
        return json_build_object('error', 'already_listed');
    end if;
    if exists (select 1 from public.guild_sale_listings
               where seller_id = v_account and status = 'active') then
        return json_build_object('error', 'already_listed');
    end if;

    select count(*) into v_others from public.guild_members
    where guild_id = p_guild_id and account_id <> v_account and left_at is null;
    if v_others > 0 then
        return json_build_object('error', 'guild_not_empty', 'others', v_others);
    end if;

    select * into q from public._guild_sale_quote(p_guild_id);
    if q.score < public._guild_sale_min_score() then
        return json_build_object('error', 'score_too_low',
            'score', q.score, 'min_score', public._guild_sale_min_score());
    end if;
    if p_price is null or p_price < q.floor_price or p_price <= 0 then
        return json_build_object('error', 'price_below_floor', 'floor', q.floor_price);
    end if;

    insert into public.guild_sale_listings (guild_id, seller_id, price, floor_price)
    values (p_guild_id, v_account, p_price, q.floor_price)
    returning id into v_id;

    -- Seller steps out: no longer a member (no perks), free to join elsewhere.
    update public.guild_members set left_at = now() where id = v_member.id;
    update public.guilds set for_sale_by = v_account where id = p_guild_id;

    -- Their horses leave the guild paddock (they still own them).
    delete from public.guild_paddock where guild_id = p_guild_id and owner_id = v_account;

    return json_build_object('ok', true, 'listing_id', v_id,
        'price', p_price, 'floor', q.floor_price);
end;
$$;
grant execute on function public.list_guild_for_sale(text, uuid, bigint) to anon, authenticated;


-- ── get_guild_sales (public browse) ─────────────────────────────────────────
-- { now, items:[{ listing_id, guild_id, name, specialization, levels, points,
--   score, price, seller_name, mine }], my_listing: {...} | null }
-- my_listing is the CALLER's own active listing (for the Reclaim panel).
create or replace function public.get_guild_sales(p_device_hash text)
returns json
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_items   json;
    v_mine    json;
begin
    v_account := public._guild_resolve_account(p_device_hash);

    select coalesce(json_agg(row_to_json(r) order by r.price asc), '[]'::json)
    into v_items
    from (
        select l.id as listing_id, g.id as guild_id, g.name, g.specialization,
               q.levels, q.points, q.score, l.price,
               a.username as seller_name,
               (v_account is not null and l.seller_id = v_account) as mine
        from public.guild_sale_listings l
        join public.guilds g on g.id = l.guild_id
        join public.accounts a on a.id = l.seller_id
        cross join lateral public._guild_sale_quote(g.id) q
        where l.status = 'active'
    ) r;

    if v_account is not null then
        select row_to_json(m) into v_mine
        from (
            select l.id as listing_id, g.id as guild_id, g.name, g.specialization,
                   l.price, public._guild_reclaim_fee() as reclaim_fee
            from public.guild_sale_listings l
            join public.guilds g on g.id = l.guild_id
            where l.seller_id = v_account and l.status = 'active'
            limit 1
        ) m;
    end if;

    return json_build_object('now', extract(epoch from now()),
        'items', v_items, 'my_listing', v_mine);
end;
$$;
grant execute on function public.get_guild_sales(text) to anon, authenticated;


-- ── buy_guild ───────────────────────────────────────────────────────────────
-- Errors: account_not_found, already_in_guild, has_guild_for_sale,
--         listing_not_found, cannot_buy_own, insufficient_tokens
create or replace function public.buy_guild(p_device_hash text, p_listing_id uuid)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_buyer   uuid;
    v_balance bigint;
    v_listing public.guild_sale_listings%rowtype;
    v_name    text;
begin
    select id, token_balance into v_buyer, v_balance
    from public.accounts where device_hash = p_device_hash for update;
    if v_buyer is null then
        return json_build_object('error', 'account_not_found');
    end if;
    if (public._guild_active_member(v_buyer)).id is not null then
        return json_build_object('error', 'already_in_guild');
    end if;
    if exists (select 1 from public.guild_sale_listings
               where seller_id = v_buyer and status = 'active') then
        return json_build_object('error', 'has_guild_for_sale');
    end if;

    select * into v_listing from public.guild_sale_listings
    where id = p_listing_id for update;
    if not found or v_listing.status <> 'active' then
        return json_build_object('error', 'listing_not_found');
    end if;
    if v_listing.seller_id = v_buyer then
        return json_build_object('error', 'cannot_buy_own');
    end if;
    if v_balance < v_listing.price then
        return json_build_object('error', 'insufficient_tokens',
            'price', v_listing.price, 'balance', v_balance);
    end if;

    perform 1 from public.guilds where id = v_listing.guild_id for update;

    -- Tokens: buyer -> seller.
    update public.accounts set token_balance = token_balance - v_listing.price where id = v_buyer;
    insert into public.token_ledger (account_id, delta, reason, ref_id)
    values (v_buyer, -v_listing.price, 'guild_sale_buy', v_listing.id);
    update public.accounts set token_balance = token_balance + v_listing.price
    where id = v_listing.seller_id;
    insert into public.token_ledger (account_id, delta, reason, ref_id)
    values (v_listing.seller_id, v_listing.price, 'guild_sale_proceeds', v_listing.id);

    -- Ownership.
    perform public._guild_install_leader(v_listing.guild_id, v_buyer);
    update public.guild_sale_listings
    set status = 'sold', buyer_id = v_buyer, closed_at = now()
    where id = v_listing.id;

    -- Fresh missions for the new owner.
    perform public._guild_reroll_all_missions(v_listing.guild_id);

    select name into v_name from public.guilds where id = v_listing.guild_id;
    return json_build_object('ok', true, 'guild_id', v_listing.guild_id,
        'guild_name', v_name, 'spent', v_listing.price,
        'new_balance', v_balance - v_listing.price);
end;
$$;
grant execute on function public.buy_guild(text, uuid) to anon, authenticated;


-- ── reclaim_guild (seller pays the fee and moves back in) ───────────────────
-- Errors: account_not_found, no_listing, leave_current_guild, insufficient_tokens
create or replace function public.reclaim_guild(p_device_hash text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_balance bigint;
    v_fee     bigint := public._guild_reclaim_fee();
    v_listing public.guild_sale_listings%rowtype;
    v_name    text;
begin
    select id, token_balance into v_account, v_balance
    from public.accounts where device_hash = p_device_hash for update;
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    select * into v_listing from public.guild_sale_listings
    where seller_id = v_account and status = 'active' for update;
    if not found then
        return json_build_object('error', 'no_listing');
    end if;
    if (public._guild_active_member(v_account)).id is not null then
        return json_build_object('error', 'leave_current_guild');
    end if;
    if v_balance < v_fee then
        return json_build_object('error', 'insufficient_tokens',
            'price', v_fee, 'balance', v_balance);
    end if;

    update public.accounts set token_balance = token_balance - v_fee where id = v_account;
    insert into public.token_ledger (account_id, delta, reason, ref_id)
    values (v_account, -v_fee, 'guild_reclaim_fee', v_listing.id);

    perform public._guild_install_leader(v_listing.guild_id, v_account);
    update public.guild_sale_listings
    set status = 'reclaimed', closed_at = now()
    where id = v_listing.id;

    select name into v_name from public.guilds where id = v_listing.guild_id;
    return json_build_object('ok', true, 'guild_id', v_listing.guild_id,
        'guild_name', v_name, 'spent', v_fee, 'new_balance', v_balance - v_fee);
end;
$$;
grant execute on function public.reclaim_guild(text) to anon, authenticated;


-- ── create_guild: blocked while you have a guild for sale (supersedes 078) ──
create or replace function public.create_guild(
    p_device_hash    text,
    p_name           text,
    p_specialization text
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account  uuid;
    v_existing public.guild_members%rowtype;
    v_guild_id uuid;
    v_name     text := trim(p_name);
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_existing := public._guild_active_member(v_account);
    if v_existing.id is not null then
        return json_build_object('error', 'already_in_guild');
    end if;

    if exists (select 1 from public.guild_sale_listings
               where seller_id = v_account and status = 'active') then
        return json_build_object('error', 'has_guild_for_sale');
    end if;

    if length(v_name) < 3 or length(v_name) > 32 then
        return json_build_object('error', 'invalid_name');
    end if;
    if p_specialization not in ('gardening', 'mining', 'horse') then
        return json_build_object('error', 'invalid_specialization');
    end if;

    if exists (select 1 from public.guilds where lower(name) = lower(v_name)) then
        return json_build_object('error', 'guild_name_taken');
    end if;

    insert into public.guilds (name, specialization, capacity)
    values (v_name, p_specialization, 5)
    returning id into v_guild_id;

    insert into public.guild_members (guild_id, account_id, role, perks_active_at)
    values (v_guild_id, v_account, 'leader', null);

    update public.guilds set leader_id = v_account where id = v_guild_id;

    return json_build_object(
        'ok', true,
        'guild', json_build_object(
            'id',             v_guild_id,
            'name',           v_name,
            'specialization', p_specialization,
            'capacity',       5
        )
    );
exception
    when unique_violation then
        return json_build_object('error', 'guild_name_taken');
end;
$$;
grant execute on function public.create_guild(text, text, text) to anon, authenticated;


-- ── join_guild: listed guilds can't be joined (supersedes 023) ──────────────
create or replace function public.join_guild(
    p_device_hash text,
    p_guild_id    uuid
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account      uuid;
    v_existing_mem public.guild_members%rowtype;
    v_guild        public.guilds%rowtype;
    v_member_count int;
    v_perks_at     double precision;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_existing_mem := public._guild_active_member(v_account);
    if v_existing_mem.id is not null then
        return json_build_object('error', 'already_in_guild');
    end if;

    select * into v_guild from public.guilds where id = p_guild_id for update;
    if not found then
        return json_build_object('error', 'guild_not_found');
    end if;
    if v_guild.for_sale_by is not null then
        return json_build_object('error', 'guild_for_sale');
    end if;

    select count(*) into v_member_count
    from public.guild_members
    where guild_id = p_guild_id and left_at is null;

    if v_member_count >= v_guild.capacity then
        return json_build_object('error', 'guild_full');
    end if;

    v_perks_at := public._guild_perks_active_at(v_account, v_guild.specialization);

    insert into public.guild_members (
        guild_id, account_id, role, perks_active_at,
        previous_guild_id, previous_guild_spec
    )
    select
        p_guild_id,
        v_account,
        'member',
        v_perks_at,
        gm_prev.guild_id,
        g_prev.specialization
    from (select 1) as _dummy
    left join public.guild_members gm_prev
        on gm_prev.account_id = v_account
        and gm_prev.left_at is not null
        and gm_prev.left_at = (
            select max(left_at) from public.guild_members
            where account_id = v_account and left_at is not null
        )
    left join public.guilds g_prev on g_prev.id = gm_prev.guild_id;

    return json_build_object('ok', true);
end;
$$;
grant execute on function public.join_guild(text, uuid) to anon, authenticated;


-- ── search_guilds: hide listed guilds (supersedes 023) ──────────────────────
create or replace function public.search_guilds(
    p_device_hash    text,
    p_query          text    default '',
    p_specialization text    default null
)
returns json
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_results json;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    select json_build_object(
        'guilds',
        coalesce(json_agg(row_to_json(r) order by r.member_count desc), '[]'::json)
    ) into v_results
    from (
        select g.id, g.name, g.specialization, g.capacity, g.upgrade_points,
               count(gm.id)::int as member_count
        from public.guilds g
        left join public.guild_members gm
            on gm.guild_id = g.id and gm.left_at is null
        where (p_query = '' or g.name ilike '%' || p_query || '%')
          and (p_specialization is null or g.specialization = p_specialization)
          and g.for_sale_by is null
        group by g.id
        having count(gm.id) < g.capacity
        limit 50
    ) r;

    return v_results;
end;
$$;
grant execute on function public.search_guilds(text, text, text) to anon, authenticated;


-- ── get_top_active_guilds: hide listed guilds (supersedes 038) ──────────────
create or replace function public.get_top_active_guilds(
    p_device_hash    text,
    p_specialization text default null,
    p_limit          int  default 10
)
returns json
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_results json;
    v_limit   int := least(greatest(coalesce(p_limit, 10), 1), 50);
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    select json_build_object(
        'guilds',
        coalesce(
            json_agg(row_to_json(r) order by r.activity_score desc, r.member_count desc, r.name asc),
            '[]'::json)
    ) into v_results
    from (
        select
            g.id, g.name, g.specialization, g.capacity, g.upgrade_points,
            count(distinct gm.id) filter (where gm.left_at is null)::int as member_count,
            count(distinct cm.id)::int as recent_completions,
            (
                count(distinct cm.id) * 10
                + count(distinct gm.id) filter (where gm.left_at is null) * 2
                + least(g.upgrade_points, 500) / 50
            )::int as activity_score
        from public.guilds g
        left join public.guild_members gm on gm.guild_id = g.id
        left join public.guild_missions cm
            on cm.guild_id = g.id
            and cm.status = 'completed'
            and cm.completed_at is not null
            and cm.completed_at >= now() - interval '7 days'
        where (p_specialization is null or g.specialization = p_specialization)
          and g.for_sale_by is null
        group by g.id
        having count(distinct gm.id) filter (where gm.left_at is null) < g.capacity
        order by activity_score desc, member_count desc, g.name asc
        limit v_limit
    ) r;

    return v_results;
end;
$$;
grant execute on function public.get_top_active_guilds(text, text, int) to anon, authenticated;


-- ── get_guild_leaderboard: hide listed guilds (supersedes 087) ──────────────
create or replace function public.get_guild_leaderboard(
    p_device_hash text,
    p_limit        int default 10
)
returns json
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
    v_account   uuid;
    v_member    public.guild_members%rowtype;
    v_my_guild  uuid;
    v_limit     int := least(greatest(coalesce(p_limit, 10), 1), 100);
    v_result    json;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null then
        return json_build_object('error', 'not_in_guild');
    end if;
    v_my_guild := v_member.guild_id;

    select json_build_object(
        'guilds',
        coalesce(json_agg(json_build_object(
            'name',               r.name,
            'specialization',     r.specialization,
            'upgrade_points',     r.upgrade_points,
            'upgrades_purchased', r.upgrades_purchased,
            'score',              r.score,
            'member_count',       r.member_count,
            'is_yours',           (r.id = v_my_guild)
        ) order by r.score desc, r.member_count desc, r.name asc), '[]'::json)
    ) into v_result
    from (
        select
            g.id, g.name, g.specialization, g.upgrade_points,
            coalesce((select sum(gul.level) from public.guild_upgrade_levels gul
                      where gul.guild_id = g.id), 0)::bigint as upgrades_purchased,
            (g.upgrade_points::bigint * coalesce((select sum(gul.level)
                from public.guild_upgrade_levels gul where gul.guild_id = g.id), 0))::bigint as score,
            count(gm.id) filter (where gm.left_at is null)::int as member_count
        from public.guilds g
        left join public.guild_members gm on gm.guild_id = g.id
        where g.for_sale_by is null
        group by g.id
        order by score desc, member_count desc, g.name asc
        limit v_limit
    ) r;

    return v_result;
end;
$$;
grant execute on function public.get_guild_leaderboard(text, int) to anon, authenticated;
