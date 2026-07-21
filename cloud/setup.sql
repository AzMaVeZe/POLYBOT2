-- PadelZit cloud setup — run once in the Supabase SQL Editor.
-- Safe to run more than once.

create table if not exists public.tournaments (
  id text primary key,
  user_id uuid not null default auth.uid(),
  data jsonb not null,
  is_public boolean not null default false,
  updated_at timestamptz not null default now()
);

-- Add the public-share column if the table already existed from an earlier run.
alter table public.tournaments add column if not exists is_public boolean not null default false;

alter table public.tournaments enable row level security;

-- Owner can do everything with their own rows.
drop policy if exists own_select on public.tournaments;
drop policy if exists own_insert on public.tournaments;
drop policy if exists own_update on public.tournaments;
drop policy if exists own_delete on public.tournaments;
drop policy if exists own_all on public.tournaments;
create policy own_all on public.tournaments
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- Public share links (r.html) read through a fetch-by-exact-id RPC instead of
-- a SELECT policy. A `using (is_public)` policy would let anyone LIST every
-- public tournament of every user with one anonymous request; the RPC requires
-- knowing the exact id (the link token) and returns a single scrubbed row
-- (claims/meIndex — account-linked fields — are stripped server-side).
drop policy if exists public_read on public.tournaments;
create or replace function public.get_public_tournament(tid text)
returns jsonb
language sql stable security definer set search_path = public as $$
  select (data - 'claims') - 'meIndex'
  from public.tournaments
  where id = tid and is_public = true
$$;
revoke all on function public.get_public_tournament(text) from public;
grant execute on function public.get_public_tournament(text) to anon, authenticated;

-- Live sharing WITHOUT an account: the guest device holds a random write
-- token; rows it publishes have no owner (user_id null) and can only be
-- updated or unpublished with that same token, through these RPCs. Accounts
-- never see these rows in their sync (own_all matches auth.uid() = user_id).
alter table public.tournaments alter column user_id drop not null;
alter table public.tournaments add column if not exists write_token text;

