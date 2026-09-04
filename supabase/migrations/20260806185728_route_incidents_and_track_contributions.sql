create table if not exists public.route_incidents (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null,
  user_id uuid references public.profiles(id) on delete set null,
  category text not null check (category in (
    'access_closed','gate_seasonal','flooded','blocked','unsafe','other'
  )),
  status text not null default 'unverified'
    check (status in ('unverified','confirmed','dismissed','expired')),
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  edge_id text,
  region_code text,
  pack_version text,
  note text,
  confirmations int not null default 0 check (confirmations >= 0),
  source text not null default 'rider_report',
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  unique (client_id)
);

create index if not exists route_incidents_edge_live_idx
  on public.route_incidents (edge_id, status, expires_at);

create index if not exists route_incidents_created_idx
  on public.route_incidents (created_at desc);

create index if not exists route_incidents_user_created_idx
  on public.route_incidents (user_id, created_at desc);

create table if not exists public.track_contributions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  edge_ids text[] not null check (cardinality(edge_ids) >= 1),
  distance_m double precision,
  region_codes text[],
  pack_version text,
  started_at timestamptz,
  ended_at timestamptz not null default now(),
  consent_version text not null default 'track_contrib_v1',
  created_at timestamptz not null default now()
);

create index if not exists track_contributions_user_created_idx
  on public.track_contributions (user_id, created_at desc);

create index if not exists track_contributions_ended_idx
  on public.track_contributions (ended_at desc);

alter table public.route_incidents enable row level security;
alter table public.track_contributions enable row level security;

drop policy if exists route_incidents_select_live on public.route_incidents;
create policy route_incidents_select_live on public.route_incidents
  for select to authenticated
  using (status in ('unverified', 'confirmed') and expires_at > now());

drop policy if exists route_incidents_insert_self on public.route_incidents;
create policy route_incidents_insert_self on public.route_incidents
  for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists route_incidents_update_self on public.route_incidents;
create policy route_incidents_update_self on public.route_incidents
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists track_contributions_select_self on public.track_contributions;
create policy track_contributions_select_self on public.track_contributions
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists track_contributions_insert_self on public.track_contributions;
create policy track_contributions_insert_self on public.track_contributions
  for insert to authenticated
  with check (user_id = auth.uid());
