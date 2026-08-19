# DIRT iOS — Groups

Group ride list/detail, invite codes, presence sharing, and map roster. Spec: the iOS docs §4. Auth prerequisite: [04-PROFILES-AUTH.md](./04-PROFILES-AUTH.md).

---

## Key files

| File | Role |
| --- | --- |
| `Dirt/Features/Groups/GroupsViewModel.swift` | Data + presence + polling |
| `Dirt/Features/Groups/GroupsSheet.swift` | List / detail UI |
| `Dirt/Persistence/SupabaseService.swift` | Client + session |
| `Dirt/Map/MapState.swift` | Rider markers (kind `.rider`) |

---

## Supabase surfaces used

### Tables

| Table | iOS usage |
| --- | --- |
| `group_members` | List memberships (`role` + nested `groups`); member roster with `profiles(display_name)` |
| `groups` | Create `{ name, owner_id }`; soft-delete via RPC (`deleted_at` filtered client-side) |
| `rider_presence` | Upsert while sharing; select for live counts + map pins |
| `profiles` | Nested select for display names (writes happen in auth/profile flow) |

**Not used on iOS yet:** `rider_alerts` (table exists; Report does not insert).

### RPCs

| RPC | Args | When |
| --- | --- | --- |
| `join_group_by_invite_code` | `p_invite_code` | Join |
| `leave_group` | `p_group_id` | Non-owner leave |
| `delete_group` | `p_group_id` | Owner soft-delete |

### Invite codes

Client validates `^[a-z0-9]{6}$` (trimmed, lowercased) before RPC.

### Live heuristic

List path:

- `sharing_enabled == true`
- valid presence row
- `last_seen_at` within **120s**, **or** null/`parse` failure treated as live (`PresenceRow.isLive`)

ISO8601 parsing accepts fractional seconds (`ISO8601DateFormatterBox`).

---

## Features implemented

| Feature | Behaviour |
| --- | --- |
| Auth gate | Sheet shows sign-in prompt if `!supabase.isSignedIn` |
| List | Name · member count · live count; pull-to-refresh |
| Create | Insert group + owner `group_members` row (`role: owner`) |
| Join | Invite code → RPC → refresh |
| Detail | Invite code + copy; sharing controls; roster; leave/delete |
| Start sharing | `requestAlways` + background location; upsert every **5s** |
| Stop sharing | Upsert `sharing_enabled: false`, `status: offline` |
| Status while sharing | `available` \| `breakdown` \| `injured` \| `stuck` (picker) |
| Roster poll | While detail open, refresh members + presence every **10s** |
| Map pins | Live peers (not self): status-colored dot + **name/status chip**; pins keep updating after sheet close while that group is tracked |
| Focus peer | Scope button flies map to peer, closes sheet |
| Route to member | Sheet **or tap peer pin on map** → `planner.routeToMember` → From here to peer coords; toast |
| Close sheet | `onDisappear` → `closeDetail()` (reset to list) |

Presence upsert payload fields: `user_id`, `sharing_enabled`, `status`, `latitude`, `longitude`, `heading`, `speed_mps`, `accuracy_m`, `last_seen_at`.

---

## Polling vs realtime (important gap)

Realtime uses a private Realtime channel `group:{groupId}` with presence + broadcast (`location`, `alert`, `sharing_off`).

**iOS v1 does not subscribe to Realtime.** It:

1. Writes the same `rider_presence` rows.
2. Polls that table on a 10s timer while a group detail is open.
3. Publishes location on a 5s timer while sharing.

Cross-client interoperability with another client works for **persisted** presence (list counts, pins, route-to-member). Latency and leave detection are coarser than Realtime. Broadcast alerts are absent.

Comment in code (`GroupsViewModel`): intentional v1 choice, documented in README.

---

## What’s next

| Priority | Work |
| --- | --- |
| High | Supabase Realtime channel parity (presence + location broadcast) |
| Medium | Insert / display `rider_alerts`; wire HUD Report |
| Medium | Stop sharing when leaving detail / signing out (verify edge cases) |
| Low | Push / Live Activity hooks for peer alerts ([07-FUTURE.md](./07-FUTURE.md)) |

---

## Starting a new agent on this area

1. Read `GroupsViewModel.swift` end-to-end, then `GroupsSheet.swift`.
2. Confirm table/RPC names against the iOS docs §4 — do not invent columns.
3. Check how rider markers merge with planner markers (`paintLiveRiders` / `refreshMap`).
4. **Invariants:** groups require signed-in session; invite codes stay 6-char lowercase alnum; live window 120s; closing sheet resets detail; do not break the `rider_presence` row shape.
5. **Open questions:** Realtime before or after POI overlays?; should sharing continue with sheet closed (today share task is independent of detail poll, but UX may want an always-on share indicator on the dock).
