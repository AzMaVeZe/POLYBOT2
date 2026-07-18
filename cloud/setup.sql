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

-- Anyone with the share link can read a row the owner marked public — powers
-- the read-only public results page (r.html), which always uses the anon key.
-- Deliberately NOT granted to `authenticated`: the app's sync reads with the
-- user's token, and public rows must never mix into another account's pull.
drop policy if exists public_read on public.tournaments;
create policy public_read on public.tournaments
  for select
  to anon
  using (is_public = true);

-- Self-serve account + data deletion (GDPR / Israeli PPL right to erasure).
-- Deletes only the caller's own rows and auth user via auth.uid().
create or replace function public.delete_account() returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  delete from public.tournaments where user_id = auth.uid();
  delete from auth.users where id = auth.uid();
end;
$$;
revoke all on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;
