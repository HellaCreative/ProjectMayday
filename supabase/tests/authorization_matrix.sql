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

insert into public.rider_presence (
  user_id, sharing_enabled, status, latitude, longitude, accuracy_m, last_seen_at
)
values
  ('10000000-0000-0000-0000-000000000001', true, 'riding', 44.7, -63.3, 5, now()),
  ('10000000-0000-0000-0000-000000000002', true, 'riding', 44.8, -63.2, 5, now()),
  ('10000000-0000-0000-0000-000000000003', true, 'riding', 45.0, -63.0, 5, now());

insert into public.route_incidents (
  id, client_id, user_id, category, latitude, longitude, expires_at
)
values
  ('40000000-0000-0000-0000-000000000001',
   '41000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-000000000001',
   'blocked', 44.7, -63.3, now() + interval '1 day'),
  ('40000000-0000-0000-0000-000000000003',
   '41000000-0000-0000-0000-000000000003',
   '10000000-0000-0000-0000-000000000003',
   'blocked', 45.0, -63.0, now() + interval '1 day');

insert into public.track_contributions (id, user_id, edge_ids)
values
  ('50000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-000000000001', array['edge-a']),
  ('50000000-0000-0000-0000-000000000002',
   '10000000-0000-0000-0000-000000000002', array['edge-b']),
  ('50000000-0000-0000-0000-000000000003',
   '10000000-0000-0000-0000-000000000003', array['edge-c']);

set local role authenticated;
set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000002';

do $test$
declare
  visible_count integer;
  affected_count integer;
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

  select count(*) into visible_count from public.rider_presence;
  if visible_count <> 2 then
    raise exception 'member expected 2 visible presence rows, got %', visible_count;
  end if;

  select count(*) into visible_count from public.rider_alerts;
  if visible_count <> 1 then
    raise exception 'member expected 1 visible group alert, got %', visible_count;
  end if;

  select count(*) into visible_count from public.track_contributions;
  if visible_count <> 1 then
    raise exception 'member expected only their contribution, got %', visible_count;
  end if;

  -- Live route incidents are deliberately shared safety data. The author can
  -- edit their own report, but another signed-in rider cannot rewrite it.
  -- Hosted development may already contain real public incident reports.
  -- Assert visibility of both fixture authors without counting unrelated data.
  select count(*) into visible_count from public.route_incidents
  where id in (
    '40000000-0000-0000-0000-000000000001',
    '40000000-0000-0000-0000-000000000003'
  );
  if visible_count <> 2 then
    raise exception 'member expected 2 live shared incidents, got %', visible_count;
  end if;

  update public.rider_presence
  set status = 'offline'
  where user_id = '10000000-0000-0000-0000-000000000001';
  get diagnostics affected_count = row_count;
  if affected_count <> 0 then
    raise exception 'member updated another rider presence row';
  end if;

  update public.route_incidents
  set note = 'rewritten'
  where id = '40000000-0000-0000-0000-000000000001';
  get diagnostics affected_count = row_count;
  if affected_count <> 0 then
    raise exception 'member updated another rider incident';
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

  blocked := false;
  begin
    insert into public.group_members (group_id, user_id, role)
    values (
      '20000000-0000-0000-0000-000000000002',
      '10000000-0000-0000-0000-000000000002',
      'member'
    );
  exception when insufficient_privilege then
    blocked := true;
  end;
  if not blocked then
    raise exception 'direct membership insert was not blocked';
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

  blocked := false;
  begin
    insert into public.rider_alerts (group_id, user_id, status, message)
    values (
      '20000000-0000-0000-0000-000000000002',
      '10000000-0000-0000-0000-000000000002',
      'stuck',
      'wrong group'
    );
  exception when insufficient_privilege then
    blocked := true;
  end;
  if not blocked then
    raise exception 'nonmember alert insert was not blocked';
  end if;

  blocked := false;
  begin
    insert into public.track_contributions (user_id, edge_ids)
    values ('10000000-0000-0000-0000-000000000001', array['forged-edge']);
  exception when insufficient_privilege then
    blocked := true;
  end;
  if not blocked then
    raise exception 'cross-account contribution insert was not blocked';
  end if;

  blocked := false;
  begin
    insert into public.route_incidents (
      client_id, user_id, category, latitude, longitude, expires_at
    ) values (
      '41000000-0000-0000-0000-000000000099',
      '10000000-0000-0000-0000-000000000001',
      'blocked', 44.7, -63.3, now() + interval '1 day'
    );
  exception when insufficient_privilege then
    blocked := true;
  end;
  if not blocked then
    raise exception 'cross-account incident insert was not blocked';
  end if;

  -- Exercise the actual private Realtime table policies, not only their
  -- helper predicate: B may send/read in AB and cannot send in C's group.
  perform set_config(
    'realtime.topic',
    'group:20000000-0000-0000-0000-000000000001',
    true
  );
  insert into realtime.messages (id, topic, extension, payload, event, private)
  values (
    '60000000-0000-0000-0000-000000000001',
    'group:20000000-0000-0000-0000-000000000001',
    'broadcast', '{"matrix":true}', 'authorization_matrix', true
  );
  select count(*) into visible_count
  from realtime.messages
  where id = '60000000-0000-0000-0000-000000000001';
  if visible_count <> 1 then
    raise exception 'group member could not read their Realtime message';
  end if;

  perform set_config(
    'realtime.topic',
    'group:20000000-0000-0000-0000-000000000002',
    true
  );
  blocked := false;
  begin
    insert into realtime.messages (topic, extension, payload, event, private)
    values (
      'group:20000000-0000-0000-0000-000000000002',
      'broadcast', '{"matrix":true}', 'authorization_matrix', true
    );
  exception when insufficient_privilege then
    blocked := true;
  end;
  if not blocked then
    raise exception 'nonmember Realtime send was not blocked';
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

  perform set_config(
    'realtime.topic',
    'group:20000000-0000-0000-0000-000000000001',
    true
  );
  blocked := false;
  begin
    insert into realtime.messages (topic, extension, payload, event, private)
    values (
      'group:20000000-0000-0000-0000-000000000001',
      'broadcast', '{"matrix":true}', 'after_delete', true
    );
  exception when insufficient_privilege then
    blocked := true;
  end;
  if not blocked then
    raise exception 'deleted group still authorized Realtime send';
  end if;
end;
$test$;

reset role;
rollback;

select 'three-user authorization matrix passed' as result;
