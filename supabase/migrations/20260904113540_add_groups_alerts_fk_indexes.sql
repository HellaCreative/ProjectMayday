-- Cover foreign keys used during owner/account deletion and alert cleanup.

create index if not exists groups_owner_id_idx
on public.groups (owner_id);

create index if not exists rider_alerts_user_id_idx
on public.rider_alerts (user_id);
