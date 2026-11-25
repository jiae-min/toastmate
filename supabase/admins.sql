-- ToastMate: server owner and app admins.
-- Run this whole file once in Supabase Dashboard → SQL Editor (safe to re-run).
-- schema.sql runs this file's contents too (section 8) for new projects.
--
-- Server owner (app_owners): turns admin access on or off for other people in the app.
-- Admin (district_admins): may add, edit and remove District events. Owners count as admins too.

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
