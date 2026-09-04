begin;

-- A deleted group must stop authorizing table reads and Realtime traffic
-- immediately, even while its memberships remain for cascade cleanup.
create or replace function public.is_group_member(p_group_id uuid, p_user_id uuid)
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

create or replace function public.is_group_owner(p_group_id uuid, p_user_id uuid)
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

-- Group members may resolve an alert, but may not rewrite who raised it,
-- its location, severity, message, group, or creation time.
create or replace function public.guard_rider_alert_resolution()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $function$
begin
  if new.id is distinct from old.id
    or new.group_id is distinct from old.group_id
    or new.user_id is distinct from old.user_id
    or new.status is distinct from old.status
    or new.message is distinct from old.message
    or new.latitude is distinct from old.latitude
    or new.longitude is distinct from old.longitude
    or new.created_at is distinct from old.created_at then
    raise exception using
      errcode = '42501',
      message = 'Only resolved_at may be changed on a rider alert.';
  end if;

  if new.resolved_at is null
    or (old.resolved_at is not null and new.resolved_at is distinct from old.resolved_at) then
    raise exception using
      errcode = '42501',
      message = 'A resolved rider alert cannot be reopened or rewritten.';
  end if;

  return new;
end;
$function$;

drop trigger if exists rider_alerts_guard_resolution on public.rider_alerts;
create trigger rider_alerts_guard_resolution
before update on public.rider_alerts
for each row execute function public.guard_rider_alert_resolution();

-- Owners must explicitly delete their group so the group cannot silently
-- become ownerless. Regular members can still leave normally.
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
  if public.is_group_owner(p_group_id, requester_id) then
    raise exception 'The group owner must delete the group instead of leaving it.';
  end if;

  delete from public.group_members
  where group_id = p_group_id and user_id = requester_id;
end;
$function$;

-- Remove per-row auth function evaluation and narrow profile visibility to
-- the rider plus people who share an active group with that rider.
drop policy if exists profiles_select_authenticated on public.profiles;
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
      and public.is_group_member(mine.group_id, (select auth.uid()))
  )
);

drop policy if exists profiles_insert_self on public.profiles;
create policy profiles_insert_self on public.profiles
for insert to authenticated with check (id = (select auth.uid()));

drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles
for update to authenticated
using (id = (select auth.uid()))
with check (id = (select auth.uid()));

drop policy if exists groups_select_member on public.groups;
create policy groups_select_member on public.groups
for select to authenticated
using (deleted_at is null and public.is_group_member(id, (select auth.uid())));

drop policy if exists groups_update_owner on public.groups;
create policy groups_update_owner on public.groups
for update to authenticated
using (deleted_at is null and owner_id = (select auth.uid()))
with check (owner_id = (select auth.uid()));

drop policy if exists groups_delete_owner on public.groups;
create policy groups_delete_owner on public.groups
for delete to authenticated using (owner_id = (select auth.uid()));

drop policy if exists group_members_select_member on public.group_members;
create policy group_members_select_member on public.group_members
for select to authenticated
using (public.is_group_member(group_id, (select auth.uid())));

drop policy if exists group_members_insert_owner on public.group_members;
create policy group_members_insert_owner on public.group_members
for insert to authenticated
with check (
  public.is_group_owner(group_id, (select auth.uid()))
  or user_id = (select auth.uid())
);

drop policy if exists group_members_delete_owner_or_self on public.group_members;
create policy group_members_delete_owner_or_self on public.group_members
for delete to authenticated
using (
  user_id = (select auth.uid())
  or public.is_group_owner(group_id, (select auth.uid()))
);

drop policy if exists presence_select_group_member on public.rider_presence;
create policy presence_select_group_member on public.rider_presence
for select to authenticated
using (
  user_id = (select auth.uid())
  or exists (
    select 1 from public.group_members as mine
    where mine.user_id = (select auth.uid())
      and public.is_group_member(mine.group_id, rider_presence.user_id)
  )
);

