# DIRT Mayday — Web POC → Native iOS Spec

Source of truth: production web POC at **https://dirt-mayday.vercel.app** (`app/index.html`, `api/route.js`, `api/supabase-config.js`, Supabase migrations). Do not invent staging; there is none.

---

## 1. Design tokens (live UI)

Final chrome lock in `app/index.html` (DIRT Enduro layer) overrides earlier CSS. Use these values:

| Token | Value | Role |
| --- | --- | --- |
| Brand orange | `#ff7a00` | Accent, dock active pill, primary CTAs (auth/groups), brand dot, selected route line |
| Orange hover / pressed | `#e56a00` / `#c25400` | Interactive states |
| Chrome black | `#16181c` | Dock shell, brand chip, Save route, active group-tab, Stop sharing |
| Chrome border | `rgba(255,255,255,0.12)` | Dock / brand outline |
| Ink / muted | `#16181c` / `#616872` | Body text / secondary |
| Sheet bg | `rgba(255,255,255,0.97)` / `#f1f2f4` | Sheets + page wash |
| **Start navigation (only)** | `#147a56` | Green exclusive to Start / End navigation CTAs — never auth/group primaries |
| Export GPX | `#616872` | Secondary route action |
| Danger | `#d83b42` | Errors / restricted |
| Dirt mix (UI stats) | `#3a9dff` | Dirt % text + stage mix bar |
| Paved mix (UI stats) | `#fdb003` | Paved % text + stage mix bar |
| Map surface overlays | access `#0a66c2`, gravel `#5d6874` / `#6b7280`, branches/track `#7c3aed`, paved `#303a45`, bridge `#16875f`, tunnel `#94572b`, restricted `#d22730` | Layers legend + NSTDB lines |

**Typography**
- UI: **Archivo** (web loads Google Fonts; iOS may substitute a close grotesque or bundle Archivo).
- Mono / metrics: **Martian Mono** (distance, %, invite codes, nav cue meta).
- Brand: `DIRT.` italic 900 + orange `.` · `MAYDAY` mono wide tracking.
- Density: dock labels ~9.5–10px; primary buttons ~10px / weight 800; sheet titles use headline weight.

**Dock active state:** orange fill `#ff7a00` + **1px white stroke** on the active `nav-btn`.

**Route CTA matrix:** Save = black · Export = gray · Start = green `#147a56`.

---

## 2. Bottom dock — Layers / Profile / Group / Route

Persistent black dock (`#16181c`, ~64px + safe area). Four equal tabs; **only one sheet/tool open at a time** (opening one closes the others).

| Tab | Opens | Behavior |
| --- | --- | --- |
| **Layers** | Legend sheet | Rider Services toggles (Fuel / Campgrounds / Lodging / Liquor) + nested Map Visibility (access, gravel, branches, bridge, tunnel, restricted). Outside tap / Escape / handle closes. Usable during navigation. |
| **Profile** | Account sheet | Signed out: email OTP. Signed in: display name, edit, sign out. |
| **Group** | Groups sheet | Requires auth. List → detail; create / join / share presence; route-to-member. Closing resets to list panel. |
| **Route** | Route finder card | Toggle: closed ↔ expanded. Modes: **From here** / **Plan a route** / **Saved**. Handle collapses/expands. Dock stays visible while planner is open. |

Active tab gets orange pill + white stroke (`aria-expanded` / body classes `legend-open` | `account-open` | `groups-open` | `planner-open`).

Locate / map chrome sits above the dock (`--p2-dock-h`).

---

## 3. Route API

**Base URL:** `https://dirt-mayday.vercel.app`  
**Endpoint:** `POST /api/route` (CORS `*`).  
**Health:** `GET /api/route` → `{ ok, service: "dirt-route", engine, note }`.

### Request

```json
{
  "profile": "balanced",
  "locations": [
    { "lat": 44.65, "lon": -63.57, "label": "A" },
    { "lat": 44.88, "lon": -63.20, "label": "B" }
  ],
  "vehicle": "dual-sport-motorcycle",
  "accessPolicy": {
    "motorizedPermissive": true,
    "motorizedUnknown": false
  }
}
```

| Field | Notes |
| --- | --- |
| `profile` | Required enum: `direct` \| `balanced` \| `dirt` \| `cleanest` (UI label **Clean** → `cleanest`). Default server-side if omitted: `balanced`. |
| `locations` | ≥2 points. Client always sends **exactly two** per request (A→B). Multi-stage Plan = one POST per stage. Use `lat`/`lon` (not lng). |
| `accessPolicy.motorizedPermissive` | Default `true` if omitted. |
| `accessPolicy.motorizedUnknown` | “Allow unknown access”. **Forced `false` for `cleanest`** even if UI toggle is on. |
| `options.matchLimitMeters` | Optional; server default 250 m (dense) or 500 m (longhaul/Vercel). Cap 750. Client usually omits. |
| `options.avoidEdgeIds` | Optional; incident recovery excludes edges server-side. |
| `options.corridorBufferMeters` | Optional graph load hint. |

