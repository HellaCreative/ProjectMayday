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
