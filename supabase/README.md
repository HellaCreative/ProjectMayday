# DIRT Supabase release contract

This folder versions the database behavior the iOS and Android apps rely on.
Apply migrations only through the linked, reviewed Supabase project and retain
the migration output.

The full production migration history is now present here. The eight original
migrations were recovered verbatim from Supabase's migration ledger on
2026-09-04; the four launch migrations were already source-controlled. A fresh
development project must replay this complete chain before it can be treated as
a faithful test environment.

## Production status — 2026-09-04

Project `dirt-mayday` (`iiiguqknqxoumlmppzfw`, Canada Central) is healthy. The
following repository migrations are applied in production with matching
Supabase migration versions:

- `20260904113053_delete_own_account.sql`
- `20260904113100_create_group.sql`
- `20260904113540_add_groups_alerts_fk_indexes.sql`
- `20260904114232_require_group_rpcs.sql`

Apple and Google sign-in providers are enabled. Metadata checks prove that the
two public app RPCs deny anonymous execution and allow signed-in execution.
Real-account deletion and multi-account Groups tests remain release gates.

The post-deployment advisors report no missing foreign-key indexes. Their
remaining findings are tracked rather than hidden:

- the app-facing RPCs intentionally use `SECURITY DEFINER`; each must continue
  to derive identity from `auth.uid()`, use qualified objects, deny `anon`, and
  expose only the minimum signed-in operation;
- direct group/member insertion is disabled; group creation and invite-code
  joining are now restricted to their authenticated RPCs;
- older group helper functions and the remaining RLS policies still need a
  versioned hardening migration and multi-account regression test;
- existing RLS expressions should use the single-evaluation `(select
  auth.uid())` form before scale; and
- leaked-password protection is disabled and should be enabled if password or
  email authentication remains available at launch.

Advisor references: [security-definer functions](https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable),
[RLS function evaluation](https://supabase.com/docs/guides/database/postgres/row-level-security#call-functions-with-select),
and [leaked-password protection](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection).

## Account deletion

`delete_own_account()` is the only deletion entry point used by the app. It:

- derives the target exclusively from `auth.uid()` and accepts no user id;
- runs as one fail-closed transaction;
- deletes groups owned by the rider and their group-scoped rows;
- deletes the rider's profile, memberships, presence, alerts, incident reports,
  and track contributions; and
- deletes `auth.users` last, so an unknown foreign key rolls everything back.

The production function comes from
`migrations/20260904113053_delete_own_account.sql`. Before shipping, verify with
a disposable, Apple-authenticated test account that:

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
`migrations/20260904113100_create_group.sql` derives ownership from
`auth.uid()`, validates the final server-side name, and inserts the group plus
owner membership in one transaction. It is deployed in production. Anonymous
execution is denied at the database grant boundary; a disposable signed-in
account must still prove creation, rollback, and owner isolation end to end.

## Required Groups RLS verification

The live policies were inspected on 2026-09-04 and their complete migration
history is now versioned. Direct `groups` and `group_members` inserts are
disabled, making group creation and invite-code joining RPC-only. Test with at
least three users in two overlapping groups and prove this matrix:

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
