begin;

-- App Store account-deletion contract. This function is intentionally one
-- server transaction: any missing table, foreign-key conflict, or permission
-- error rolls the whole operation back and the iOS app reports that nothing
-- was confirmed deleted.
create or replace function public.delete_own_account()
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
    requester_id uuid := auth.uid();
begin
    if requester_id is null then
        raise exception using
            errcode = '42501',
            message = 'Authentication is required to delete an account.';
    end if;

    if not exists (select 1 from auth.users where id = requester_id) then
        raise exception using
            errcode = 'P0002',
            message = 'The authenticated account no longer exists.';
    end if;

    -- Groups owned by the rider end with the account. Remove group-scoped
    -- records first so no former member retains a channel or orphan membership.
    delete from public.rider_alerts as alert
    using public.groups as owned_group
    where owned_group.owner_id = requester_id
      and alert.group_id = owned_group.id;

    delete from public.group_members as membership
    using public.groups as owned_group
    where owned_group.owner_id = requester_id
      and membership.group_id = owned_group.id;

    delete from public.groups
    where owner_id = requester_id;

    -- Remove the rider's data in groups owned by somebody else and all
    -- account-associated safety/contribution records.
    delete from public.rider_alerts where user_id = requester_id;
    delete from public.rider_presence where user_id = requester_id;
    delete from public.route_incidents where user_id = requester_id;
    delete from public.track_contributions where user_id = requester_id;
    delete from public.group_members where user_id = requester_id;
    delete from public.profiles where id = requester_id;

    -- This is last on purpose. A foreign key the contract did not account for
    -- must fail the transaction instead of leaving an undeletable partial user.
    delete from auth.users where id = requester_id;
    if not found then
        raise exception using
            errcode = 'P0002',
            message = 'The authenticated account could not be deleted.';
    end if;
end;
$function$;

comment on function public.delete_own_account() is
    'Deletes auth.uid() and all DIRT-owned account data in one transaction.';

revoke all on function public.delete_own_account() from public;
revoke all on function public.delete_own_account() from anon;
grant execute on function public.delete_own_account() to authenticated;

commit;
