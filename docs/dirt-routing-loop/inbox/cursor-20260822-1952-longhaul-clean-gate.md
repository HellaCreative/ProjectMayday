# Cursor build — 2026-08-22 19:52 ADT — Clean-sections longhaul gate

**Shipped.** One condition. No fuel-station placement, per-leg identity, packs,
manifest, or deploy.

## Where the trigger actually lives

Device log `fuel longhaul default requested=dirt sections=clean reason=fuel_stop_required`
is emitted by **Dirt** (`feature/routing-itinerary-rebuild`), not this pack-rebuild
worktree. Pack-rebuild has no Clean-sections default.

File: `/Users/richardsmith/SandBox01/MAYDAYiOS/Dirt/Dirt/Features/RoutePlanning/Itinerary/ItineraryBuilder.swift`

## Exact change

**1. Pre-route Clean foundation** (was also treating “longer than one tank” as long-haul)

Old (~L86–90):

```
fuel.usableMeters > 0 && (
    straightMeters > fuel.usableMeters
        || straightMeters >= 1_000_000
        || endpointRegions.count > 1
)
```

New (L86–89):

```
fuel.usableMeters > 0 && (
    straightMeters >= 1_000_000
        || endpointRegions.count > 1
)
```

**2. Post-discovery force-Clean** (this is the `reason=fuel_stop_required` path)

Old (~L114):

```
if fuel.usableMeters > 0, discoveredStops > 0, discoveryProfile != .cleanest
```

New (L113–115):

```
if fuel.usableMeters > 0,
   (straightMeters >= 1_000_000 || discoveredStops > 3),
   discoveryProfile != .cleanest
```

A 319 km Dirt From Here with one pump: not ≥1000 km, not >3 pumps → requested
profile is kept. Clean-sections still applies for ≥1000 km, >3 pumps, or
cross-region.

## Build

`xcodebuild build -project Dirt.xcodeproj -scheme Dirt` (iPhone 17 sim) from
`/Users/richardsmith/SandBox01/MAYDAYiOS/Dirt` — **BUILD SUCCEEDED**.

NS bench not run. 41/65 stands.

## Next agent: Claude

Rick physically tests a ~319 km Dirt From Here with one fuel stop. Dirt must
stay Dirt. No Codex this turn.
