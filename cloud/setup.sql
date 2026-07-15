-- PadelZit cloud setup — run once in the Supabase SQL Editor.
-- Creates the tournaments table; every user can only see and edit their own rows.

create table if not exists public.tournaments (
  id text primary key,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  data jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.tournaments enable row level security;

create policy "own_select" on public.tournaments
  for select using (auth.uid() = user_id);
create policy "own_insert" on public.tournaments
  for insert with check (auth.uid() = user_id);
create policy "own_update" on public.tournaments
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "own_delete" on public.tournaments
  for delete using (auth.uid() = user_id);
