alter table public.groups add column if not exists deleted_at timestamptz;

create or replace function public.join_group_by_invite_code(p_invite_code text)
returns table (id uuid, name text, owner_id uuid, invite_code text, created_at timestamptz, deleted_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
  normalized_code text := lower(trim(coalesce(p_invite_code, '')));
  target_group public.groups%rowtype;
  current_user_id uuid := auth.uid();
begin
  if current_user_id is null then
    raise exception 'You must be signed in to join a group.';
  end if;
  if normalized_code !~ '^[a-z0-9]{6}$' then
    raise exception 'Invite codes are six lowercase letters or numbers.';
  end if;

  select g.* into target_group
  from public.groups g
  where lower(g.invite_code) = normalized_code
    and g.deleted_at is null
  limit 1;

  if not found then
    raise exception 'No active riding group was found for that code.';
  end if;

  insert into public.group_members (group_id, user_id, role)
  values (target_group.id, current_user_id, 'member')
  on conflict (group_id, user_id) do nothing;

  return query select target_group.id, target_group.name, target_group.owner_id,
    target_group.invite_code, target_group.created_at, target_group.deleted_at;
end;
$$;

create or replace function public.delete_group(p_group_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_group_owner(p_group_id, auth.uid()) then
    raise exception 'Only the group owner can delete this group.';
  end if;
  update public.groups
  set deleted_at = coalesce(deleted_at, now())
  where id = p_group_id;
end;
$$;

create or replace function public.leave_group(p_group_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'You must be signed in to leave a group.';
  end if;
  delete from public.group_members
  where group_id = p_group_id and user_id = auth.uid();
end;
$$;

revoke execute on function public.join_group_by_invite_code(text) from public, anon;
revoke execute on function public.delete_group(uuid) from public, anon;
revoke execute on function public.leave_group(uuid) from public, anon;
grant execute on function public.join_group_by_invite_code(text) to authenticated, service_role;
grant execute on function public.delete_group(uuid) to authenticated, service_role;
grant execute on function public.leave_group(uuid) to authenticated, service_role;