Cross-province long hauls may run **canada-chain** hops server-side; client still sends one A/B pair.

### Success response (`status: "complete"`, HTTP 200)

Key fields the client uses:

| Field | Type | Notes |
| --- | --- | --- |
| `geometry` | `[lon, lat][]` | Polyline for map + nav |
| `distanceMeters` | number | |
| `estimatedMovingSeconds` / `estimatedElapsedSeconds` | number | ETA |
| `stats` | object | `pavedPercent`, `dirtPercent`, `gravelPercent`, `accessPercent`, `trackPercent`, `unknownAccessPercent`, … |
| `segments[]` | object | Per-edge: `edgeId`, `surfaceClass`, `accessClass`, `distanceMeters`, optional `geometry` |
| `maneuvers[]` | object | Turn cues along geometry |
| `accessPolicy` | echoed policy | |
| `warnings[]` | `{ code, message }` | e.g. `unknown_access_enabled`, `unknown_access_used`, `unavoidable_pavement` |
| `debug` | object | Match/engine/region (Debug sheet) |

Surface mix UI: **dirt** = adventure surfaces (gravel+access+resource+track+unknown+single); **paved** = paved % — colors `#3a9dff` / `#fdb003`, not brand orange.

### Errors

| HTTP | `status` | Typical `error` |
| --- | --- | --- |
| 400 | `error` | `invalid_profile`, `invalid_locations`, `match_limit_too_large`, `graph_load_failed`, … |
| 422 | `failed` | `match_failed`, `disconnected_components`, `no_route`, `chain_hop_failed` |
| 500/503 | `error` | `route_internal_error`, `graph_memory_pressure` |

Failed bodies should have empty `geometry` when incomplete. Always check `status === "complete"` before painting a route.

---

## 4. Supabase

### Config

`GET https://dirt-mayday.vercel.app/api/supabase-config` →  
`{ "url": "<SUPABASE_URL>", "publishableKey": "<anon/publishable>" }`  
(`Cache-Control: no-store`). iOS should fetch this (or bake the same project URL + publishable key).

Default project URL in repo: `https://iiiguqknqxoumlmppzfw.supabase.co`.

### Auth — email OTP

1. `signInWithOtp({ email, options: { shouldCreateUser: true, data: { display_name } } })`
2. UI: “Check your email” + code field; **60s resend cooldown**
3. `verifyOtp({ email, token, type: "email" })`
4. Persist session + auto-refresh (Supabase Swift client)
5. Profile: `auth.updateUser({ data: { display_name } })` then upsert `profiles` `{ id, display_name, updated_at }`
6. Sign out: `auth.signOut()`

Groups require a signed-in session.

### Tables (client usage)

| Table | Ops |
| --- | --- |
| `profiles` | upsert display name; selected via `group_members.profiles(display_name)` |
| `groups` | insert `{ name, owner_id }`; fields `id, name, owner_id, invite_code, created_at, deleted_at` |
| `group_members` | insert owner row; list by `user_id`; members by `group_id` |
| `rider_presence` | upsert on `user_id`; select for live map / list counts |
| `rider_alerts` | insert incident rows (`breakdown` \| `injured` \| `stuck`) |

**Invite codes:** 6 lowercase alphanumeric (`^[a-z0-9]{6}$`).

**Live rider heuristic:** `sharing_enabled === true` + valid lat/lon + `last_seen_at` within **120s** (or null last_seen treated as live in list path).

### RPCs

| RPC | Args |
| --- | --- |
| `join_group_by_invite_code` | `p_invite_code` |
| `delete_group` | `p_group_id` (owner soft-delete → `deleted_at`) |
| `leave_group` | `p_group_id` |

### Realtime (group ride)

Private channel `group:{groupId}` with presence key = `userId`.

| Event | Purpose |
| --- | --- |
| presence sync/join/leave | Roster |
| broadcast `location` | Peer GPS |
| broadcast `alert` | Rider alert |
| broadcast `sharing_off` | Peer stopped sharing |

Persist presence upsert:

```json
{
  "user_id": "<uuid>",
  "sharing_enabled": true,
  "status": "available",
  "latitude": 0,
  "longitude": 0,
  "heading": 0,
  "speed_mps": 0,
  "accuracy_m": 0,
  "last_seen_at": "<ISO8601>"
}
```

