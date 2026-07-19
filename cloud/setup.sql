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

-- Self-serve account + data deletion (GDPR / Israeli PPL right to erasure).
-- Deletes only the caller's own rows and auth user via auth.uid().
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
