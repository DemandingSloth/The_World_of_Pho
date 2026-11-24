-- ============================================================================
-- Migration 069: Guild disband (leader shutdown)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Adds disband_guild: a leader can SHUT DOWN their guild outright, even with
-- other members present. Previously leave_guild blocked a leader with members
-- ('leader_must_transfer'); there was no way for a leader to intentionally close
-- a guild. The client gates this behind explicit warnings (see guild_detail
-- Roster "Leave / Disband" button).
--
-- Deleting the guild row CASCADES to every child table that references
-- guilds(id) ON DELETE CASCADE — guild_members, guild_missions,
-- guild_contributions (via mission), guild_links, guild_link_requests,
-- guild_upgrade_levels, stockpile, store listings, etc. So all inbound/outbound
-- links from OTHER guilds are severed automatically (both guild_links and any
-- pending guild_link_requests in either direction are removed).
-- ============================================================================


-- ── disband_guild ──────────────────────────────────────────────────────────────
-- LEADER-ONLY. Permanently deletes the caller's guild and all of its data.
-- Returns { ok, dissolved: true } | { error }.
--   errors: account_not_found, not_in_guild, not_guild_leader
create or replace function public.disband_guild(
    p_device_hash text,
    p_guild_id    uuid
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
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;

    -- Lock the guild row + confirm the caller is its leader.
    select * into v_guild from public.guilds where id = p_guild_id for update;
    if not found then
        return json_build_object('error', 'not_in_guild');
    end if;
    if v_guild.leader_id is distinct from v_account then
        return json_build_object('error', 'not_guild_leader');
    end if;

    -- Delete the guild. ON DELETE CASCADE on every child FK (including both
    -- guild_links guild FKs and guild_link_requests' requesting/target FKs)
    -- removes all members, missions, contributions, links, pending link
    -- requests, upgrades, stockpile, and store rows in one shot.
    delete from public.guilds where id = p_guild_id;

    return json_build_object('ok', true, 'dissolved', true);
end;
$$;
grant execute on function public.disband_guild(text, uuid) to anon, authenticated;
