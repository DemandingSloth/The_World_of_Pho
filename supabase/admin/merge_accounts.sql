-- ============================================================================
-- ADMIN: fold an old (locked-out) account into the player's current account
-- ============================================================================
-- Run in the Supabase SQL editor. NOT a migration — run by hand when needed.
--
-- CURRENT account = the one the player uses now (has their device + the
--                   recovery code they saved).        e.g. 'veterst'
-- OLD account     = the locked-out one whose NAME and ASSETS they want back.
--                                                     e.g. 'Anferny'
--
-- Result: the CURRENT account keeps its device + recovery code, takes the OLD
-- account's name, and receives ALL of the OLD account's assets:
--   • token + Benjamin balances added; Money Gun owned if either owned it;
--     the higher Money Gun / horse-prestige levels kept.
--   • every row that points at the OLD account (horses, listings, escrow, bets,
--     missions, ledger, guild membership/leadership, ...) is moved over.
-- The OLD account is kept (not deleted) but emptied, unlinked and renamed
-- '<name>_old' so it can never be used again.
--
-- Guild rule: a player can only be in ONE guild. If BOTH accounts are in a
-- guild, the OLD account's guild is kept and the CURRENT one's membership ends.
--
-- Everything runs in one transaction — any error rolls it all back.
-- ============================================================================


-- ── STEP 1: PREVIEW (read-only). Check these are the right two players. ─────
select username, id, token_balance, benjamin_balance, created_at,
       left(device_hash, 12) as device
from public.accounts
where lower(username) in (lower('Anferny'), lower('veterst'));


-- ── STEP 2: MERGE. Edit the two names if needed, then run. ──────────────────
do $$
declare
    v_old_name     text := 'Anferny';   -- name + assets to recover
    v_current_name text := 'veterst';   -- the account the player uses now
    v_old     public.accounts%rowtype;
    v_cur     public.accounts%rowtype;
    r         record;
    v_n       bigint;
    v_report  text := '';
begin
    select * into v_old from public.accounts where lower(username) = lower(v_old_name)     for update;
    select * into v_cur from public.accounts where lower(username) = lower(v_current_name) for update;
    if v_old.id is null then raise exception 'OLD account % not found', v_old_name; end if;
    if v_cur.id is null then raise exception 'CURRENT account % not found', v_current_name; end if;
    if v_old.id = v_cur.id then raise exception 'Same account'; end if;

    -- One guild max: if both are in a guild, keep the OLD account's.
    if exists (select 1 from public.guild_members where account_id = v_old.id and left_at is null)
       and exists (select 1 from public.guild_members where account_id = v_cur.id and left_at is null) then
        update public.guild_members set left_at = now()
        where account_id = v_cur.id and left_at is null;
        v_report := v_report || E'\n  both were in a guild: kept the old account''s guild';
    end if;

    -- Move every account reference from OLD to CURRENT.
    for r in
        select distinct cl.relname as tbl, att.attname as col
        from pg_constraint con
        join pg_class cl      on cl.oid = con.conrelid
        join pg_namespace ns  on ns.oid = cl.relnamespace
        join pg_attribute att on att.attrelid = con.conrelid and att.attnum = any(con.conkey)
        where con.contype = 'f'
          and con.confrelid = 'public.accounts'::regclass
          and ns.nspname = 'public'
        union
        select c.table_name, c.column_name
        from information_schema.columns c
        where c.table_schema = 'public'
          and c.data_type = 'uuid'
          and c.table_name <> 'accounts'
          and c.column_name in ('account_id', 'owner_id', 'seller_id', 'buyer_id',
                                'leader_id', 'enqueued_by', 'trainer_id', 'for_sale_by')
    loop
        begin
            execute format('update public.%I set %I = $1 where %I = $2', r.tbl, r.col, r.col)
            using v_cur.id, v_old.id;
            get diagnostics v_n = row_count;
            if v_n > 0 then
                v_report := v_report || format(E'\n  %s.%s: %s row(s) moved', r.tbl, r.col, v_n);
            end if;
        exception when unique_violation then
            -- Some row clashes with one the current account already has (e.g.
            -- the same mission slot). Move rows ONE AT A TIME so only the
            -- clashing ones are dropped (the current account's copy stays).
            declare
                v_ctid   tid;
                v_moved  int := 0;
                v_dropped int := 0;
            begin
                for v_ctid in execute format('select ctid from public.%I where %I = $1', r.tbl, r.col)
                    using v_old.id
                loop
                    begin
                        execute format('update public.%I set %I = $1 where ctid = $2', r.tbl, r.col)
                        using v_cur.id, v_ctid;
                        v_moved := v_moved + 1;
                    exception when unique_violation then
                        execute format('delete from public.%I where ctid = $1', r.tbl) using v_ctid;
                        v_dropped := v_dropped + 1;
                    end;
                end loop;
                v_report := v_report || format(E'\n  %s.%s: %s moved, %s duplicate(s) dropped',
                    r.tbl, r.col, v_moved, v_dropped);
            end;
        end;
    end loop;

    -- Free the old name and empty/unlink the old row (kept for the record).
    update public.accounts set
        username         = left(username, 12) || '_old',
        token_balance    = 0,
        benjamin_balance = 0,
        device_hash      = 'merged-into:' || v_cur.id::text
    where id = v_old.id;

    -- Current account: old name + combined balances. Device and recovery code
    -- are NOT touched — the player's saved code keeps working.
    update public.accounts set
        username         = v_old.username,
        token_balance    = token_balance + coalesce(v_old.token_balance, 0),
        benjamin_balance = coalesce(benjamin_balance, 0) + coalesce(v_old.benjamin_balance, 0),
        money_gun_owned  = coalesce(money_gun_owned, false) or coalesce(v_old.money_gun_owned, false)
    where id = v_cur.id;

    -- Higher levels win (columns from later migrations; skipped if absent).
    begin
        execute 'update public.accounts a set
                   money_gun_level = greatest(coalesce(a.money_gun_level,0), coalesce(o.money_gun_level,0))
                 from public.accounts o where a.id = $1 and o.id = $2'
        using v_cur.id, v_old.id;
    exception when undefined_column then null; end;
    begin
        execute 'update public.accounts a set
                   prestige_training_level = greatest(a.prestige_training_level, o.prestige_training_level),
                   prestige_stable_level   = greatest(a.prestige_stable_level,   o.prestige_stable_level)
                 from public.accounts o where a.id = $1 and o.id = $2'
        using v_cur.id, v_old.id;
    exception when undefined_column then null; end;

    raise notice E'Folded % into % (now named %): tokens +%, benjamins +% %',
        v_old_name, v_current_name, v_old.username,
        coalesce(v_old.token_balance, 0), coalesce(v_old.benjamin_balance, 0), v_report;
end $$;


-- ── STEP 3: CHECK. 'Anferny' should now be the player's current account. ────
select username, token_balance, benjamin_balance, left(device_hash, 12) as device
from public.accounts
where lower(username) like lower('Anferny%');
