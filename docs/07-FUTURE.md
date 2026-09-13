# DIRT iOS — Future & deferred work

Work explicitly out of v1 scope, plus a practical App Store path. Do not treat this list as committed roadmap — pick items when Rick prioritises them. Baseline gaps also listed in [../README_TESTFLIGHT.md](../README_TESTFLIGHT.md) and [00-OVERVIEW.md](./00-OVERVIEW.md).

---

## Audit hardening backlog (2026-07-27)

This dated list records non-routing audit items. Confirm their current status
before acting. Routing fixes, pack work, and their qualification are tracked
only in [the routing source of truth](ROUTING-SOURCE-OF-TRUTH.md).

| Priority | Item | Notes | Status |
| --- | --- | --- | --- |
| High | Failed POI / network manifest `Task` sticks for the session | Clear task on failure so a later refresh retries | **Done** |
| High | Release builds include tester auth + subscription bypass | Debug or an explicit `DIRT_PRE_RELEASE_TESTER_UNLOCK` compilation condition only; public Release scrubs persisted bypass values | **Done** |
| High | Live sharing can publish `(0,0)` before GPS is ready | Wait for a fresh, accurate fix; reject sentinel coordinates locally and remotely | **Done** |
| Medium | `IPHONEOS_DEPLOYMENT_TARGET = 26.0` | Richard deliberately selected iOS 26.0 as the launch minimum; the Release verifier locks the archive metadata to that value | **Done** |
| Medium | Inconsistent HTTP response validation | Review response validation and diagnostics for non-routing network clients | Open |
| Medium | Thin tests around critical state machines | Presence coordinates, non-routing manifest retry, and StoreKit/trial transitions | Open |
| Low | `GPXParser` unused `var track` | Change to `let` | Open |

---

## Near-term product gaps (still “app” scope)

| Item | Today | Direction |
| --- | --- | --- |
| POI / Rider Services overlays | Overpass + fuel filter | Keep respecting `@AppStorage` prefs; existence confirmation later |
| NSTDB / provincial road overlays | Toggles only | Same — MapLibre sources/layers per installed province pack |
| Supabase Realtime | Private `group:{id}` channel + 10s ordinary / 5s distress persisted presence | Push notifications / durable alert history ([03-GROUPS.md](./03-GROUPS.md)) |
| Shared incidents | `rider_alerts` + Realtime peer banner | Historical-alert UI; routing implications belong in [the routing source of truth](ROUTING-SOURCE-OF-TRUTH.md) |
| Corridor offline tiles | BBox pyramid z8–14 | True corridor / budgeted tile set closer to a true corridor |
| GPX import | Track/route import, traced display, local save, and continue-as-plan | Import interface work; any routing conversion belongs in [the routing source of truth](ROUTING-SOURCE-OF-TRUTH.md) |

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

## Routing work

Routing, fuel, pack delivery, performance, current work, and acceptance are defined
only in [the routing source of truth](ROUTING-SOURCE-OF-TRUTH.md). This future-work list does not
set a routing backlog, source policy, or implementation baseline.

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
2. Overlay streams.
3. Corridor offline tiles.
4. Shared-incident presentation.
5. Voice / haptics.
6. Live Activities → Watch → CarPlay.

---

## Explicit non-goals (unless Rick reopens)

| Non-goal | Why |
| --- | --- |
| Non-native map shell | Locked native SwiftUI + MapLibre ([00-OVERVIEW.md](./00-OVERVIEW.md)) |
| Replacing MapLibre with Apple MapKit | Shortbread + overlay model is the product map |
| Inventing features from ChatGPT outlines | Outlines are reference-only; code in this repo wins |
| Shipping CarPlay in the first store binary | Entitlements and review cost outweigh v1 learning |

---

## Starting a new agent on this area

1. Read [../AGENTS.md](../AGENTS.md) then [00-OVERVIEW.md](./00-OVERVIEW.md). Work only in this iOS repo.
2. Confirm the feature is absent in code (search `Dirt/`) — do not re-document invented work as done.
3. For overlays/realtime/incidents, read the iOS code in `Dirt/`.
4. Preserve the current native interface and development/production isolation.
   Routing decisions are defined only in [the routing source of truth](ROUTING-SOURCE-OF-TRUTH.md).
5. **Open questions:** Rick’s priority between realtime vs overlays; ASC privacy policy URL; whether Live Activities are wanted before public TestFlight.
