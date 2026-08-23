# Phase 0 — Fuel-stage mutation inventory

> **DECOMMISSIONED:** Historical evidence only. Current authority:
> [`00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md`](../../../00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md).

This phase instruments the mutable `Stage` representation without changing its
behaviour. The device reproduction log will identify which mutation path loses
the fuel-end flag before the canonical itinerary replaces this representation.

## `endsAtFuelStop` writes

| File:line | Write | Can demote a fuel stage? |
| --- | --- | --- |
| `Dirt/Features/RoutePlanning/RoutePlannerModel.swift:36` | Default value on a newly constructed `Stage`. | Yes, if a fuel stage is reconstructed without subsequently setting the flag. |
| `Dirt/Features/RoutePlanning/RoutePlannerModel.swift:52` | The instrumented `setEndsAtFuelStop` storage write. | Yes; every explicit write now passes through this logger. |
| `Dirt/Features/RoutePlanning/RoutePlannerModel.swift:2769` | `expandStageIntoFuelItinerary` marks every intermediate generated hop as fuel-ending. | No in its intended loop bounds; the final hop is deliberately non-fuel. |
| `Dirt/Features/RoutePlanning/RoutePlannerModel.swift:2879` | `buildLiveFuelChain` marks hops before the rider destination as fuel-ending. | No in its intended loop bounds; the final hop is deliberately non-fuel. |
| `Dirt/Features/RoutePlanning/RoutePlannerModel.swift:2964` | `splitStage` assigns the first half from `viaIsFuel`. | **Yes.** The default `viaIsFuel = false` demotes the inserted first half unless every fuel split passes `true`. |
| `Dirt/Features/RoutePlanning/RoutePlannerModel.swift:2971` | `splitStage` copies the original flag to the second half. | No when the original is intact; yes indirectly if the original was already demoted. |

## `fuelStopID` writes

| File:line | Write | Can demote a fuel stage? |
| --- | --- | --- |
| `Dirt/Features/RoutePlanning/RoutePlannerModel.swift:38` | Optional default on a newly constructed `Stage`. | It cannot flip the Boolean, but a reconstructed stage can lose station identity. |
| `Dirt/Features/RoutePlanning/RoutePlannerModel.swift:2779` | Assigns the matching packed station while expanding a fuel itinerary. | No; adds identity only. |
| `Dirt/Features/RoutePlanning/RoutePlannerModel.swift:2884` | Assigns the chosen live fuel-chain station. | No; adds identity only. |
| `Dirt/Features/RoutePlanning/RoutePlannerModel.swift:2972` | Copies station identity to the second split half. | No direct flag change; can attach the station to the wrong half if split semantics are wrong. |

## `fuelGroupID` writes

| File:line | Write | Can demote a fuel stage? |
| --- | --- | --- |
| `Dirt/Features/RoutePlanning/RoutePlannerModel.swift:42` | Optional default on a newly constructed `Stage`. | It cannot flip the Boolean, but losing the group makes later code treat the hop as a primary rider leg. |
| `Dirt/Features/RoutePlanning/RoutePlannerModel.swift:2770` | Assigns one group to expanded itinerary hops. | No; establishes derived-hop membership. |
| `Dirt/Features/RoutePlanning/RoutePlannerModel.swift:2880` | Assigns one group to live fuel-chain hops. | No; establishes derived-hop membership. |
| `Dirt/Features/RoutePlanning/RoutePlannerModel.swift:2965` | Copies the group to the first split half. | No direct demotion. |
| `Dirt/Features/RoutePlanning/RoutePlannerModel.swift:2974` | Copies the group to the second split half. | No direct demotion. |

## Leading hypotheses before device evidence

1. `splitStage(at:via:viaIsFuel:)` is the only explicit path able to turn a
   fuel-ending stage into a non-fuel-ending stage through its default argument.
2. Any code that reconstructs `Stage` via its memberwise initializer can silently
   inherit the default `endsAtFuelStop = false`, even without an explicit assignment.
3. Losing `fuelGroupID` does not directly flip the flag, but it changes collapse,
   editing, and continuity behaviour enough to make a derived hop behave like a
   rider-created leg.

## Device evidence

The fuel-before-waypoint decision is always false on rebuild:
`rebuildPrimaryPlanThenFuelAssist` reads `nextPrimaryMeters` from
`stages[i+1].response?.distanceMeters` after it has just set every `response = nil`.

Long-press on the route bypasses `handleTap` and appends a waypoint instead of
inserting: no `map tap result=` line fired and a third pin was appended.
