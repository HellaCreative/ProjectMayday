-- Group creation and invite-code joining are RPC-only. The RPCs derive the
-- acting user from auth.uid(); mobile clients cannot choose an owner/member.

drop policy if exists groups_insert_owner on public.groups;
drop policy if exists group_members_insert_owner on public.group_members;

revoke insert on table public.groups from authenticated;
revoke insert on table public.group_members from authenticated;
