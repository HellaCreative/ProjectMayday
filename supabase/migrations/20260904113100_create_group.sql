begin;

-- Creates the group and its owner membership in one transaction. The caller
-- supplies only the display name; ownership is always derived from auth.uid().
create or replace function public.create_group(p_name text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
    requester_id uuid := auth.uid();
    cleaned_name text := btrim(regexp_replace(coalesce(p_name, ''), E'[\n\r]+', ' ', 'g'));
    created_id uuid;
begin
    if requester_id is null then
        raise exception using
            errcode = '42501',
            message = 'Authentication is required to create a group.';
    end if;

    if char_length(cleaned_name) < 1 or char_length(cleaned_name) > 60 then
        raise exception using
            errcode = '22023',
            message = 'Group names must be between 1 and 60 characters.';
    end if;

    insert into public.groups (name, owner_id)
    values (cleaned_name, requester_id)
    returning id into created_id;

    insert into public.group_members (group_id, user_id, role)
    values (created_id, requester_id, 'owner');

    return created_id;
end;
$function$;

comment on function public.create_group(text) is
    'Atomically creates a group and its owner membership for auth.uid().';

revoke all on function public.create_group(text) from public;
revoke all on function public.create_group(text) from anon;
grant execute on function public.create_group(text) to authenticated;

commit;
