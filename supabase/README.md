# DIRT Supabase release contract

This folder versions the database behavior the iOS app relies on. It is not
evidence that the live Supabase project has been changed. Apply migrations only
through the linked, reviewed Supabase project and retain the migration output.

## Account deletion

`delete_own_account()` is the only deletion entry point used by the app. It:

- derives the target exclusively from `auth.uid()` and accepts no user id;
- runs as one fail-closed transaction;
- deletes groups owned by the rider and their group-scoped rows;
- deletes the rider's profile, memberships, presence, alerts, incident reports,
  and track contributions; and
- deletes `auth.users` last, so an unknown foreign key rolls everything back.

Before shipping, apply `migrations/20260904010000_delete_own_account.sql` to a
staging project first. Verify with a real Apple-authenticated test account that:

1. an anonymous request cannot execute the function;
2. one signed-in rider cannot select or delete another rider's data;
3. deleting a member leaves unrelated groups and members untouched;
4. deleting an owner removes that owner's groups and group-scoped rows;
5. no rows remain for the deleted user in every table named by the migration;
6. the Auth user is gone and an old access token cannot access data; and
7. forcing a foreign-key failure leaves the Auth user and every row intact.

Account deletion does not cancel an App Store subscription. The app states this
before confirmation and keeps Apple's subscription-management path available.

Because the native sign-in path does not yet exchange Apple's one-time
authorization code for a server-held refresh token, production deletion must
also direct the rider to revoke DIRT under Apple Account settings. Before this
can be called fully automated, add the server-side Apple token exchange,
encrypted token storage, `/auth/revoke` call, and credential-revocation event
handling. No Apple private key or client secret belongs in the app or database
migrations.

## Atomic group creation

`create_group(p_name)` in
`migrations/20260904020000_create_group.sql` derives ownership from
`auth.uid()`, validates the final server-side name, and inserts the group plus
owner membership in one transaction. Deploy it before testing any build that
contains the matching client call. Verify that anonymous callers are rejected,
membership failure rolls back the group row, and the caller cannot choose a
different owner.

## Required Groups RLS verification

The production policies are not exported in this repository yet, so their live
state cannot be inferred from client code. Export and review the actual schema,
functions, grants, and policies before launch. Test with at least three users in
two overlapping groups and prove this matrix:

| Surface | Required rule |
| --- | --- |
| `groups` | Only active members can read; only the owner can rename/delete. |
| `group_members` | Members can read their group's roster; invite-code joining is RPC-only; only self can leave. |
| `profiles` | Group peers can read only the display-name fields needed by the roster; self can update self. |
| `rider_presence` | A rider can write only their own row; only group peers can read it. |
| `rider_alerts` | A rider can insert only as self into a joined group; only that group's members can read it. |
| `route_incidents` | A rider can write only as self; public/shared reads expose only approved fields. |
| `track_contributions` | A rider can insert only as self; other clients cannot read raw contributions. |
| private Realtime | A client can subscribe/send only for a group they currently belong to. |

Also export the definitions and grants for `create_group`,
`join_group_by_invite_code`, `leave_group`, and `delete_group`.
