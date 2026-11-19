-- ToastMate: joining a club only by invite code or by an approved join request.
-- Run this whole file once in Supabase Dashboard → SQL Editor (safe to re-run).
-- schema.sql runs this file's contents too (section 7) for new projects.

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
