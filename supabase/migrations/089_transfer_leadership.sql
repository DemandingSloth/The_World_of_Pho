-- ============================================================================
-- Migration 089: transfer_leadership — leader hands off control to a member
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 022 (guild_members + guilds.leader_id) applied.
--
-- The current leader picks one of their guild members to become the new leader.
-- In one atomic transaction:
--   1. The new leader's guild_members.role is set to 'leader'.
--   2. The former leader's guild_members.role is set to 'member'.
--   3. guilds.leader_id is updated to the new leader's account id.
--
-- Guards:
--   • Caller must be an active member and the current guild leader.
--   • Target must be an active member of the SAME guild and currently a 'member'
--     (can't transfer to someone already the leader, or to someone outside the guild).
--   • Can't transfer to yourself (no-op but rejected cleanly).
--
-- Returns { ok, new_leader_id, new_leader_username } | { error }.
--   errors: account_not_found, not_in_guild, not_leader, target_not_found,
--           target_not_member, cannot_transfer_to_self
-- ============================================================================

create or replace function public.transfer_leadership(
    p_device_hash      text,
    p_guild_id         uuid,
    p_new_leader_id    uuid
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account   uuid;
    v_member    public.guild_members%rowtype;
    v_guild     public.guilds%rowtype;
    v_target    public.guild_members%rowtype;
    v_username  text;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    if v_account = p_new_leader_id then
        return json_build_object('error', 'cannot_transfer_to_self');
    end if;

    -- Caller must be the active leader.
    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;
    if v_member.role <> 'leader' then
        return json_build_object('error', 'not_leader');
    end if;

    -- Lock guild row.
    select * into v_guild from public.guilds where id = p_guild_id for update;
    if v_guild.leader_id is distinct from v_account then
        return json_build_object('error', 'not_leader');
    end if;

    -- Target must be an active member of the same guild.
    select * into v_target from public.guild_members
    where account_id = p_new_leader_id and guild_id = p_guild_id and left_at is null
    for update;
    if not found then
        return json_build_object('error', 'target_not_found');
    end if;
    if v_target.role <> 'member' then
        -- Target is somehow already the leader (shouldn't happen, but safe guard).
        return json_build_object('error', 'target_not_member');
    end if;

    select username into v_username from public.accounts where id = p_new_leader_id;

    -- ── Atomic swap ──────────────────────────────────────────────────────────
    -- Promote the new leader.
    update public.guild_members set role = 'leader'
    where account_id = p_new_leader_id and guild_id = p_guild_id and left_at is null;

    -- Demote the former leader to member.
    update public.guild_members set role = 'member'
    where account_id = v_account and guild_id = p_guild_id and left_at is null;

    -- Update the denormalised leader reference on the guild.
    update public.guilds set leader_id = p_new_leader_id where id = p_guild_id;

    return json_build_object(
        'ok', true,
        'new_leader_id', p_new_leader_id,
        'new_leader_username', coalesce(v_username, '?')
    );
end;
$$;
grant execute on function public.transfer_leadership(text, uuid, uuid) to anon, authenticated;
