-- PadelZit cloud setup — run once in the Supabase SQL Editor.
-- Safe to run more than once.

create table if not exists public.tournaments (
  id text primary key,
  user_id uuid not null default auth.uid(),
  data jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.tournaments enable row level security;

drop policy if exists own_select on public.tournaments;
drop policy if exists own_insert on public.tournaments;
drop policy if exists own_update on public.tournaments;
drop policy if exists own_delete on public.tournaments;
drop policy if exists own_all on public.tournaments;

create policy own_all on public.tournaments
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
