alter table public.rider_presence
  alter column status set default 'riding';

alter table public.rider_presence
  drop constraint if exists rider_presence_status_check;

alter table public.rider_presence
  add constraint rider_presence_status_check
  check (status in (
    'riding', 'flat_tire', 'dead_battery', 'unrepairable', 'injured', 'stuck', 'offline',
    'available', 'breakdown'
  ));

alter table public.rider_alerts
  drop constraint if exists rider_alerts_status_check;

alter table public.rider_alerts
  add constraint rider_alerts_status_check
  check (status in (
    'flat_tire', 'dead_battery', 'unrepairable', 'injured', 'stuck', 'breakdown'
  ));

comment on column public.rider_presence.status is
  'Rider-selected state. Current values: riding, flat_tire, dead_battery, unrepairable, injured, stuck, offline. Legacy available and breakdown remain readable during client migration.';
