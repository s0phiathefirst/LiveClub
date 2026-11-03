-- LIVE CLUB database. Paste the whole file into Supabase > SQL Editor and press Run, once.
-- Safe to run again: it only creates what is missing.

-- 1. accounts: login ID + email. Private: no policies, so only the server (secret key) can read it.
create table if not exists public.accounts (
  id          uuid primary key references auth.users(id) on delete cascade,
  login_id    text not null check (login_id ~ '^[A-Za-z0-9._]{4,16}$'),
  login_lower text generated always as (lower(login_id)) stored,
  email       text not null,
  created_at  timestamptz not null default now()
);
create unique index if not exists accounts_login_unique on public.accounts (login_lower);
alter table public.accounts enable row level security;

-- 2. profiles: the nickname shown above each ghost. Anyone can read; nobody can edit from the browser.
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  nickname    text not null check (nickname ~ '^[가-힣A-Za-z0-9._]{2,12}$'),
  is_dev      boolean not null default false,
  created_at  timestamptz not null default now()
);
create unique index if not exists profiles_nickname_unique on public.profiles (lower(nickname));
alter table public.profiles enable row level security;
drop policy if exists "read nicknames" on public.profiles;
create policy "read nicknames" on public.profiles for select using (true);

-- 3. clubs: one club per person, everything about it in one JSON document.
create table if not exists public.clubs (
  owner       uuid primary key references public.profiles(id) on delete cascade,
  data        jsonb not null,
  updated_at  timestamptz not null default now(),
  constraint clubs_size check (pg_column_size(data) < 200000)
);
alter table public.clubs enable row level security;
drop policy if exists "read clubs" on public.clubs;
drop policy if exists "insert own club" on public.clubs;
drop policy if exists "update own club" on public.clubs;
drop policy if exists "delete own club" on public.clubs;
create policy "read clubs"       on public.clubs for select using (true);
create policy "insert own club"  on public.clubs for insert with check ((select auth.uid()) = owner);
create policy "update own club"  on public.clubs for update using ((select auth.uid()) = owner) with check ((select auth.uid()) = owner);
create policy "delete own club"  on public.clubs for delete using ((select auth.uid()) = owner);

-- 4. every new sign-up gets an account + profile. A taken ID or nickname makes the whole sign-up fail,
--    so duplicates are impossible even if two people press the button at the same moment.
--    The developer ID gets is_dev automatically (the big club in the middle of the street).
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  lid  text := new.raw_user_meta_data->>'login_id';
  nick text := new.raw_user_meta_data->>'nickname';
begin
  insert into public.accounts (id, login_id, email) values (new.id, lid, new.email);
  insert into public.profiles (id, nickname, is_dev) values (new.id, nick, lower(lid) = 'joreng2');
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- 5. the sign-up form asks this before sending the code: is the ID free, is the nickname free (true/false only)
create or replace function public.check_available(p_login text, p_nick text) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'login', not exists (select 1 from public.accounts where login_lower = lower(p_login)),
    'nick',  not exists (select 1 from public.profiles where lower(nickname) = lower(p_nick)));
$$;
revoke all on function public.check_available(text, text) from public;
grant execute on function public.check_available(text, text) to anon, authenticated;