Statuses: `available` \| `breakdown` \| `injured` \| `stuck` \| `offline`.

---

## 5. Feature checklist (parity)

| Feature | Web behavior to match |
| --- | --- |
| **Map idle** | Shortbread basemap; NS overview center ≈ `[-63.0, 45.1]` zoom `7.25`; brand chip; dock; locate; optional Debug |
| **Layers** | Rider Services POIs + Map Visibility NSTDB overlays; prefs persist |
| **Auth** | Email OTP → code → profile |
| **Profile** | Display name edit, sign out |
| **Groups list** | Create / join / member+live counts |
| **Group detail** | Invite code, members, Start/Stop sharing, status, leave/delete |
| **Share** | Presence + realtime location while sharing |
| **From here** | GPS as A; tap map for B; profile + Allow unknown; route; ephemeral (clears when re-entering tab) |
| **Plan stages** | Multi-stage A→B hops; long-press add stage; per-stage profile; aggregate mix; Clear route clears plan only via explicit clear |
| **Saved** | Local store (web: Dexie `dirt_saved_routes_v1`); open / delete / import GPX |
| **Start nav** | Green CTA → TBT HUD, follow orange line, Report / End; prefetch offline tiles |
| **Offline tile session** | See §6 rules |
| **Route-to-member** | Needs self + peer locations; switches to From here with B = peer; toast named route |
| **Clear route** | Stops nav if active; clears A/B/active route; does **not** wipe offline cache by itself |
| **Debug** | Optional on iOS — copy recent `/api/route` attempts (web keeps last 25 in localStorage) |

Also ship: Save route (black), Export GPX (share sheet), Allow unknown ack dialog, incident report + avoid-edge recalculate (if targeting full parity).

---

## 6. Map style

| Item | Value |
| --- | --- |
| Engine (web) | MapLibre GL JS 4.7.1 → iOS: MapLibre Native |
| Style URL | `https://dirt-mayday.vercel.app/app/data/shortbread-style.json` (or bundle equivalent) |
| Style name | `SVWD03` |
| Vector tiles | `https://vector.openstreetmap.org/shortbread_v1/{z}/{x}/{y}.mvt` (z 0–14) |
| Sprite | `/app/data/shortbread/svwd03sprite` (resolve against production host when remote) |
| Attribution | © OpenStreetMap contributors |

Web applies `tuneShortbreadContrast()` after load (stronger water/forest/road colors). Overlay NSTDB/POI chunks are separate GeoJSON sources, not Shortbread.

**Selected route:** per-surface colours matching live web `route-network` (access `#0a66c2`, gravel `#5d6874`, track `#7c3aed`, paved `#ffb000`, connector `#d22730`). Brand orange is chrome/CTA/destination pin — not the route stroke. Stats mix `#3a9dff` / `#fdb003` stay UI-only.

### Offline tile session rules (nav corridor)

Cache identity: web `dirt-nav-basemap-v2`, max **~1200** tiles, concurrency 4.

1. Prefetch **only on Start Navigation** — not when From here / Plan merely completes.
2. Same session key → **keep** cache and top-up missing tiles.
3. Mid-trip recalculate → **keep** tiles; prefetch new corridor; do not clear.
4. **Clear** tiles only when Start Navigation begins on a **different route identity** (new destination / clear+new plan). Ending nav UI alone must **not** wipe the cache.

During nav, tile requests may be served from local cache with network fill-through.

---

## 7. iOS permissions (parity)

| Permission | Why |
| --- | --- |
| **Location When In Use** | From here A, locate, nav follow, route-to-member, presence publish |
| **Location Always / Background Modes · Location** | Live group sharing + turn-by-turn while screen locked (match “keep sharing while riding”) |
| **Motion / compass** (optional) | Heading if not using GPS course alone |
| **Network** | Route API, tiles, Supabase, POI/trail chunks |
| **Clipboard** | Invite code / Debug dump copy |
| **Speech** (optional) | Cue audio (`dirt_cue_audio_v1` on web) |
| **Photo Library / Files** | GPX import/export share sheet |

Privacy strings should name: map location, ride navigation, and optional live group sharing.

---

## 8. Quick integration constants

```
BASE = https://dirt-mayday.vercel.app
POST  {BASE}/api/route
GET   {BASE}/api/supabase-config
STYLE {BASE}/app/data/shortbread-style.json
TILES https://vector.openstreetmap.org/shortbread_v1/{z}/{x}/{y}.mvt
```

Profiles UI → API: Direct / Balanced / Dirt / Clean → `direct` / `balanced` / `dirt` / `cleanest`.
