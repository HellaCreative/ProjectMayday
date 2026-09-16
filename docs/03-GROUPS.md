# DIRT iOS — Groups

Group ride list/detail, invite codes, presence sharing, and map roster. Spec: the iOS docs §4. Auth prerequisite: [04-PROFILES-AUTH.md](./04-PROFILES-AUTH.md).

---

## Key files

| File | Role |
| --- | --- |
| `Dirt/Features/Groups/GroupsViewModel.swift` | Membership, validated presence, realtime, and polling fallback |
| `Dirt/Features/Groups/GroupSafetyPolicies.swift` | Presence validity and stop-trigger tracking rules |
| `Dirt/Features/Groups/GroupsSheet.swift` | List / detail UI, roster, invite, in-sheet sharing |
| `Dirt/Features/Groups/GroupNavigationNoticeBanner.swift` | Stop-trigger notices + peer-alert HUD |
| `Dirt/Features/Map/MapControlStack.swift` | Rider-status sharing popover on the map |
| `Dirt/App/RootView.swift` | Dock Group panel, peer pin sheet, replace-route confirm |
| `Dirt/Features/RoutePlanning/RoutePlannerModel.swift` | `routeToMember`, stop-trigger tracking, sharing-ended notice |
| `Dirt/Persistence/SupabaseService.swift` | Client + session |
| `Dirt/Map/MapState.swift` | Independent rider and planner marker state |

---

## Supabase surfaces used

### Tables

| Table | iOS usage |
| --- | --- |
| `group_members` | List memberships (`role` + nested `groups`); member roster with `profiles(display_name)` |
| `groups` | Read membership summaries; create/delete through RPCs (`deleted_at` filtered client-side) |
| `rider_presence` | Upsert while sharing; select for live counts + map pins |
| `rider_alerts` | Insert distress/route reports, fetch unresolved peer alerts, resolve dismissed/recovered alerts |
| `profiles` | Nested select for display names (writes happen in auth/profile flow) |

### RPCs

| RPC | Args | When |
| --- | --- | --- |
| `create_group` | `p_name` | Atomically create group + owner membership |
| `join_group_by_invite_code` | `p_invite_code` | Join |
| `leave_group` | `p_group_id` | Non-owner leave |
| `delete_group` | `p_group_id` | Owner soft-delete |

### Invite codes

Client validates `^[a-z0-9]{6}$` (trimmed, lowercased) before RPC.

### Live heuristic

List path:

- `sharing_enabled == true`
- valid, non-sentinel coordinate
- `last_seen_at` parses and is within **120s**

ISO8601 parsing accepts fractional seconds (`ISO8601DateFormatterBox`).
Missing, future, malformed, or stale timestamps are offline, never live.

---

## Features implemented

| Feature | Behaviour |
| --- | --- |
| Auth gate | Sheet shows sign-in prompt if `!supabase.isSignedIn` |
| List | Name · created/joined · rider count · live count; quiet “Showing {name} on the map”; pull-to-refresh |
| Create | Inline name field (1–60 chars), then transactional `create_group` so group + owner membership succeed or roll back together |
| Join | Inline 6-character invite code → RPC → refresh |
| Detail | Invite code + copy; roster; confirm before leave/delete |
| Start sharing | Map Rider-status popover **or** own roster row. Wait for a current, accurate GPS fix, then `requestAlways` + background location; upsert every **10s** normally and every **5s** during distress. Sharing is account-wide to every membership. |
| Stop sharing | Broadcast sharing-off, upsert `sharing_enabled: false`, `status: offline`, and release only the group-sharing background-location claim |
| Status while sharing | `riding` \| `flat_tire` \| `dead_battery` \| `unrepairable` \| `injured` \| `stuck` (picker) |
| Roster refresh | While group detail is open, poll every **5s**. After close, **30s** when Realtime is connected and **10s** when it is down |
| Map pins | Live peers (not self): status-colored dot + **name/status chip**; pins keep updating after sheet close while that group is tracked |
| Focus peer | Scope button flies map to peer, closes sheet |
| Pin sheet | Tap a live peer pin → compact name / status / Live location / Route to rider |
| Route to member | Sheet **or tap peer pin on map** → route to the validated last-known position while preserving stable group/member identity. If already navigating to a different rider, confirm then end current nav and route to the new member. Offline/stale never routes. |
| Stop-trigger tracking | During navigation the route stays frozen while the follower is moving. After an 8s stop, it updates if the member moved at least 100m and is still live. Resuming motion cancels/discards the update. |
| Tracking notice | A successful update, sharing end, or safe fallback produces a persistent, dismissible navigation notice |
| Peer alerts | Distress status and route reports are persisted and broadcast only to the selected/tracked target group, shown above the map, and reconciled against current presence |
| Sign out | Broadcast offline, stop sharing/tracking tasks, close channels, and clear roster/pins before auth is removed |
| Close sheet | `onDisappear` → `closeDetail()` (reset to list) |

