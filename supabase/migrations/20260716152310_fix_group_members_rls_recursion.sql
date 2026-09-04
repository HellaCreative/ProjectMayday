-- Keep membership checks out of row-level policies on group_members itself.
-- A policy that queries group_members recursively causes Supabase/Postgres to
-- reject every read with "infinite recursion detected".
create or replace function public.is_group_member(p_group_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.group_members gm
    where gm.group_id = p_group_id
      and gm.user_id = p_user_id
  );
$$;

create or replace function public.is_group_owner(p_group_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.groups g
    where g.id = p_group_id
      and g.owner_id = p_user_id
  );
$$;

revoke execute on function public.is_group_member(uuid, uuid) from public, anon;
revoke execute on function public.is_group_owner(uuid, uuid) from public, anon;
grant execute on function public.is_group_member(uuid, uuid) to authenticated, service_role;
grant execute on function public.is_group_owner(uuid, uuid) to authenticated, service_role;

drop policy if exists groups_select_member on public.groups;
create policy groups_select_member on public.groups for select to authenticated using (
  owner_id = auth.uid() or public.is_group_member(id, auth.uid())
);

drop policy if exists group_members_select_member on public.group_members;
create policy group_members_select_member on public.group_members for select to authenticated using (
  user_id = auth.uid() or public.is_group_member(group_id, auth.uid())
);

drop policy if exists group_members_insert_owner on public.group_members;
create policy group_members_insert_owner on public.group_members for insert to authenticated with check (
  public.is_group_owner(group_id, auth.uid()) or user_id = auth.uid()
);

drop policy if exists group_members_delete_owner_or_self on public.group_members;
create policy group_members_delete_owner_or_self on public.group_members for delete to authenticated using (
  user_id = auth.uid() or public.is_group_owner(group_id, auth.uid())
);

drop policy if exists presence_select_group_member on public.rider_presence;
create policy presence_select_group_member on public.rider_presence for select to authenticated using (
  user_id = auth.uid() or exists (
    select 1
    from public.group_members mine
    where mine.user_id = auth.uid()
      and public.is_group_member(mine.group_id, rider_presence.user_id)
  )
);

drop policy if exists alerts_select_group_member on public.rider_alerts;
create policy alerts_select_group_member on public.rider_alerts for select to authenticated using (
  public.is_group_member(group_id, auth.uid())
);

drop policy if exists alerts_insert_self_member on public.rider_alerts;
create policy alerts_insert_self_member on public.rider_alerts for insert to authenticated with check (
  user_id = auth.uid() and public.is_group_member(group_id, auth.uid())
);

drop policy if exists alerts_update_self_or_owner on public.rider_alerts;
create policy alerts_update_self_or_owner on public.rider_alerts for update to authenticated using (
  user_id = auth.uid() or public.is_group_owner(group_id, auth.uid())
);

drop policy if exists group_members_can_receive_realtime on realtime.messages;
create policy group_members_can_receive_realtime on realtime.messages for select to authenticated using (
  realtime.topic() like 'group:%'
  and public.is_group_member(split_part(realtime.topic(), ':', 2)::uuid, auth.uid())
);

drop policy if exists group_members_can_send_realtime on realtime.messages;
create policy group_members_can_send_realtime on realtime.messages for insert to authenticated with check (
  realtime.topic() like 'group:%'
  and public.is_group_member(split_part(realtime.topic(), ':', 2)::uuid, auth.uid())
);
