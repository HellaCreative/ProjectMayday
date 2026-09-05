-- Run against a disposable/local database after all migrations. This test
-- always rolls back. It proves the server-owned account deletion contract,
-- including cross-account isolation and fail-closed atomicity.
begin;

insert into auth.users (
  id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
values
  ('70000000-0000-0000-0000-000000000001', 'authenticated', 'authenticated',
   'owner@test.invalid', '{}', '{"display_name":"Owner"}', now(), now()),
  ('70000000-0000-0000-0000-000000000002', 'authenticated', 'authenticated',
   'member@test.invalid', '{}', '{"display_name":"Member"}', now(), now()),
  ('70000000-0000-0000-0000-000000000003', 'authenticated', 'authenticated',
   'unrelated@test.invalid', '{}', '{"display_name":"Unrelated"}', now(), now()),
  ('70000000-0000-0000-0000-000000000004', 'authenticated', 'authenticated',
   'rollback@test.invalid', '{}', '{"display_name":"Rollback"}', now(), now());

insert into auth.sessions (id, user_id, aal, created_at, updated_at)
values
  ('71000000-0000-0000-0000-000000000001',
   '70000000-0000-0000-0000-000000000001', 'aal1', now(), now()),
  ('71000000-0000-0000-0000-000000000002',
   '70000000-0000-0000-0000-000000000002', 'aal1', now(), now()),
  ('71000000-0000-0000-0000-000000000003',
   '70000000-0000-0000-0000-000000000003', 'aal1', now(), now()),
  ('71000000-0000-0000-0000-000000000004',
   '70000000-0000-0000-0000-000000000004', 'aal1', now(), now());

insert into public.groups (id, name, owner_id, invite_code)
values
  ('72000000-0000-0000-0000-000000000001', 'Owner group',
   '70000000-0000-0000-0000-000000000001', 'own001'),
  ('72000000-0000-0000-0000-000000000003', 'Unrelated group',
   '70000000-0000-0000-0000-000000000003', 'unr003');

insert into public.group_members (group_id, user_id, role)
values
  ('72000000-0000-0000-0000-000000000001',
   '70000000-0000-0000-0000-000000000001', 'owner'),
  ('72000000-0000-0000-0000-000000000001',
   '70000000-0000-0000-0000-000000000002', 'member'),
  ('72000000-0000-0000-0000-000000000003',
   '70000000-0000-0000-0000-000000000003', 'owner');

insert into public.rider_presence (
  user_id, sharing_enabled, status, latitude, longitude, accuracy_m, last_seen_at
)
values
  ('70000000-0000-0000-0000-000000000001', true, 'riding', 44.7, -63.3, 5, now()),
  ('70000000-0000-0000-0000-000000000002', true, 'riding', 44.8, -63.2, 5, now()),
  ('70000000-0000-0000-0000-000000000003', true, 'riding', 45.0, -63.0, 5, now()),
  ('70000000-0000-0000-0000-000000000004', true, 'riding', 45.1, -62.9, 5, now());

insert into public.rider_alerts (id, group_id, user_id, status, message)
values
  ('73000000-0000-0000-0000-000000000001',
   '72000000-0000-0000-0000-000000000001',
   '70000000-0000-0000-0000-000000000001', 'stuck', 'owner alert'),
  ('73000000-0000-0000-0000-000000000002',
   '72000000-0000-0000-0000-000000000001',
   '70000000-0000-0000-0000-000000000002', 'stuck', 'member alert'),
  ('73000000-0000-0000-0000-000000000003',
   '72000000-0000-0000-0000-000000000003',
   '70000000-0000-0000-0000-000000000003', 'stuck', 'unrelated alert');

insert into public.route_incidents (
  id, client_id, user_id, category, latitude, longitude, expires_at
)
values
  ('74000000-0000-0000-0000-000000000002',
   '74100000-0000-0000-0000-000000000002',
   '70000000-0000-0000-0000-000000000002',
   'blocked', 44.8, -63.2, now() + interval '1 day'),
  ('74000000-0000-0000-0000-000000000003',
   '74100000-0000-0000-0000-000000000003',
   '70000000-0000-0000-0000-000000000003',
   'blocked', 45.0, -63.0, now() + interval '1 day'),
  ('74000000-0000-0000-0000-000000000004',
   '74100000-0000-0000-0000-000000000004',
   '70000000-0000-0000-0000-000000000004',
   'blocked', 45.1, -62.9, now() + interval '1 day');

insert into public.track_contributions (id, user_id, edge_ids)
values
  ('75000000-0000-0000-0000-000000000002',
   '70000000-0000-0000-0000-000000000002', array['member-edge']),
  ('75000000-0000-0000-0000-000000000003',
   '70000000-0000-0000-0000-000000000003', array['unrelated-edge']),
  ('75000000-0000-0000-0000-000000000004',
   '70000000-0000-0000-0000-000000000004', array['rollback-edge']);

-- Anonymous callers never reach the privileged deletion function.
set local role anon;
do $test$
declare
  blocked boolean := false;
begin
  begin
    perform public.delete_own_account();
  exception when insufficient_privilege then
    blocked := true;
  end;
  if not blocked then
    raise exception 'anonymous account deletion was not blocked';
  end if;
end;
$test$;

-- Deleting a member removes only that rider and their account-owned data.
reset role;
set local role authenticated;
set local request.jwt.claim.sub = '70000000-0000-0000-0000-000000000002';
select public.delete_own_account();
reset role;

do $test$
declare
  found_count integer;
begin
  select count(*) into found_count
  from auth.users where id = '70000000-0000-0000-0000-000000000002';
  if found_count <> 0 then raise exception 'member Auth user remained'; end if;

  select count(*) into found_count
  from auth.sessions where user_id = '70000000-0000-0000-0000-000000000002';
  if found_count <> 0 then raise exception 'member Auth session remained'; end if;

  select count(*) into found_count
  from public.profiles where id = '70000000-0000-0000-0000-000000000002';
  if found_count <> 0 then raise exception 'member profile remained'; end if;

  select count(*) into found_count
  from public.group_members where user_id = '70000000-0000-0000-0000-000000000002';
  if found_count <> 0 then raise exception 'member membership remained'; end if;

  select count(*) into found_count
  from public.rider_presence where user_id = '70000000-0000-0000-0000-000000000002';
  if found_count <> 0 then raise exception 'member presence remained'; end if;

  select count(*) into found_count
  from public.rider_alerts where user_id = '70000000-0000-0000-0000-000000000002';
  if found_count <> 0 then raise exception 'member alert remained'; end if;

  select count(*) into found_count
  from public.route_incidents where user_id = '70000000-0000-0000-0000-000000000002';
  if found_count <> 0 then raise exception 'member incident remained'; end if;

  select count(*) into found_count
  from public.track_contributions where user_id = '70000000-0000-0000-0000-000000000002';
  if found_count <> 0 then raise exception 'member contribution remained'; end if;

  select count(*) into found_count
  from public.groups where id = '72000000-0000-0000-0000-000000000001';
  if found_count <> 1 then raise exception 'member deletion removed owner group'; end if;

  select count(*) into found_count
  from auth.users where id = '70000000-0000-0000-0000-000000000003';
  if found_count <> 1 then raise exception 'member deletion touched unrelated user'; end if;
end;
$test$;

-- Deleting an owner removes their group and every group-scoped row while the
-- unrelated account/group remains intact.
set local role authenticated;
set local request.jwt.claim.sub = '70000000-0000-0000-0000-000000000001';
select public.delete_own_account();
reset role;

do $test$
declare
  found_count integer;
begin
  select count(*) into found_count
  from public.groups where id = '72000000-0000-0000-0000-000000000001';
  if found_count <> 0 then raise exception 'owner group remained'; end if;

  select count(*) into found_count
  from public.rider_alerts where group_id = '72000000-0000-0000-0000-000000000001';
  if found_count <> 0 then raise exception 'owner group alert remained'; end if;

  select count(*) into found_count
  from public.groups where id = '72000000-0000-0000-0000-000000000003';
  if found_count <> 1 then raise exception 'owner deletion touched unrelated group'; end if;

  select count(*) into found_count
  from public.rider_alerts where id = '73000000-0000-0000-0000-000000000003';
  if found_count <> 1 then raise exception 'owner deletion touched unrelated alert'; end if;
end;
$test$;

-- Manufacture an unaccounted foreign key to prove that any late deletion
-- failure rolls the whole RPC back instead of partially erasing the rider.
create table public.__dirt_account_deletion_blocker_test (
  user_id uuid primary key references auth.users(id)
);
insert into public.__dirt_account_deletion_blocker_test
values ('70000000-0000-0000-0000-000000000004');

set local role authenticated;
set local request.jwt.claim.sub = '70000000-0000-0000-0000-000000000004';
do $test$
declare
  blocked boolean := false;
begin
  begin
    perform public.delete_own_account();
  exception when foreign_key_violation then
    blocked := true;
  end;
  if not blocked then
    raise exception 'forced deletion failure did not fail closed';
  end if;
end;
$test$;
reset role;

do $test$
declare
  found_count integer;
begin
  select count(*) into found_count
  from auth.users where id = '70000000-0000-0000-0000-000000000004';
  if found_count <> 1 then raise exception 'failed deletion removed Auth user'; end if;

  select count(*) into found_count
  from auth.sessions where user_id = '70000000-0000-0000-0000-000000000004';
  if found_count <> 1 then raise exception 'failed deletion removed Auth session'; end if;

  select count(*) into found_count
  from public.profiles where id = '70000000-0000-0000-0000-000000000004';
  if found_count <> 1 then raise exception 'failed deletion removed profile'; end if;

  select count(*) into found_count
  from public.rider_presence where user_id = '70000000-0000-0000-0000-000000000004';
  if found_count <> 1 then raise exception 'failed deletion removed presence'; end if;

  select count(*) into found_count
  from public.route_incidents where user_id = '70000000-0000-0000-0000-000000000004';
  if found_count <> 1 then raise exception 'failed deletion removed incident'; end if;

  select count(*) into found_count
  from public.track_contributions where user_id = '70000000-0000-0000-0000-000000000004';
  if found_count <> 1 then raise exception 'failed deletion removed contribution'; end if;
end;
$test$;

rollback;

select 'account deletion matrix passed' as result;
