-- ============================================================================
-- Migration 106: Sell your guild to the game ("Guild Exchange")
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 103 (guild sales).
--
-- Guild flipping: a leader can now INSTANTLY sell their guild to the game at
-- its floor price instead of waiting for a player to buy it.
--
--   • Same rules as listing (103): leader only, sole member, score >= 50,
--     not already listed.
--   • The seller is paid the floor price in tokens right away and leaves the
--     guild (their horses leave its paddock, they keep them).
--   • The game ("Guild Exchange", a system account) re-lists the guild on the
--     Guilds for Sale board at floor + 5% (rounded up). Players buy it with the
--     normal buy_guild — nothing changes for the buyer.
--   • The game holds at most 3 unsold guilds. When a 4th comes in, its OLDEST
--     unsold guild is destroyed (deleted with all its data) to make room.
--
-- The Guild Exchange is an internal account: its device_hash can never match a
-- real client (clients send a SHA-256 hex hash), so nobody can sign in as it.
-- Tokens paid to it by buyers are effectively removed from circulation.
-- ============================================================================


-- ── The system account ──────────────────────────────────────────────────────
do $$
declare
    v_name text := 'Guild Exchange';
begin
    if not exists (select 1 from public.accounts where device_hash = 'system:guild-exchange') then
        -- Fall back to a suffixed name if a player already owns this one.
        if exists (select 1 from public.accounts where lower(username) = lower(v_name)) then
            v_name := 'Guild Exchange ' || floor(random() * 1000)::int::text;
        end if;
        insert into public.accounts (device_hash, username, token_balance, recovery_hash)
        values ('system:guild-exchange', v_name, 0,
                crypt(encode(gen_random_bytes(24), 'hex'), gen_salt('bf')));
    end if;
end;
$$;

create or replace function public._guild_exchange_account() returns uuid
language sql stable security definer set search_path = public as $$
    select id from public.accounts where device_hash = 'system:guild-exchange';
$$;
revoke all on function public._guild_exchange_account() from anon, authenticated;

-- Max unsold guilds the game holds at once, and its markup.
create or replace function public._guild_exchange_slots() returns int
language sql immutable as $$ select 3; $$;
create or replace function public._guild_exchange_markup() returns numeric
language sql immutable as $$ select 1.05::numeric; $$;


-- ── sell_guild_to_game ──────────────────────────────────────────────────────
-- Returns { ok, paid, new_balance, relisted_price, evicted_guild } | { error }
--   errors: account_not_found, not_in_guild, not_guild_leader, guild_not_empty,
--           score_too_low, already_listed, exchange_unavailable
create or replace function public.sell_guild_to_game(
    p_device_hash text,
    p_guild_id    uuid
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account  uuid;
    v_balance  bigint;
    v_member   public.guild_members%rowtype;
    v_guild    public.guilds%rowtype;
    v_exchange uuid := public._guild_exchange_account();
    q          record;
    v_others   int;
    v_price    bigint;
    v_evict    uuid;
    v_evicted  text;
begin
    if v_exchange is null then
        return json_build_object('error', 'exchange_unavailable');
    end if;

    select id, token_balance into v_account, v_balance
    from public.accounts where device_hash = p_device_hash for update;
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

    -- Serialize exchange slot management.
    perform pg_advisory_xact_lock(hashtextextended('guild_exchange', 0));

    -- Make room: destroy the oldest unsold guild(s) the game holds.
    while (select count(*) from public.guild_sale_listings
           where seller_id = v_exchange and status = 'active')
          >= public._guild_exchange_slots() loop
        select l.guild_id into v_evict
        from public.guild_sale_listings l
        where l.seller_id = v_exchange and l.status = 'active'
        order by l.created_at asc
        limit 1;
        select name into v_evicted from public.guilds where id = v_evict;
        delete from public.guilds where id = v_evict;  -- cascades the listing too
    end loop;

    -- Pay the seller the floor price.
    update public.accounts set token_balance = token_balance + q.floor_price
    where id = v_account;
    insert into public.token_ledger (account_id, delta, reason, ref_id)
    values (v_account, q.floor_price, 'guild_sold_to_game', p_guild_id);

    -- Seller steps out (same as listing): no longer a member; horses leave.
    update public.guild_members set left_at = now() where id = v_member.id;
    delete from public.guild_paddock where guild_id = p_guild_id and owner_id = v_account;

    -- The game takes ownership and re-lists at floor + 5%.
    v_price := ceil(q.floor_price::numeric * public._guild_exchange_markup())::bigint;
    update public.guilds set leader_id = v_exchange, for_sale_by = v_exchange
    where id = p_guild_id;
    insert into public.guild_sale_listings (guild_id, seller_id, price, floor_price)
    values (p_guild_id, v_exchange, v_price, q.floor_price);

    return json_build_object('ok', true,
        'paid',           q.floor_price,
        'new_balance',    v_balance + q.floor_price,
        'relisted_price', v_price,
        'evicted_guild',  v_evicted);
end;
$$;
grant execute on function public.sell_guild_to_game(text, uuid) to anon, authenticated;
