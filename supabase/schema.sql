-- ToastMate database schema for Supabase
-- Run the whole file once in Supabase Dashboard → SQL Editor → New query → Run.
-- Safe to re-run: it drops and recreates functions, triggers and policies (tables are kept).

-- =========================================================
-- 1. Tables
--    Each row keeps the app's object in `data` (jsonb).
--    Columns outside `data` exist only for security rules.
-- =========================================================
create table if not exists public.profiles (
  id uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create table if not exists public.clubs (
  id text primary key,
  data jsonb not null default '{}'::jsonb,
  created_by uuid default auth.uid(),
  updated_at timestamptz not null default now()
);

create table if not exists public.members (
  id text primary key,
  club_id text not null references public.clubs (id) on delete cascade,
  uid uuid,                                   -- filled from data.uid by trigger
  officer boolean not null default false,     -- filled from data.officer by trigger
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
create index if not exists members_club_idx on public.members (club_id);
create index if not exists members_uid_idx on public.members (uid);

create table if not exists public.meetings (
  id text primary key,
  club_id text not null references public.clubs (id) on delete cascade,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
create index if not exists meetings_club_idx on public.meetings (club_id);

create table if not exists public.events (
  id text primary key,
  data jsonb not null default '{}'::jsonb,
  created_by uuid default auth.uid(),
  updated_at timestamptz not null default now()
);

-- District leaders who may add District events. Add people in SQL Editor:
--   insert into public.district_admins (uid) values ('<user id from Authentication → Users>');
create table if not exists public.district_admins (
  uid uuid primary key references auth.users (id) on delete cascade
);

create table if not exists public.reflections (
  uid uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id text not null,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (uid, id)
);

-- =========================================================
-- 2. Helper functions (security definer so policies can call them
--    without recursive row-level checks)
-- =========================================================
create or replace function public.tm_my_member(p_club text)
returns text language sql stable security definer set search_path = public as $$
  select id from public.members where club_id = p_club and uid = auth.uid() limit 1
$$;

create or replace function public.tm_is_member(p_club text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where club_id = p_club and uid = auth.uid())
$$;

create or replace function public.tm_is_officer(p_club text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where club_id = p_club and uid = auth.uid() and officer)
$$;

create or replace function public.tm_is_district_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.district_admins where uid = auth.uid())
$$;

create or replace function public.tm_is_any_officer()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where uid = auth.uid() and officer)
$$;

-- Recursive merge: objects merge key by key, anything else (arrays, null) replaces.
create or replace function public.tm_merge(a jsonb, b jsonb)
returns jsonb language plpgsql immutable as $$
declare k text; out jsonb;
begin
  if a is null or jsonb_typeof(a) <> 'object' or jsonb_typeof(b) <> 'object' then return b; end if;
  out := a;
  for k in select jsonb_object_keys(b) loop
    if jsonb_typeof(out -> k) = 'object' and jsonb_typeof(b -> k) = 'object' then
      out := jsonb_set(out, array[k], public.tm_merge(out -> k, b -> k));
    else
      out := jsonb_set(out, array[k], b -> k, true);
    end if;
  end loop;
  return out;
end $$;

-- The app's "update": merges a patch into one row on the server, so two people
-- booking different roles at the same moment never overwrite each other.
-- security invoker: row-level security still applies.
create or replace function public.tm_patch(p_table text, p_id text, p_patch jsonb)
returns void language plpgsql security invoker set search_path = public as $$
declare n int;
begin
  if p_table not in ('profiles', 'clubs', 'members', 'meetings', 'events', 'reflections') then
    raise exception 'TM_BAD_TABLE';
  end if;
  if p_table = 'reflections' then
    update public.reflections set data = public.tm_merge(data, p_patch), updated_at = now() where id = p_id and uid = auth.uid();
  else
    execute format('update public.%I set data = public.tm_merge(data, $1), updated_at = now() where id::text = $2', p_table)
      using p_patch, p_id;
  end if;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'TM_NOT_FOUND'; end if;
end $$;

-- Joining a club: claim an unclaimed roster entry with the same name, or add a new one.
-- The first person to join a club with no officers becomes its officer.
create or replace function public.tm_join_club(p_club text, p_name text)
returns text language plpgsql security definer set search_path = public as $$
declare mid text; has_officer boolean;
begin
  if auth.uid() is null then raise exception 'TM_NOT_SIGNED_IN'; end if;
  if not exists (select 1 from public.clubs where id = p_club) then raise exception 'TM_NOT_FOUND'; end if;
  select id into mid from public.members where club_id = p_club and uid = auth.uid() limit 1;
  if mid is not null then return mid; end if;
  select exists (select 1 from public.members where club_id = p_club and officer) into has_officer;
  select id into mid from public.members
    where club_id = p_club and uid is null and lower(regexp_replace(data ->> 'name', '[\s.\-_]', '', 'g')) = lower(regexp_replace(p_name, '[\s.\-_]', '', 'g'))
    limit 1;
  perform set_config('tm.joining', '1', true);
  if mid is not null then
    update public.members set data = data || jsonb_build_object('uid', auth.uid()::text)
      || case when has_officer then '{}'::jsonb else '{"officer": true}'::jsonb end
      where id = mid;
  else
    mid := 'm' || substr(md5(random()::text || clock_timestamp()::text), 1, 12);
    insert into public.members (id, club_id, data)
      values (mid, p_club, jsonb_build_object('name', p_name, 'uid', auth.uid()::text, 'officer', not has_officer, 'position', ''));
  end if;
  perform set_config('tm.joining', '', true);
  return mid;
end $$;

-- =========================================================
-- 3. Triggers
-- =========================================================
create or replace function public.tm_member_columns()
returns trigger language plpgsql as $$
begin
  new.uid := nullif(new.data ->> 'uid', '')::uuid;
  new.officer := coalesce((new.data ->> 'officer')::boolean, false);
  return new;
end $$;
drop trigger if exists a_member_columns on public.members;
create trigger a_member_columns before insert or update on public.members
  for each row execute function public.tm_member_columns();

-- Members who are not officers may only edit their own entry: change their name or leave.
create or replace function public.tm_member_guard()
returns trigger language plpgsql set search_path = public as $$
begin
  -- SQL editor / service role (no signed-in user), the join function, and officers skip the checks
  if auth.uid() is null or current_setting('tm.joining', true) = '1' or public.tm_is_officer(old.club_id) then return new; end if;
  if old.uid is distinct from auth.uid() then raise exception 'TM_OFFICERS_ONLY'; end if;
  if new.club_id <> old.club_id
     or (new.data -> 'officer') is distinct from (old.data -> 'officer')
     or (new.data -> 'position') is distinct from (old.data -> 'position')
     or (new.uid is not null and new.uid <> auth.uid()) then
    raise exception 'TM_OFFICERS_ONLY';
  end if;
  return new;
end $$;
drop trigger if exists b_member_guard on public.members;
create trigger b_member_guard before update on public.members
  for each row execute function public.tm_member_guard();

-- Members who are not officers may book or cancel only their own roles,
-- add or remove only themselves as Table Topics speakers,
-- and edit the theme (Toastmaster) or Word of the Day (Grammarian) only when they hold that role.
create or replace function public.tm_meeting_guard()
returns trigger language plpgsql set search_path = public as $$
declare
  me text; k text; o jsonb; n jsonb;
  free_keys text[] := array['roles', 'tts', 'theme', 'tq', 'wod', 'wodMeaning'];
begin
  if auth.uid() is null or public.tm_is_officer(old.club_id) then return new; end if;
  me := public.tm_my_member(old.club_id);
  if me is null or new.club_id <> old.club_id then raise exception 'TM_OFFICERS_ONLY'; end if;
  if (old.data - free_keys) is distinct from (new.data - free_keys) then raise exception 'TM_OFFICERS_ONLY'; end if;
  if old.data ->> 'status' = 'final' and old.data is distinct from new.data then raise exception 'TM_FINAL'; end if;

  for k in select jsonb_object_keys(coalesce(old.data -> 'roles', '{}')) union select jsonb_object_keys(coalesce(new.data -> 'roles', '{}')) loop
    o := nullif(old.data -> 'roles' -> k, 'null'::jsonb);
    n := nullif(new.data -> 'roles' -> k, 'null'::jsonb);
    if o is distinct from n then
      if not ((o is null or o ->> 'mid' = me) and (n is null or n ->> 'mid' = me)) then
        raise exception 'TM_ROLE_TAKEN';
      end if;
    end if;
  end loop;

  if (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(coalesce(old.data -> 'tts', '[]')) e where e ->> 'mid' is distinct from me)
     is distinct from
     (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(coalesce(new.data -> 'tts', '[]')) e where e ->> 'mid' is distinct from me) then
    raise exception 'TM_OFFICERS_ONLY';
  end if;

  if ((old.data -> 'theme') is distinct from (new.data -> 'theme') or (old.data -> 'tq') is distinct from (new.data -> 'tq'))
     and coalesce(new.data -> 'roles' -> 'tm' ->> 'mid', '') <> me then
    raise exception 'TM_OFFICERS_ONLY';
  end if;
  if ((old.data -> 'wod') is distinct from (new.data -> 'wod') or (old.data -> 'wodMeaning') is distinct from (new.data -> 'wodMeaning'))
     and coalesce(new.data -> 'roles' -> 'gram' ->> 'mid', '') <> me then
    raise exception 'TM_OFFICERS_ONLY';
  end if;
  return new;
end $$;
drop trigger if exists b_meeting_guard on public.meetings;
create trigger b_meeting_guard before update on public.meetings
  for each row execute function public.tm_meeting_guard();

-- =========================================================
-- 4. Row-level security
-- =========================================================
alter table public.profiles enable row level security;
alter table public.clubs enable row level security;
alter table public.members enable row level security;
alter table public.meetings enable row level security;
alter table public.events enable row level security;
alter table public.reflections enable row level security;

do $$ declare r record; begin
  for r in select policyname, tablename from pg_policies where schemaname = 'public'
           and tablename in ('profiles', 'clubs', 'members', 'meetings', 'events', 'reflections') loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

-- profiles: only yourself
create policy "own profile" on public.profiles for all to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- clubs: everyone signed in can see the club list (to join); officers edit; anyone may register a new club
create policy "read clubs" on public.clubs for select to authenticated using (true);
create policy "create club" on public.clubs for insert to authenticated with check (created_by = auth.uid());
create policy "officers edit club" on public.clubs for update to authenticated
  using (public.tm_is_officer(id)) with check (public.tm_is_officer(id));

-- members: visible to the club's members; officers manage the roster; a club's creator adds themself
create policy "read members" on public.members for select to authenticated using (public.tm_is_member(club_id));
create policy "add members" on public.members for insert to authenticated with check (
  public.tm_is_officer(club_id)
  or (exists (select 1 from public.clubs c where c.id = club_id and c.created_by = auth.uid()) and data ->> 'uid' = auth.uid()::text)
);
create policy "edit members" on public.members for update to authenticated
  using (public.tm_is_officer(club_id) or uid = auth.uid())
  with check (public.tm_is_officer(club_id) or uid = auth.uid() or uid is null);  -- uid null = leaving the club
create policy "remove members" on public.members for delete to authenticated using (public.tm_is_officer(club_id));

-- meetings: members read and book (checked by trigger); officers create and delete
create policy "read meetings" on public.meetings for select to authenticated using (public.tm_is_member(club_id));
create policy "officers add meetings" on public.meetings for insert to authenticated with check (public.tm_is_officer(club_id));
create policy "members update meetings" on public.meetings for update to authenticated
  using (public.tm_is_member(club_id)) with check (public.tm_is_member(club_id));
create policy "officers delete meetings" on public.meetings for delete to authenticated using (public.tm_is_officer(club_id));

-- District events: everyone signed in reads; only District admins add, edit or remove
create policy "read events" on public.events for select to authenticated using (true);
create policy "district adds events" on public.events for insert to authenticated
  with check (public.tm_is_district_admin() and created_by = auth.uid());
create policy "district edits events" on public.events for update to authenticated
  using (public.tm_is_district_admin());
create policy "district removes events" on public.events for delete to authenticated
  using (public.tm_is_district_admin());

-- district_admins: nobody edits it from the app; signed-in users may check only themselves
alter table public.district_admins enable row level security;
drop policy if exists "see self" on public.district_admins;
create policy "see self" on public.district_admins for select to authenticated using (uid = auth.uid());

-- reflections: private to each person
create policy "own reflections" on public.reflections for all to authenticated
  using (uid = auth.uid()) with check (uid = auth.uid());

-- =========================================================
-- 5. Permissions and realtime
-- =========================================================
revoke all on public.profiles, public.clubs, public.members, public.meetings, public.events, public.reflections, public.district_admins from anon;
grant select on public.district_admins to authenticated;
grant select, insert, update, delete on public.profiles, public.clubs, public.members, public.meetings, public.events, public.reflections to authenticated;
revoke execute on function public.tm_patch(text, text, jsonb), public.tm_join_club(text, text) from public, anon;
grant execute on function public.tm_patch(text, text, jsonb), public.tm_join_club(text, text), public.tm_is_district_admin() to authenticated;

do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin alter publication supabase_realtime add table public.clubs; exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.members; exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.meetings; exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.events; exception when duplicate_object then null; end;
  end if;
end $$;

-- Keep-alive ping for the GitHub Actions workflow (touches the database, reveals nothing)
create or replace function public.tm_ping() returns int language sql stable as $$ select 1 $$;
grant execute on function public.tm_ping() to anon, authenticated;

-- Account deletion: unlink from every club (role history keeps the name), delete
-- the profile and reflections, then remove the login itself.
create or replace function public.tm_delete_me() returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'TM_SIGN_IN'; end if;
  perform set_config('tm.joining', '1', true);
  update public.members set data = data || jsonb_build_object('uid', '', 'officer', false) where uid = me;
  perform set_config('tm.joining', '', true);
  delete from public.reflections where uid = me;
  delete from public.district_admins where uid = me;
  delete from public.profiles where id = me;
  delete from auth.users where id = me;
end $$;
revoke all on function public.tm_delete_me() from public, anon;
grant execute on function public.tm_delete_me() to authenticated;

-- =========================================================
-- 6. Starting clubs (the first person to join each becomes its officer)
-- =========================================================
insert into public.clubs (id, data, created_by) values
('kutm', '{
  "official": "Korea University Toastmasters Club", "nick": "KUTM", "division": "A", "area": "14", "langs": ["en"],
  "start": "19:30", "end": "21:30",
  "venue": "블루라움 안암오거리점 지하 1층", "address": "서울 동대문구 약령시로 3 지하1층",
  "maps": {"naver": "https://naver.me/GOPEra0V", "kakao": "https://kko.to/rRNb2JUKMF", "google": "https://maps.app.goo.gl/MMsy5m89WK89kWM27"},
  "fee": {"on": false, "target": "guest"},
  "flow": [{"id": "f1", "type": "opening", "min": 5}, {"id": "f2", "type": "roles", "min": 5}, {"id": "f3", "type": "tt", "min": 20}, {"id": "f4", "type": "break", "min": 10},
           {"id": "f5", "type": "speeches", "min": 0}, {"id": "f6", "type": "evaluation", "min": 0}, {"id": "f7", "type": "awards", "min": 5}, {"id": "f8", "type": "closing", "min": 5}]
}'::jsonb, null),
('gwanghwamun', '{
  "official": "GwangHwaMun Korean Toastmasters Club", "nick": "광화문 토스트마스터즈", "division": "A", "area": "13", "langs": ["ko"],
  "start": "19:30", "end": "21:30",
  "venue": "공간클라크", "address": "서울 종로구 새문안로 42 피어선빌딩 1108호",
  "maps": {"naver": "https://naver.me/FvEI4Ck5", "kakao": "https://kko.to/5a9oqO26c9", "google": "https://maps.app.goo.gl/Vid51WSbPrCWXkD9A"},
  "fee": {"on": false, "target": "guest"},
  "flow": [{"id": "f1", "type": "opening", "min": 5}, {"id": "f2", "type": "roles", "min": 5}, {"id": "f3", "type": "tt", "min": 20}, {"id": "f4", "type": "break", "min": 10},
           {"id": "f5", "type": "speeches", "min": 0}, {"id": "f6", "type": "evaluation", "min": 0}, {"id": "f7", "type": "awards", "min": 5}, {"id": "f8", "type": "closing", "min": 5}]
}'::jsonb, null)
on conflict (id) do nothing;
