create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '',
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(trim(name)) between 1 and 80),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  invite_code text not null unique default upper(substr(encode(gen_random_bytes(6), 'hex'), 1, 10)),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.group_members (
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null default 'member' check (role in ('owner', 'member')),
  created_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

create table if not exists public.rider_presence (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  sharing_enabled boolean not null default false,
  status text not null default 'available' check (status in ('available', 'breakdown', 'injured', 'stuck', 'offline')),
  latitude double precision check (latitude between -90 and 90),
  longitude double precision check (longitude between -180 and 180),
  heading double precision,
  speed_mps double precision,
  accuracy_m double precision,
  status_note text,
  last_seen_at timestamptz,
  updated_at timestamptz not null default now()
);

create table if not exists public.rider_alerts (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  status text not null check (status in ('breakdown', 'injured', 'stuck')),
  message text,
  latitude double precision check (latitude between -90 and 90),
  longitude double precision check (longitude between -180 and 180),
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

create index if not exists group_members_user_idx on public.group_members(user_id);
create index if not exists rider_alerts_group_created_idx on public.rider_alerts(group_id, created_at desc);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at before update on public.profiles
for each row execute function public.set_updated_at();

drop trigger if exists groups_set_updated_at on public.groups;
create trigger groups_set_updated_at before update on public.groups
for each row execute function public.set_updated_at();

drop trigger if exists presence_set_updated_at on public.rider_presence;
create trigger presence_set_updated_at before update on public.rider_presence
for each row execute function public.set_updated_at();

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'display_name', ''))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

alter table public.profiles enable row level security;
alter table public.groups enable row level security;
alter table public.group_members enable row level security;
alter table public.rider_presence enable row level security;
alter table public.rider_alerts enable row level security;

drop policy if exists profiles_select_authenticated on public.profiles;
create policy profiles_select_authenticated on public.profiles for select to authenticated using (true);
drop policy if exists profiles_insert_self on public.profiles;
create policy profiles_insert_self on public.profiles for insert to authenticated with check (id = auth.uid());
drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists groups_select_member on public.groups;
create policy groups_select_member on public.groups for select to authenticated using (
  owner_id = auth.uid() or exists (
    select 1 from public.group_members gm where gm.group_id = groups.id and gm.user_id = auth.uid()
  )
);
drop policy if exists groups_insert_owner on public.groups;
create policy groups_insert_owner on public.groups for insert to authenticated with check (owner_id = auth.uid());
drop policy if exists groups_update_owner on public.groups;
create policy groups_update_owner on public.groups for update to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());
drop policy if exists groups_delete_owner on public.groups;
create policy groups_delete_owner on public.groups for delete to authenticated using (owner_id = auth.uid());

drop policy if exists group_members_select_member on public.group_members;
create policy group_members_select_member on public.group_members for select to authenticated using (
  user_id = auth.uid() or exists (
    select 1 from public.group_members own where own.group_id = group_members.group_id and own.user_id = auth.uid()
  )
);
drop policy if exists group_members_insert_owner on public.group_members;
create policy group_members_insert_owner on public.group_members for insert to authenticated with check (
  exists (select 1 from public.groups g where g.id = group_members.group_id and g.owner_id = auth.uid())
  or user_id = auth.uid()
);
drop policy if exists group_members_delete_owner_or_self on public.group_members;
create policy group_members_delete_owner_or_self on public.group_members for delete to authenticated using (
  user_id = auth.uid() or exists (select 1 from public.groups g where g.id = group_members.group_id and g.owner_id = auth.uid())
);

drop policy if exists presence_select_group_member on public.rider_presence;
create policy presence_select_group_member on public.rider_presence for select to authenticated using (
  user_id = auth.uid() or exists (
    select 1 from public.group_members mine
    join public.group_members theirs on theirs.group_id = mine.group_id
    where mine.user_id = auth.uid() and theirs.user_id = rider_presence.user_id
  )
);
drop policy if exists presence_insert_self on public.rider_presence;
create policy presence_insert_self on public.rider_presence for insert to authenticated with check (user_id = auth.uid());
drop policy if exists presence_update_self on public.rider_presence;
create policy presence_update_self on public.rider_presence for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists presence_delete_self on public.rider_presence;
create policy presence_delete_self on public.rider_presence for delete to authenticated using (user_id = auth.uid());

drop policy if exists alerts_select_group_member on public.rider_alerts;
create policy alerts_select_group_member on public.rider_alerts for select to authenticated using (
  exists (select 1 from public.group_members gm where gm.group_id = rider_alerts.group_id and gm.user_id = auth.uid())
);
drop policy if exists alerts_insert_self_member on public.rider_alerts;
create policy alerts_insert_self_member on public.rider_alerts for insert to authenticated with check (
  user_id = auth.uid() and exists (select 1 from public.group_members gm where gm.group_id = rider_alerts.group_id and gm.user_id = auth.uid())
);
drop policy if exists alerts_update_self_or_owner on public.rider_alerts;
create policy alerts_update_self_or_owner on public.rider_alerts for update to authenticated using (
  user_id = auth.uid() or exists (select 1 from public.groups g where g.id = rider_alerts.group_id and g.owner_id = auth.uid())
);

-- Realtime is used for ephemeral group location; the database stores only the latest
-- presence/status record and alert history, never a high-volume GPS breadcrumb stream.
alter table public.rider_presence replica identity full;
alter table public.rider_alerts replica identity full;

-- Private Realtime channels: only authenticated members of the matching group
-- can publish or receive presence/broadcast messages for group:<uuid> topics.
drop policy if exists group_members_can_receive_realtime on realtime.messages;
create policy group_members_can_receive_realtime on realtime.messages for select to authenticated using (
  realtime.topic() like 'group:%' and exists (
    select 1 from public.group_members gm
    where gm.group_id = split_part(realtime.topic(), ':', 2)::uuid and gm.user_id = auth.uid()
  )
);

drop policy if exists group_members_can_send_realtime on realtime.messages;
create policy group_members_can_send_realtime on realtime.messages for insert to authenticated with check (
  realtime.topic() like 'group:%' and exists (
    select 1 from public.group_members gm
    where gm.group_id = split_part(realtime.topic(), ':', 2)::uuid and gm.user_id = auth.uid()
  )
);
