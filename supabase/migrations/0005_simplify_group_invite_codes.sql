-- Group invite codes are for a small riding group, not account security.
-- Keep them short and easy to read while retaining a unique constraint.
alter table public.groups
  alter column invite_code set default lower(substr(encode(extensions.gen_random_bytes(4), 'hex'), 1, 6));

-- Refresh existing POC groups to the new format as well.
update public.groups
set invite_code = lower(substr(encode(extensions.gen_random_bytes(4), 'hex'), 1, 6));