Presence upsert payload fields: `user_id`, `sharing_enabled`, `status`, `latitude`, `longitude`, `heading`, `speed_mps`, `accuracy_m`, `last_seen_at`.

When a stationary phone has only an old cached fix, Start Sharing restarts the
standard Core Location stream to force a newly timestamped reading. The rider
remains in the explicit waiting state until that fix passes the shared freshness
and accuracy policy; the app never manufactures a green/live state from an
unpublishable coordinate. Exported diagnostics record sharing start/stop,
authorization/accuracy mode, fix age and accuracy, first successful presence
commit, and failed presence writes without recording coordinates or account IDs.

---

## Realtime and polling fallback

Realtime uses a private Realtime channel `group:{groupId}` with presence + broadcast (`location`, `alert`, `sharing_off`).

The app subscribes to the tracked group's private channel for low-latency validated location, alert, and sharing-off events. It persists `rider_presence` every 10s during ordinary sharing and every 5s during distress, then polls the database every **5s while that group's detail is open**, or every 30s when Realtime is connected (10s when it is down) after detail closes, so a missed broadcast is eventually corrected. Request generations prevent old group/list responses from overwriting a newer selection.

Location broadcasts and database rows pass the same validity checks. The app never publishes `(0,0)`, never treats a missing timestamp as live, and does not route to a stale member.

Planner pins and group pins have separate generations. Group movement updates only the rider annotation and does not rebuild or disturb route/fuel pins.

### Stop-trigger tracking rules

1. Navigate paints the route to the member's validated last-known position.
2. While the following rider is moving, member movement updates only the target pin.
3. A stop begins only from an accurate location reading at or below 0.8 m/s and must hold for 8 seconds.
4. If the member moved at least 100m and is still live, rebuild from the follower's stopped position.
5. If the follower moves before completion, cancel and discard the result.
6. If automatic fuel stops are present, do not silently remove them; ask the rider to review the route.
7. If sharing ends or refresh fails, keep the existing route and clearly label it as the last-known destination.

---

## What’s next

| Priority | Work |
| --- | --- |
| Release | `create_group` is deployed and metadata-verified; finish multi-account production RLS/private Realtime tests |
| Release | Add the moderation, report, and block workflow required before Groups is public |
| Low | Push, historical alert UI, and Live Activity hooks for peer alerts ([07-FUTURE.md](./07-FUTURE.md)) |

## Launch security boundary

The client is not proof that Supabase Row Level Security is correct. The live
schema, functions, grants, policies, and private Realtime authorization must be
exported, reviewed, and tested before release. The versioned verification matrix
and account-deletion migration live in [`../supabase/README.md`](../supabase/README.md).

Distress scope is deliberately narrow: the database row and Realtime broadcast
use the same single target group. Membership in another connected group is not
permission to copy an alert into that group's channel.

---

## Starting a new agent on this area

1. Read `GroupsViewModel.swift` end-to-end, then `GroupsSheet.swift`.
2. Confirm table/RPC names against the iOS docs §4 — do not invent columns.
3. Check how rider markers are isolated from planner markers (`setGroupMarkers` / `setPlannerMarkers`).
4. **Invariants:** groups require a signed-in session; invite codes stay 6-char lowercase alnum; live window is 120s; only fresh accurate local fixes publish; moving riders never receive a group-target reroute; do not break the `rider_presence` row shape.
5. **Release dependency:** `create_group` is deployed; prove it with disposable multi-account tests. The client no longer performs two independent writes.
