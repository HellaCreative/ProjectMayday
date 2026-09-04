-- Any group member can resolve peer distress alerts (dismiss / clear toast).
drop policy if exists alerts_update_self_or_owner on public.rider_alerts;
create policy alerts_update_group_member on public.rider_alerts
for update to authenticated
using (public.is_group_member(group_id, auth.uid()))
with check (public.is_group_member(group_id, auth.uid()));
