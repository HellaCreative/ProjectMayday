-- Run against a disposable/local database after all migrations. This test
-- always rolls back; its fixed UUIDs and invalid email domain must never be
-- used as development seed data.
begin;

insert into auth.users (
  id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
values
  ('10000000-0000-0000-0000-000000000001', 'authenticated', 'authenticated',
   'a@test.invalid', '{}', '{"display_name":"A"}', now(), now()),
  ('10000000-0000-0000-0000-000000000002', 'authenticated', 'authenticated',
   'b@test.invalid', '{}', '{"display_name":"B"}', now(), now()),
  ('10000000-0000-0000-0000-000000000003', 'authenticated', 'authenticated',
   'c@test.invalid', '{}', '{"display_name":"C"}', now(), now());

insert into public.groups (id, name, owner_id, invite_code)
values
  ('20000000-0000-0000-0000-000000000001', 'Group AB',
   '10000000-0000-0000-0000-000000000001', 'abc123'),
  ('20000000-0000-0000-0000-000000000002', 'Group C',
   '10000000-0000-0000-0000-000000000003', 'def456');

insert into public.group_members (group_id, user_id, role)
values
  ('20000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-000000000001', 'owner'),
  ('20000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-000000000002', 'member'),
  ('20000000-0000-0000-0000-000000000002',
   '10000000-0000-0000-0000-000000000003', 'owner');

insert into public.rider_alerts (id, group_id, user_id, status, message)
values (
  '30000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000001',
  'stuck',
  'help'
);

set local role authenticated;
set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000002';

do $test$
declare
  visible_count integer;
  blocked boolean := false;
  created_group uuid;
begin
  select count(*) into visible_count from public.profiles;
  if visible_count <> 2 then
    raise exception 'member expected 2 visible profiles, got %', visible_count;
  end if;

  select count(*) into visible_count from public.groups;
  if visible_count <> 1 then
    raise exception 'member expected 1 visible group, got %', visible_count;
  end if;

  select count(*) into visible_count from public.group_members;
  if visible_count <> 2 then
    raise exception 'member expected 2 visible memberships, got %', visible_count;
  end if;

  begin
    insert into public.groups (name, owner_id)
    values ('forbidden', '10000000-0000-0000-0000-000000000002');
  exception when insufficient_privilege then
    blocked := true;
  end;
  if not blocked then
    raise exception 'direct group insert was not blocked';
  end if;

  created_group := public.create_group('RPC Group');
  if created_group is null then
    raise exception 'create_group returned null';
  end if;

  update public.rider_alerts
  set resolved_at = now()
  where id = '30000000-0000-0000-0000-000000000001';
  if not found then
    raise exception 'group member could not resolve alert';
  end if;

  blocked := false;
  begin
    update public.rider_alerts
    set message = 'rewritten'
    where id = '30000000-0000-0000-0000-000000000001';
  exception when insufficient_privilege then
    blocked := true;
  end;
  if not blocked then
    raise exception 'alert message rewrite was not blocked';
  end if;
end;
$test$;

reset role;
set local role authenticated;
set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000001';

do $test$
declare
  blocked boolean := false;
  visible_count integer;
begin
  begin
    perform public.leave_group('20000000-0000-0000-0000-000000000001');
  exception when others then
    if sqlerrm like 'The group owner must delete%' then
      blocked := true;
    else
      raise;
    end if;
  end;
  if not blocked then
    raise exception 'owner leave was not blocked';
  end if;

  perform public.delete_group('20000000-0000-0000-0000-000000000001');
  select count(*) into visible_count
  from public.groups
  where id = '20000000-0000-0000-0000-000000000001';
  if visible_count <> 0 then
    raise exception 'deleted group remained visible';
  end if;

  if private.is_group_member(
    '20000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000001'
  ) then
    raise exception 'deleted group still authorized membership';
  end if;
end;
$test$;

reset role;
rollback;

select 'three-user authorization matrix passed' as result;
