-- ============================================================================
-- Migration 043: claim_guild_reward_xp — tokens-since-watermark for XP grants
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Guild missions pay the player marketplace TOKENS on completion (credited in
-- _guild_distribute_reward, logged to token_ledger with reason 'guild_reward').
-- We now also want the player to earn XP for those rewards:
--     XP = guild tokens received x 5
-- (XP is local/client-authoritative, so the server can't grant it directly.)
--
-- This read-only RPC lets the client total the guild_reward tokens it has
-- received SINCE a watermark timestamp, so it can award the matching XP exactly
-- once and advance its watermark. Idempotent: calling again with the updated
-- watermark returns 0 until new rewards arrive.
--
-- p_since_epoch : unix seconds; only ledger rows strictly AFTER this are summed.
--                 Pass 0 on first ever call (sums all historical guild rewards).
-- Returns json: { ok, tokens_since, latest_epoch }
--   tokens_since : sum of positive 'guild_reward' deltas after the watermark
--   latest_epoch : newest guild_reward created_at (unix secs), or p_since_epoch
--                  if there were none — the client stores this as its new mark.
-- ============================================================================

create or replace function public.claim_guild_reward_xp(
    p_device_hash text,
    p_since_epoch  double precision default 0
)
returns json
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_since   timestamptz;
    v_tokens  bigint := 0;
    v_latest  double precision;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_since := to_timestamp(coalesce(p_since_epoch, 0));

    select
        coalesce(sum(delta), 0),
        coalesce(max(extract(epoch from created_at)), coalesce(p_since_epoch, 0))
    into v_tokens, v_latest
    from public.token_ledger
    where account_id = v_account
      and reason = 'guild_reward'
      and delta > 0
      and created_at > v_since;

    -- server_now lets the client anchor its FIRST watermark to deploy time, so
    -- a brand-new player's first reward (earned after now) still awards XP,
    -- while a pre-feature player's historical rewards (before now) do not.
    return json_build_object(
        'ok', true,
        'tokens_since', v_tokens,
        'latest_epoch', v_latest,
        'server_now', extract(epoch from now())
    );
end;
$$;

grant execute on function public.claim_guild_reward_xp(text, double precision) to anon, authenticated;
