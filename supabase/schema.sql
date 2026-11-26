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
-- (Replaced in section 7: direct join only while a club has no officer.)
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
-- and edit the theme (Toastmaster), Word of the Day (Grammarian) or the Discussion/Debate topic
-- (that session's master) only when they hold that role.
create or replace function public.tm_meeting_guard()
returns trigger language plpgsql set search_path = public as $$
declare
  me text; k text; o jsonb; n jsonb;
  free_keys text[] := array['roles', 'tts', 'theme', 'tq', 'wod', 'wodMeaning', 'wodExample', 'dsTopic', 'dbTopic'];
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
  if ((old.data -> 'wod') is distinct from (new.data -> 'wod') or (old.data -> 'wodMeaning') is distinct from (new.data -> 'wodMeaning')
      or (old.data -> 'wodExample') is distinct from (new.data -> 'wodExample'))
     and coalesce(new.data -> 'roles' -> 'gram' ->> 'mid', '') <> me then
    raise exception 'TM_OFFICERS_ONLY';
  end if;
  if (old.data -> 'dsTopic') is distinct from (new.data -> 'dsTopic')
     and coalesce(new.data -> 'roles' -> 'dsm' ->> 'mid', '') <> me then
    raise exception 'TM_OFFICERS_ONLY';
  end if;
  if (old.data -> 'dbTopic') is distinct from (new.data -> 'dbTopic')
     and coalesce(new.data -> 'roles' -> 'dbm' ->> 'mid', '') <> me then
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

-- =========================================================
-- 7. Joining: invite codes and join requests
-- =========================================================
create table if not exists public.club_invites (
  club_id text primary key references public.clubs (id) on delete cascade,
  code text not null unique,
  updated_at timestamptz not null default now()
);
alter table public.club_invites enable row level security;  -- no policies: only the functions below touch it
revoke all on public.club_invites from anon, authenticated;

create table if not exists public.join_requests (
  club_id text not null references public.clubs (id) on delete cascade,
  uid uuid not null references auth.users (id) on delete cascade,
  name text not null default '',
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid,
  primary key (club_id, uid)
);
alter table public.join_requests enable row level security;
drop policy if exists "see requests" on public.join_requests;
create policy "see requests" on public.join_requests for select to authenticated
  using (uid = auth.uid() or public.tm_is_officer(club_id));
revoke all on public.join_requests from anon, authenticated;
grant select on public.join_requests to authenticated;   -- writes only through the functions below

create or replace function public.tm__has_officer(p_club text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where club_id = p_club and officer)
$$;

-- Internal: link a user to a club (claims an unclaimed roster entry with the same name,
-- or adds one) and adds the club to that user's profile. Not callable from the app.
create or replace function public.tm__add_member(p_club text, p_uid uuid, p_name text, p_officer boolean)
returns text language plpgsql security definer set search_path = public as $$
declare mid text;
begin
  select id into mid from public.members where club_id = p_club and uid = p_uid limit 1;
  if mid is null then
    select id into mid from public.members
      where club_id = p_club and uid is null
        and lower(regexp_replace(data ->> 'name', '[\s.\-_]', '', 'g')) = lower(regexp_replace(p_name, '[\s.\-_]', '', 'g'))
      limit 1;
    perform set_config('tm.joining', '1', true);
    if mid is not null then
      update public.members set data = data || jsonb_build_object('uid', p_uid::text)
        || case when p_officer then '{"officer": true}'::jsonb else '{}'::jsonb end
        where id = mid;
    else
      mid := 'm' || substr(md5(random()::text || clock_timestamp()::text), 1, 12);
      insert into public.members (id, club_id, data)
        values (mid, p_club, jsonb_build_object('name', p_name, 'uid', p_uid::text, 'officer', p_officer, 'position', ''));
    end if;
    perform set_config('tm.joining', '', true);
  end if;
  update public.profiles
    set data = jsonb_set(data, '{clubs}', (
          select coalesce(jsonb_agg(distinct x), '[]'::jsonb)
          from jsonb_array_elements_text(
            case when jsonb_typeof(data -> 'clubs') = 'array' then data -> 'clubs' else '[]'::jsonb end || to_jsonb(p_club)) x)),
        updated_at = now()
    where id = p_uid;
  return mid;
end $$;

-- Direct join works only for a club that has no officer yet (its first member becomes the officer).
create or replace function public.tm_join_club(p_club text, p_name text)
returns text language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'TM_NOT_SIGNED_IN'; end if;
  if not exists (select 1 from public.clubs where id = p_club) then raise exception 'TM_NOT_FOUND'; end if;
  if exists (select 1 from public.members where club_id = p_club and uid = auth.uid()) then
    return public.tm__add_member(p_club, auth.uid(), p_name, false);
  end if;
  if public.tm__has_officer(p_club) then raise exception 'TM_NEED_APPROVAL'; end if;
  return public.tm__add_member(p_club, auth.uid(), p_name, true);
end $$;

-- Ask to join. Returns 'joined' (already a member, or the club had no officer yet) or 'pending'.
-- A rejected request can be sent again; it goes back to pending.
create or replace function public.tm_request_join(p_club text, p_name text)
returns text language plpgsql security definer set search_path = public as $$
declare cl jsonb;
begin
  if auth.uid() is null then raise exception 'TM_NOT_SIGNED_IN'; end if;
  select data into cl from public.clubs where id = p_club;
  if not found then raise exception 'TM_NOT_FOUND'; end if;
  if exists (select 1 from public.members where club_id = p_club and uid = auth.uid()) then return 'joined'; end if;
  if not public.tm__has_officer(p_club) then
    perform public.tm__add_member(p_club, auth.uid(), p_name, true);
    return 'joined';
  end if;
  if coalesce(cl ->> 'acceptRequests', 'true') = 'false' then raise exception 'TM_REQUESTS_OFF'; end if;
  insert into public.join_requests (club_id, uid, name, status, created_at, decided_at, decided_by)
    values (p_club, auth.uid(), left(coalesce(nullif(trim(p_name), ''), 'Member'), 80), 'pending', now(), null, null)
    on conflict (club_id, uid) do update
      set name = excluded.name, status = 'pending', created_at = now(), decided_at = null, decided_by = null;
  return 'pending';
end $$;

-- Officers approve or reject a pending request.
create or replace function public.tm_decide_request(p_club text, p_uid uuid, p_approve boolean)
returns void language plpgsql security definer set search_path = public as $$
declare r public.join_requests%rowtype;
begin
  if not public.tm_is_officer(p_club) then raise exception 'TM_OFFICERS_ONLY'; end if;
  select * into r from public.join_requests where club_id = p_club and uid = p_uid for update;
  if not found then raise exception 'TM_NOT_FOUND'; end if;
  if r.status <> 'pending' then return; end if;
  if p_approve then perform public.tm__add_member(p_club, p_uid, r.name, false); end if;
  update public.join_requests
    set status = case when p_approve then 'approved' else 'rejected' end, decided_at = now(), decided_by = auth.uid()
    where club_id = p_club and uid = p_uid;
end $$;

-- Officers read the club's invite code (made on first use) or replace it with a new one.
create or replace function public.tm_invite_code(p_club text, p_reset boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare c text;
begin
  if not public.tm_is_officer(p_club) then raise exception 'TM_OFFICERS_ONLY'; end if;
  select code into c from public.club_invites where club_id = p_club;
  if c is null or p_reset then
    loop
      c := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
      exit when not exists (select 1 from public.club_invites where code = c);
    end loop;
    insert into public.club_invites (club_id, code, updated_at) values (p_club, c, now())
      on conflict (club_id) do update set code = excluded.code, updated_at = now();
  end if;
  return c;
end $$;

-- Join with an invite code. Returns the club id.
create or replace function public.tm_join_with_code(p_code text, p_name text)
returns text language plpgsql security definer set search_path = public as $$
declare cid text;
begin
  if auth.uid() is null then raise exception 'TM_NOT_SIGNED_IN'; end if;
  select club_id into cid from public.club_invites
    where code = upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  if cid is null then raise exception 'TM_BAD_CODE'; end if;
  perform public.tm__add_member(cid, auth.uid(), left(coalesce(nullif(trim(p_name), ''), 'Member'), 80), not public.tm__has_officer(cid));
  update public.join_requests set status = 'approved', decided_at = now()
    where club_id = cid and uid = auth.uid() and status = 'pending';
  return cid;
end $$;

revoke all on function public.tm__add_member(text, uuid, text, boolean), public.tm__has_officer(text) from public, anon, authenticated;
revoke all on function public.tm_join_club(text, text), public.tm_request_join(text, text), public.tm_decide_request(text, uuid, boolean),
  public.tm_invite_code(text, boolean), public.tm_join_with_code(text, text) from public, anon;
grant execute on function public.tm_join_club(text, text), public.tm_request_join(text, text), public.tm_decide_request(text, uuid, boolean),
  public.tm_invite_code(text, boolean), public.tm_join_with_code(text, text) to authenticated;

do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin alter publication supabase_realtime add table public.join_requests; exception when duplicate_object then null; end;
  end if;
end $$;

-- =========================================================
-- 8. Server owner and admins
-- =========================================================
create table if not exists public.app_owners (
  uid uuid primary key references auth.users (id) on delete cascade
);
alter table public.app_owners enable row level security;  -- no policies: only the functions below read it
revoke all on public.app_owners from anon, authenticated;

-- Server owner: Jiae Min (same id as ownerIds in config.js)
insert into public.app_owners (uid)
  select '4ba309c9-4c86-4d7a-94c5-a6db7e34bd8a'::uuid
  where exists (select 1 from auth.users where id = '4ba309c9-4c86-4d7a-94c5-a6db7e34bd8a'::uuid)
  on conflict do nothing;

create or replace function public.tm_is_app_owner()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.app_owners where uid = auth.uid())
$$;

-- Owners are admins too
create or replace function public.tm_is_district_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.district_admins where uid = auth.uid())
      or exists (select 1 from public.app_owners where uid = auth.uid())
