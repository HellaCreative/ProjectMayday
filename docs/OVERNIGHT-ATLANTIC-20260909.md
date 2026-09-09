# DIRT overnight routing handoff — September 9, 2026

Final report for the completed overnight automated sweep. Overnight automation is paused. Automated results are not physical-device acceptance.

## Ready on DEV

The live DEV service is source `f2da612ae73dd175123430391010b48f0d9408a7`, with both NS/NB release02. No app reinstall or pack download is required. Saved routes retain their geometry; fresh routes exercise the changes.

- Coarse waypoint routing searches a wider area for eligible roads. A further fix recovers a connected start road when nearby isolated fragments crowd the initial choices. Two real cases now recover roads500m and3.2km away, inside their allowed snap limits.
- A bounded continuation-search retry recovers a previously failing reversed multi-waypoint route.
- Earlier fuel-repeat fixes and startup performance improvements remain included. Six established long-route baselines retain exactly the same geometry and fuel-stop identities.

The latest snapping change passed219 local checks and30 private/public hosted checks. Later stress tests added both-direction short loops and smaller-range NB cases. Successful completion and good route shape are recorded separately.

## Still open

- Some large loops fail the fuel-search state limit. A central NS return leg fails at180km and225km usable range; the previous DEV version also fails it. A fresh reverse Inverness case remains open. Experiments that failed to help were reverted.
- Individual legs can be free of internal repeats while overlapping earlier legs. One new example shares153km across its first two legs. The app supplies only recent road history, so the service cannot reliably avoid every earlier road.
- Rider waypoints can produce a junction turnaround: new examples have734m and3.0km returns. These are distinct from fuel detours. Immediate pin snapping, persistent per-pin precision and turnaround behavior need app/contract follow-up.
- A120km usable-range Clean case retains6.9km of repeated road around fuel. At225km the same first leg has no stop or repeat. Excluding its chosen pump made the repeat worse; a cleaner alternative is not yet proved.
- The hardest cold Clean request still has narrow headroom under its20-second budget. Mapped fuel access remains provisional.

## Morning physical check

Use a fresh online route with your usual250km range and10% reserve. First try coarse pin placement and your accepted multi-waypoint loop. Inspect waypoint departures, fuel approaches and overlap with earlier legs. No further physical testing was required overnight.

Live JavaScript only: native app, production and GitHub push were not changed. Last qualified DEV and its rollback are preserved. Detailed evidence and exact fixtures are in `ROUTING-REBUILD-PROGRESS.md` and `scripts/pack-fabric/bench/fixtures`.
