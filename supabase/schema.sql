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

-- 6. nickname changes (boutique): once per calendar day in Korea time, the developer any time
alter table public.profiles add column if not exists nick_changed_at timestamptz;
create or replace function public.change_nickname(p_nick text) returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); prof public.profiles;
begin
  if me is null then return 'auth'; end if;
  if p_nick is null or p_nick !~ '^[가-힣A-Za-z0-9._]{2,12}$' then return 'invalid'; end if;
  select * into prof from public.profiles where id = me for update;
  if not prof.is_dev and prof.nick_changed_at is not null
     and (prof.nick_changed_at at time zone 'Asia/Seoul')::date = (now() at time zone 'Asia/Seoul')::date then
    return 'today';
  end if;
  if exists (select 1 from public.profiles where lower(nickname) = lower(p_nick) and id <> me) then return 'taken'; end if;
  update public.profiles set nickname = p_nick, nick_changed_at = now() where id = me;
  return 'ok';
exception when unique_violation then return 'taken';
end $$;
revoke all on function public.change_nickname(text) from public;
grant execute on function public.change_nickname(text) to authenticated;

-- 7. guestbook: one per club. Anyone can read; signed-in people write as themselves;
--    the writer or the club owner can delete. One entry per person every 30 seconds.
create table if not exists public.guestbook (
  id          bigint generated always as identity primary key,
  club_owner  uuid not null references public.profiles(id) on delete cascade,
  author      uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  message     text not null check (char_length(btrim(message)) between 1 and 200),
  created_at  timestamptz not null default now()
);
create index if not exists guestbook_club_idx on public.guestbook (club_owner, created_at desc);
alter table public.guestbook enable row level security;
drop policy if exists "read guestbook" on public.guestbook;
drop policy if exists "write own entry" on public.guestbook;
drop policy if exists "delete own or on my club" on public.guestbook;
create policy "read guestbook" on public.guestbook for select using (true);
create policy "write own entry" on public.guestbook for insert to authenticated with check ((select auth.uid()) = author);
create policy "delete own or on my club" on public.guestbook for delete to authenticated
  using ((select auth.uid()) = author or (select auth.uid()) = club_owner);

create or replace function public.guestbook_slow_down() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.guestbook where author = new.author and created_at > now() - interval '30 seconds') then
    raise exception 'too_fast';
  end if;
  return new;
end $$;
drop trigger if exists guestbook_slow_down on public.guestbook;
create trigger guestbook_slow_down before insert on public.guestbook
  for each row execute function public.guestbook_slow_down();