$$;

-- Who is an admin, so the app can show the badge. Signed-in users only; reveals ids and the role, nothing else.
create or replace function public.tm_admin_uids()
returns table (uid uuid, owner boolean) language sql stable security definer set search_path = public as $$
  select o.uid, true from public.app_owners o where auth.uid() is not null
  union
  select d.uid, false from public.district_admins d
   where auth.uid() is not null and not exists (select 1 from public.app_owners o where o.uid = d.uid)
$$;

-- Turn admin access on or off. Only the server owner may call it, and owners can't be changed here.
create or replace function public.tm_set_admin(p_uid uuid, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.app_owners where uid = auth.uid()) then raise exception 'TM_NOT_OWNER'; end if;
  if p_uid is null or exists (select 1 from public.app_owners where uid = p_uid) then raise exception 'TM_BAD_TARGET'; end if;
  if p_on then
    insert into public.district_admins (uid) values (p_uid) on conflict do nothing;
  else
    delete from public.district_admins where uid = p_uid;
  end if;
end $$;

revoke all on function public.tm_is_app_owner(), public.tm_admin_uids(), public.tm_set_admin(uuid, boolean) from public, anon;
grant execute on function public.tm_is_app_owner(), public.tm_admin_uids(), public.tm_set_admin(uuid, boolean), public.tm_is_district_admin() to authenticated;

-- Sign-up list for the server owner's admin screen (Settings → 관리자). Owner only.
create or replace function public.tm_list_users()
returns table (uid uuid, name text, real_name text, clubs text[], role text, joined_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from public.app_owners where app_owners.uid = auth.uid()) then raise exception 'TM_NOT_OWNER'; end if;
  return query
  select u.id,
         coalesce(nullif(p.data ->> 'name', ''), ''),
         coalesce(p.data ->> 'realName', ''),
         coalesce((select array_agg(coalesce(nullif(c.data ->> 'nick', ''), nullif(c.data ->> 'official', ''), c.id) order by c.id)
                     from public.members m join public.clubs c on c.id = m.club_id where m.uid = u.id), '{}'),
         case when exists (select 1 from public.app_owners o where o.uid = u.id) then 'owner'
              when exists (select 1 from public.district_admins d where d.uid = u.id) then 'admin' else '' end,
         u.created_at
    from auth.users u left join public.profiles p on p.id = u.id
   order by u.created_at;
end $$;
revoke all on function public.tm_list_users() from public, anon;
grant execute on function public.tm_list_users() to authenticated;
