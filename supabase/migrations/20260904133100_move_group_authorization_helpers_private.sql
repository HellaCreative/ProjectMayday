begin;

create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated, service_role;

create or replace function private.is_group_member(p_group_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1
    from public.group_members as gm
    join public.groups as g on g.id = gm.group_id
    where gm.group_id = p_group_id
      and gm.user_id = p_user_id
      and g.deleted_at is null
  );
$function$;

create or replace function private.is_group_owner(p_group_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1
    from public.groups as g
    where g.id = p_group_id
      and g.owner_id = p_user_id
      and g.deleted_at is null
  );
$function$;

revoke all on function private.is_group_member(uuid, uuid) from public, anon;
revoke all on function private.is_group_owner(uuid, uuid) from public, anon;
grant execute on function private.is_group_member(uuid, uuid) to authenticated, service_role;
grant execute on function private.is_group_owner(uuid, uuid) to authenticated, service_role;

drop policy if exists profiles_select_self_or_group_member on public.profiles;
create policy profiles_select_self_or_group_member on public.profiles
for select to authenticated
using (
  id = (select auth.uid())
  or exists (
    select 1
    from public.group_members as mine
    join public.group_members as theirs on theirs.group_id = mine.group_id
    where mine.user_id = (select auth.uid())
      and theirs.user_id = profiles.id
      and private.is_group_member(mine.group_id, (select auth.uid()))
  )
);

drop policy if exists groups_select_member on public.groups;
create policy groups_select_member on public.groups
for select to authenticated
using (deleted_at is null and private.is_group_member(id, (select auth.uid())));

drop policy if exists group_members_select_member on public.group_members;
create policy group_members_select_member on public.group_members
for select to authenticated
using (private.is_group_member(group_id, (select auth.uid())));

drop policy if exists group_members_insert_owner on public.group_members;
create policy group_members_insert_owner on public.group_members
for insert to authenticated
with check (
  private.is_group_owner(group_id, (select auth.uid()))
  or user_id = (select auth.uid())
);

drop policy if exists group_members_delete_owner_or_self on public.group_members;
create policy group_members_delete_owner_or_self on public.group_members
for delete to authenticated
using (
  user_id = (select auth.uid())
  or private.is_group_owner(group_id, (select auth.uid()))
);

drop policy if exists presence_select_group_member on public.rider_presence;
create policy presence_select_group_member on public.rider_presence
for select to authenticated
using (
  user_id = (select auth.uid())
  or exists (
    select 1 from public.group_members as mine
    where mine.user_id = (select auth.uid())
      and private.is_group_member(mine.group_id, rider_presence.user_id)
  )
);

drop policy if exists alerts_select_group_member on public.rider_alerts;
create policy alerts_select_group_member on public.rider_alerts
for select to authenticated
using (private.is_group_member(group_id, (select auth.uid())));

drop policy if exists alerts_insert_self_member on public.rider_alerts;
create policy alerts_insert_self_member on public.rider_alerts
for insert to authenticated
with check (
  user_id = (select auth.uid())
  and private.is_group_member(group_id, (select auth.uid()))
);

drop policy if exists alerts_update_group_member on public.rider_alerts;
create policy alerts_update_group_member on public.rider_alerts
for update to authenticated
using (private.is_group_member(group_id, (select auth.uid())))
with check (private.is_group_member(group_id, (select auth.uid())));

drop policy if exists group_members_can_receive_realtime on realtime.messages;
create policy group_members_can_receive_realtime on realtime.messages
for select to authenticated
using (
  realtime.topic() like 'group:%'
  and private.is_group_member(
    split_part(realtime.topic(), ':', 2)::uuid,
    (select auth.uid())
  )
);

drop policy if exists group_members_can_send_realtime on realtime.messages;
create policy group_members_can_send_realtime on realtime.messages
for insert to authenticated
with check (
  realtime.topic() like 'group:%'
  and private.is_group_member(
    split_part(realtime.topic(), ':', 2)::uuid,
    (select auth.uid())
  )
);

create or replace function public.delete_group(p_group_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if not private.is_group_owner(p_group_id, auth.uid()) then
    raise exception 'Only the group owner can delete this group.';
  end if;
  update public.groups
  set deleted_at = coalesce(deleted_at, now())
  where id = p_group_id;
end;
$function$;

create or replace function public.leave_group(p_group_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  requester_id uuid := auth.uid();
begin
  if requester_id is null then
    raise exception 'You must be signed in to leave a group.';
  end if;
  if private.is_group_owner(p_group_id, requester_id) then
    raise exception 'The group owner must delete the group instead of leaving it.';
  end if;

  delete from public.group_members
  where group_id = p_group_id and user_id = requester_id;
end;
$function$;

drop function public.is_group_member(uuid, uuid);
drop function public.is_group_owner(uuid, uuid);

commit;