drop policy if exists presence_insert_self on public.rider_presence;
create policy presence_insert_self on public.rider_presence
for insert to authenticated with check (user_id = (select auth.uid()));

drop policy if exists presence_update_self on public.rider_presence;
create policy presence_update_self on public.rider_presence
for update to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

drop policy if exists presence_delete_self on public.rider_presence;
create policy presence_delete_self on public.rider_presence
for delete to authenticated using (user_id = (select auth.uid()));

drop policy if exists alerts_select_group_member on public.rider_alerts;
create policy alerts_select_group_member on public.rider_alerts
for select to authenticated
using (public.is_group_member(group_id, (select auth.uid())));

drop policy if exists alerts_insert_self_member on public.rider_alerts;
create policy alerts_insert_self_member on public.rider_alerts
for insert to authenticated
with check (
  user_id = (select auth.uid())
  and public.is_group_member(group_id, (select auth.uid()))
);

drop policy if exists alerts_update_self_or_owner on public.rider_alerts;
drop policy if exists alerts_update_group_member on public.rider_alerts;
create policy alerts_update_group_member on public.rider_alerts
for update to authenticated
using (public.is_group_member(group_id, (select auth.uid())))
with check (public.is_group_member(group_id, (select auth.uid())));

drop policy if exists route_incidents_insert_self on public.route_incidents;
create policy route_incidents_insert_self on public.route_incidents
for insert to authenticated with check (user_id = (select auth.uid()));

drop policy if exists route_incidents_update_self on public.route_incidents;
create policy route_incidents_update_self on public.route_incidents
for update to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

drop policy if exists track_contributions_select_self on public.track_contributions;
create policy track_contributions_select_self on public.track_contributions
for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists track_contributions_insert_self on public.track_contributions;
create policy track_contributions_insert_self on public.track_contributions
for insert to authenticated with check (user_id = (select auth.uid()));

drop policy if exists group_members_can_receive_realtime on realtime.messages;
create policy group_members_can_receive_realtime on realtime.messages
for select to authenticated
using (
  realtime.topic() like 'group:%'
  and public.is_group_member(
    split_part(realtime.topic(), ':', 2)::uuid,
    (select auth.uid())
  )
);

drop policy if exists group_members_can_send_realtime on realtime.messages;
create policy group_members_can_send_realtime on realtime.messages
for insert to authenticated
with check (
  realtime.topic() like 'group:%'
  and public.is_group_member(
    split_part(realtime.topic(), ':', 2)::uuid,
    (select auth.uid())
  )
);

-- Supabase creates broad default table grants. RLS still protects rows, but
-- removing operations the app never uses gives each client role less power.
revoke all on all tables in schema public from anon;

revoke all on table public.profiles from authenticated;
grant select, insert, update on table public.profiles to authenticated;

revoke all on table public.groups from authenticated;
grant select on table public.groups to authenticated;

revoke all on table public.group_members from authenticated;
grant select on table public.group_members to authenticated;

revoke all on table public.rider_presence from authenticated;
grant select, insert, update, delete on table public.rider_presence to authenticated;

revoke all on table public.rider_alerts from authenticated;
grant select, insert, update on table public.rider_alerts to authenticated;

revoke all on table public.route_incidents from authenticated;
grant select, insert, update on table public.route_incidents to authenticated;

revoke all on table public.track_contributions from authenticated;
grant select, insert on table public.track_contributions to authenticated;

-- Existing definer functions are fully qualified; use an empty search path so
-- caller-controlled objects can never shadow their dependencies.
alter function public.set_updated_at() set search_path = '';
alter function public.handle_new_user() set search_path = '';
alter function public.join_group_by_invite_code(text) set search_path = '';
alter function public.delete_group(uuid) set search_path = '';
alter function public.delete_own_account() set search_path = '';
alter function public.create_group(text) set search_path = '';

revoke all on function public.guard_rider_alert_resolution() from public, anon, authenticated;
grant execute on function public.guard_rider_alert_resolution() to postgres, service_role;

commit;