create or replace function public.publish_live(tid text, token text, tdata jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if tid is null or token is null or length(token) < 16 or tdata is null then
    raise exception 'bad request';
  end if;
  insert into public.tournaments as t (id, user_id, data, is_public, write_token)
  values (tid, null, tdata, true, token)
  on conflict (id) do update
    set data = excluded.data, is_public = true, updated_at = now()
    where t.user_id is null and t.write_token = excluded.write_token;
end;
$$;
revoke all on function public.publish_live(text, text, jsonb) from public;
grant execute on function public.publish_live(text, text, jsonb) to anon, authenticated;

create or replace function public.stop_live(tid text, token text)
returns void language sql security definer set search_path = public as $$
  update public.tournaments set is_public = false
  where id = tid and user_id is null and write_token = token;
$$;
revoke all on function public.stop_live(text, text) from public;
grant execute on function public.stop_live(text, text) to anon, authenticated;

-- Player profiles + personal roster. Each account has a display name, an
-- optional unique nickname, and a private roster (the players they organize
-- for). Rows are readable/writable by their owner only.
create table if not exists public.profiles (
  user_id uuid primary key default auth.uid(),
  email text not null,
  name text,
  nickname text,
  roster jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);
create unique index if not exists profiles_nickname_key
  on public.profiles (lower(nickname))
  where nickname is not null and nickname <> '';
alter table public.profiles enable row level security;
drop policy if exists profiles_own on public.profiles;
create policy profiles_own on public.profiles
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- Directory lookup: find one registered player by EXACT email or nickname.
-- Deliberately not a free-text search (no user enumeration); returns only the
-- public fields, to signed-in callers.
create or replace function public.find_player(q text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('uid', user_id, 'name', name, 'nickname', nickname)
  from public.profiles
  where lower(email) = lower(trim(q))
     or (nickname is not null and nickname <> '' and lower(nickname) = lower(trim(q)))
  limit 1
$$;
revoke all on function public.find_player(text) from public, anon;
grant execute on function public.find_player(text) to authenticated;

-- ============================================================================
-- Friends: mutual-consent graph, invite links, and a friends-only engagement
-- leaderboard (usage-based points, separate from tournament win/loss ranking).
-- ============================================================================

-- friend_edges has NO direct-access policies on purpose: RLS is enabled with
-- zero policies, which denies every PostgREST request against the table
-- outright. Every read and write goes through a SECURITY DEFINER RPC below,
-- so auth.uid() is always checked explicitly and there is one audited path
-- for every mutation (mirrors the RPC-only approach used elsewhere in this
-- schema for anything that needs cross-account visibility).
create table if not exists public.friend_edges (
  requester uuid not null references auth.users(id) on delete cascade,
  addressee uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  primary key (requester, addressee),
  check (requester <> addressee)
);
alter table public.friend_edges enable row level security;

-- Each account gets a standing invite token (like the live-share write token)
-- that identifies them in a shareable link. Regenerating it invalidates any
-- link already sent.
alter table public.profiles add column if not exists friend_token uuid not null default gen_random_uuid();

create or replace function public.reset_friend_token()
returns uuid language plpgsql security definer set search_path = public as $$
declare new_token uuid := gen_random_uuid();
begin
  update public.profiles set friend_token = new_token where user_id = auth.uid();
  if not found then
    insert into public.profiles (user_id, email, friend_token)
    values (auth.uid(), (select email from auth.users where id = auth.uid()), new_token);
  end if;
  return new_token;
end;
$$;
revoke all on function public.reset_friend_token() from public, anon;
grant execute on function public.reset_friend_token() to authenticated;

-- Resolve an invite link's token to the inviter's public display info, for
-- the "X invited you — accept?" confirmation screen. Creates nothing yet.
-- Open to anon too (unlike find_player): a friend_token is a high-entropy
-- random uuid handed only to whoever received the link, not a guessable
-- email/nickname, so showing "X invited you" before sign-in carries no
-- enumeration risk — same reasoning as the anonymous get_public_tournament
-- read for a share-link id.
create or replace function public.resolve_invite(token uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('uid', user_id, 'name', name, 'nickname', nickname)
  from public.profiles where friend_token = token
$$;
revoke all on function public.resolve_invite(uuid) from public;
grant execute on function public.resolve_invite(uuid) to anon, authenticated;

-- Accepting an invite link IS the second party's explicit consent (they had
-- to tap Accept on the confirmation screen), so this creates an ACCEPTED edge
-- directly — no separate pending step, unlike the email-search path below.
create or replace function public.accept_invite(token uuid)
returns text language plpgsql security definer set search_path = public as $$
declare inviter uuid;
begin
  select user_id into inviter from public.profiles where friend_token = token;
  if inviter is null then return 'not_found'; end if;
  if inviter = auth.uid() then return 'self'; end if;
  if exists (
    select 1 from public.friend_edges
    where (requester=inviter and addressee=auth.uid()) or (requester=auth.uid() and addressee=inviter)
  ) then
    update public.friend_edges set status='accepted', responded_at=now()
      where (requester=inviter and addressee=auth.uid()) or (requester=auth.uid() and addressee=inviter);
  else
    insert into public.friend_edges (requester, addressee, status, responded_at)
    values (inviter, auth.uid(), 'accepted', now());
  end if;
  return 'accepted';
end;
$$;
revoke all on function public.accept_invite(uuid) from public, anon;
grant execute on function public.accept_invite(uuid) to authenticated;

-- Send a friend request by EXACT email — same anti-enumeration rule as
-- find_player: a miss returns 'not_found' either way, never confirming or
-- denying an account beyond what find_player already discloses.
create or replace function public.request_friend(target_email text)
returns text language plpgsql security definer set search_path = public as $$
declare target uuid;
begin
  select user_id into target from public.profiles where lower(email) = lower(trim(target_email));
  if target is null then return 'not_found'; end if;
  if target = auth.uid() then return 'self'; end if;
  if exists (
    select 1 from public.friend_edges
    where status='accepted'
      and ((requester=auth.uid() and addressee=target) or (requester=target and addressee=auth.uid()))
  ) then
    return 'already_friends';
  end if;
  if exists (select 1 from public.friend_edges where requester=auth.uid() and addressee=target and status='pending') then
    return 'already_pending';
  end if;
  if exists (select 1 from public.friend_edges where requester=target and addressee=auth.uid() and status='pending') then
    -- They already asked us first — accept it instead of creating a mirror row.
    update public.friend_edges set status='accepted', responded_at=now()
      where requester=target and addressee=auth.uid();
    return 'accepted';
  end if;
  insert into public.friend_edges (requester, addressee) values (auth.uid(), target);
  return 'sent';
end;
$$;
revoke all on function public.request_friend(text) from public, anon;
grant execute on function public.request_friend(text) to authenticated;

create or replace function public.respond_friend_request(requester_uid uuid, do_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if do_accept then
    update public.friend_edges set status='accepted', responded_at=now()
      where requester=requester_uid and addressee=auth.uid() and status='pending';
  else
    delete from public.friend_edges where requester=requester_uid and addressee=auth.uid() and status='pending';
  end if;
end;
$$;
revoke all on function public.respond_friend_request(uuid, boolean) from public, anon;
grant execute on function public.respond_friend_request(uuid, boolean) to authenticated;

create or replace function public.unfriend(other_uid uuid)
returns void language sql security definer set search_path = public as $$
  delete from public.friend_edges
  where (requester=auth.uid() and addressee=other_uid) or (requester=other_uid and addressee=auth.uid());
$$;
revoke all on function public.unfriend(uuid) from public, anon;
grant execute on function public.unfriend(uuid) to authenticated;

-- What the app needs on load: accepted friends + incoming pending requests.
create or replace function public.list_friend_state()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'friends', coalesce((
      select jsonb_agg(jsonb_build_object('uid', p.user_id, 'name', p.name, 'nickname', p.nickname))
      from public.friend_edges e
      join public.profiles p on p.user_id = (case when e.requester = auth.uid() then e.addressee else e.requester end)
      where (e.requester = auth.uid() or e.addressee = auth.uid()) and e.status = 'accepted'
    ), '[]'::jsonb),
    'pending', coalesce((
      select jsonb_agg(jsonb_build_object('uid', p.user_id, 'name', p.name, 'nickname', p.nickname, 'since', e.created_at))
      from public.friend_edges e
      join public.profiles p on p.user_id = e.requester
      where e.addressee = auth.uid() and e.status = 'pending'
    ), '[]'::jsonb)
  )
$$;
revoke all on function public.list_friend_state() from public, anon;
grant execute on function public.list_friend_state() to authenticated;

-- ----------------------------------------------------------------------------
-- Engagement stats + friends leaderboard.
--
-- Deliberately NOT computed by parsing tournament history jsonb in SQL: the
-- client already has tested, trusted logic (recompute/rankOrder) for exactly
-- this — who played, who won, who's champion — so it computes per-tournament
-- totals for its own claimed players and reports the TOTALS (not raw scores)
-- here. The server only re-validates cheap invariants (caller owns the
-- tournament, the player is actually claimed in it, reported counts can't
-- exceed the tournament's real game count) and otherwise trusts the organizer
-- the same way it already trusts them for the scores themselves — there is no
-- independent referee in this app, on-device or server-side, so this doesn't
-- add a new trust boundary. Reading is still gated to accepted friends only,
-- and only ever returns summed points, never raw tournament content.
create table if not exists public.tournament_player_stats (
  tournament_id text not null references public.tournaments(id) on delete cascade,
  player_uid uuid not null references auth.users(id) on delete cascade,
  games_played int not null default 0,
  games_won int not null default 0,
  finished boolean not null default false,
  is_champion boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (tournament_id, player_uid)
);
alter table public.tournament_player_stats enable row level security;
-- Also RPC-only (no direct policies) — see friend_edges comment above.

create or replace function public.sync_tournament_stats(tid text, stats jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  owner uuid;
  hist_len int;
  plist_len int;
  is_finished boolean;
  tclaims jsonb;
  rec jsonb;
  p_uid uuid;
  g_played int;
  g_won int;
  is_champ boolean;
begin
  select user_id, jsonb_array_length(coalesce(data->'history','[]'::jsonb)),
         jsonb_array_length(coalesce(data->'players','[]'::jsonb)),
         coalesce((data->>'finished')::boolean, false),
         data->'claims'
    into owner, hist_len, plist_len, is_finished, tclaims
    from public.tournaments where id = tid;
  if owner is null or owner <> auth.uid() then return; end if;
  if plist_len < 4 or hist_len < 3 then return; end if; -- below the "counts at all" threshold
  if tclaims is null or jsonb_typeof(tclaims) <> 'object' then return; end if;

  for rec in select * from jsonb_array_elements(coalesce(stats, '[]'::jsonb))
  loop
    p_uid := nullif(rec->>'uid', '')::uuid;
    if p_uid is null or not (tclaims ? p_uid::text) then continue; end if; -- must be claimed here
    g_played := greatest(0, least(coalesce((rec->>'played')::int, 0), hist_len));
    g_won := greatest(0, least(coalesce((rec->>'won')::int, 0), g_played));
    is_champ := coalesce((rec->>'champion')::boolean, false) and is_finished;
    insert into public.tournament_player_stats
      (tournament_id, player_uid, games_played, games_won, finished, is_champion, updated_at)
    values (tid, p_uid, g_played, g_won, is_finished, is_champ, now())
    on conflict (tournament_id, player_uid) do update
      set games_played = excluded.games_played, games_won = excluded.games_won,
          finished = excluded.finished, is_champion = excluded.is_champion, updated_at = now();
  end loop;
end;
$$;
revoke all on function public.sync_tournament_stats(text, jsonb) from public, anon;
grant execute on function public.sync_tournament_stats(text, jsonb) to authenticated;

-- Engagement score per tournament-player-slot: 1/game played, +2 more (3 total)
-- if won, +3 for finishing an eligible tournament, +10 for winning it outright.
-- month_score resets naturally each calendar month (drives a fresh, low-
-- pressure leaderboard); alltime_score is shown only as a career/tenure stat,
-- not a competitive axis (see product notes for why: avoids punishing anyone
-- who joins later).
create or replace function public.get_friends_leaderboard()
returns table (
  uid uuid, name text, nickname text,
  month_score int, alltime_score int,
  titles int, games_won int
)
language sql stable security definer set search_path = public as $$
  with circle as (
    select auth.uid() as u
    union
    select case when e.requester = auth.uid() then e.addressee else e.requester end
    from public.friend_edges e
    where (e.requester = auth.uid() or e.addressee = auth.uid()) and e.status = 'accepted'
  ),
  scored as (
    select
      s.player_uid,
      (s.games_played + s.games_won * 2
        + (case when s.finished then 3 else 0 end)
        + (case when s.is_champion then 10 else 0 end)) as pts,
      s.is_champion, s.games_won, s.updated_at
    from public.tournament_player_stats s
    join circle c on c.u = s.player_uid
  )
  -- All aggregates qualify with scored.* — profiles also has updated_at, so an
  -- unqualified reference is ambiguous.
  select p.user_id, p.name, p.nickname,
    coalesce(sum(scored.pts) filter (where scored.updated_at >= date_trunc('month', now())), 0)::int as month_score,
    coalesce(sum(scored.pts), 0)::int as alltime_score,
    coalesce(sum(1) filter (where scored.is_champion), 0)::int as titles,
    coalesce(sum(scored.games_won), 0)::int as games_won
  from circle c
  join public.profiles p on p.user_id = c.u
  left join scored on scored.player_uid = c.u
  group by p.user_id, p.name, p.nickname
  order by month_score desc, alltime_score desc
$$;
revoke all on function public.get_friends_leaderboard() from public, anon;
grant execute on function public.get_friends_leaderboard() to authenticated;

-- Self-serve account + data deletion (GDPR / Israeli PPL right to erasure).
-- Deletes only the caller's own rows and auth user via auth.uid(). friend_edges
-- and tournament_player_stats rows referencing this uid are cleaned up by
-- their own ON DELETE CASCADE foreign keys to auth.users when the user row
-- goes; tournament_player_stats rows are also cascaded when the tournament
-- itself is deleted below.
create or replace function public.delete_account() returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  delete from public.tournaments where user_id = auth.uid();
  delete from public.profiles where user_id = auth.uid();
  delete from auth.users where id = auth.uid();
end;
$$;
revoke all on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;
