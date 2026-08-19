# DIRT iOS — Future & deferred work

Work explicitly out of v1 scope, plus a practical App Store path. Do not treat this list as committed roadmap — pick items when Rick prioritises them. Baseline gaps also listed in [../README_TESTFLIGHT.md](../README_TESTFLIGHT.md) and [00-OVERVIEW.md](./00-OVERVIEW.md).

---

## Audit hardening backlog (2026-07-27)

From the Codex iOS audit. **#2 stale routes** and **#5 failed-manifest retry** were implemented in-session; the rest stay here until prioritized.

| Priority | Item | Notes | Status |
| --- | --- | --- | --- |
| High | Stale on-device routing responses can overwrite newer intent | Request generation + stage-id apply; ignore mismatched replies | **Done** |
| High | Failed POI / network manifest `Task` sticks for the session | Clear task on failure so a later refresh retries | **Done** |
| High | Release builds include tester auth + subscription bypass | `BuildChannel.allowPreReleaseTesterUnlock` — intentional for TestFlight; set `false` (or Store-only config) before public App Store freeze | Open |
| High | Live sharing can publish `(0,0)` before GPS is ready | `GroupsViewModel.publishPresence` — wait for a valid fix; don’t write Gulf-of-Guinea junk | Open |
| High | Gzip decode uses a fixed 8× output ceiling | `Data.gunzipped()` — grow buffer / stream; current packs may be fine until blank provinces appear | Open |
| Medium | `IPHONEOS_DEPLOYMENT_TARGET = 26.5` | Likely Xcode default inheritance — lower to the real minimum OS before store if reach matters | Open |
| Medium | Inconsistent HTTP response validation | Shared client: require `200..<300`, size limits, better diagnostics for R2 manifests / Overpass / pack chunks | Open |
| Medium | Thin tests around critical state machines | Highest ROI: stale-route ordering, stage delete during route, presence coords, manifest retry, StoreKit/trial transitions | Open |
| Low | `GPXParser` unused `var track` | Change to `let` | Open |

---

## Near-term product gaps (still “app” scope)

| Item | Today | Direction |
| --- | --- | --- |
| POI / Rider Services overlays | Overpass + fuel filter | Keep respecting `@AppStorage` prefs; existence confirmation later |
| NSTDB / provincial road overlays | Toggles only | Same — MapLibre sources/layers per installed province pack |
| Supabase Realtime | `rider_presence` poll 10s | Private `group:{id}` channel + broadcast ([03-GROUPS.md](./03-GROUPS.md)) |
| Shared incidents | Local HUD toast | `rider_alerts` insert + peer display; optional `avoidEdgeIds` recalculate |
| Corridor offline tiles | BBox pyramid z8–14 | True corridor / budgeted tile set closer to a true corridor |
| GPX import | Export only | GPX import |

---

## Platform features (deferred)

| Feature | Notes |
| --- | --- |
| **Live Activities** | Nav ETA / next cue on Lock Screen Dynamic Island — natural fit once TBT is stable |
| **Apple Watch** | Glanceable cue + distance; complication later |
| **CarPlay** | Navigation app entitlement + map template — significant certification work |
| **Voice (AVSpeech)** | Cue audio toggle ships with the map stack (`dirt_cue_audio_v1`); refine phrasing / ducking later |
| **Haptics** | Turn proximity / off-route pulses |
| **Background audio session** | Only if voice ships |

None of these exist in the current target capabilities beyond location background mode.

---

## On-device routing

Shipped. `GraphPackStore` + `OnDeviceRouter` on R2 `graph.v2` packs. Costing must stay in lockstep with `pack-fabric/routing/lib/profile-costs.js`.

---

## Packs / performance (later)

Pack streaming lives in **this** repo: `scripts/pack-fabric/` → R2. Locked laws: [08-MAP-REFINEMENT.md](./08-MAP-REFINEMENT.md). Two adjacent installed packs already chain on-device.

---

## App Store submission checklist

Operational path also in [../README_TESTFLIGHT.md](../README_TESTFLIGHT.md).

| Step | Status / action |
| --- | --- |
| ASC app record `com.mayday.dirt` + SKU `MAYDAY-DIRT-IOS-001` | Confirm in ASC |
| Agreements / tax / banking for team `34XM6B4G7A` | Rick |
| Distribution cert + App Store profile | Create via Xcode Organizer Distribute (automatic signing) |
| Export IPA from `build/Dirt.xcarchive` | Blocked until profile exists |
| Upload TestFlight | Organizer or ASC API key (`~/.appstoreconnect/private_keys`) |
| Privacy nutrition labels | Location (precise), possibly tracking=no; match actual SDKs (MapLibre tiles, Supabase) |
| Privacy policy URL | Needed for submission — confirm hosting |
| Export compliance / encryption | Standard HTTPS — answer questionnaire |
| Screenshots | iPhone sizes for Navigation category |
| Review notes | Explain dual-sport routing; demo account if OTP email is awkward for review |
| Age rating / category | Navigation already set on target |

**Do not** claim Watch/CarPlay/Live Activities in review notes until they ship.

---

## Suggested order (opinionated, not locked)

1. Unblock TestFlight (signing + upload).
2. Realtime groups **or** overlay streams (pick by field-test pain).
3. Corridor offline tiles.
4. Shared incidents + avoid-edge.
5. Voice / haptics.
6. Live Activities → Watch → CarPlay.

---

## Explicit non-goals (unless Rick reopens)

| Non-goal | Why |
| --- | --- |
| Non-native map shell | Locked native SwiftUI + MapLibre ([00-OVERVIEW.md](./00-OVERVIEW.md)) |
| Staging backend | Production hosts only |
| Replacing MapLibre with Apple MapKit | Shortbread + overlay model is the product map |
| Inventing features from ChatGPT outlines | Outlines are reference-only; code in this repo wins |
| Shipping CarPlay in the first store binary | Entitlements and review cost outweigh v1 learning |

---

## Starting a new agent on this area

1. Read [../AGENTS.md](../AGENTS.md) then [00-OVERVIEW.md](./00-OVERVIEW.md). Work only in this iOS repo.
2. Confirm the feature is absent in code (search `Dirt/`) — do not re-document invented work as done.
3. For overlays/realtime/incidents, read the iOS code in `Dirt/`.
4. **Invariants:** native SwiftUI only; no second backend; Clean⊥Allow; green CTA law.
5. **Open questions:** Rick’s priority between realtime vs overlays; ASC privacy policy URL; whether Live Activities are wanted before public TestFlight.
