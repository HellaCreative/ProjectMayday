# BC–Washington live memory repair

Richard requested BC–Washington repair first, with one hosted request at a time and no simulator launches.

The custom ride settings rejection is separate: live-canary explicitly supports ridePreferences only in NS/NB. Do not silently ignore requested preferences or claim national support as part of this fix.

Default BC–Washington requests previously failed HTTP500 from Vercel memory exhaustion. A local sequential loader reproduction confirms the spatial snap grid expands long ferry bounding rectangles into millions of cells. One geometry alone spans3,486,092cells in both packs. BC loaded at1,148,387,328RSS bytes; addingWA exhausted a1200MiB JavaScript heap.

Commit29a05c keeps rectangles spanning more than256cells once and merges their indexes on each queried cell. The returned candidate set AND edge order match the previous grid, including interior rectangle cells; no roads, ferries, costs, legal rules or pack files change. All known production consumers use get(cell). Tests compare every cell across overlapping broad/ordinary bounds and cover a continental rectangle.

With the same source packs and process limit, BC+WA loaded together at688,586,752RSS bytes.209 local tests pass. Private preview1kc9294gb uses the unchanged national candidate09 environment; hosted forward/reverse checks are in progress, and no repair alias change has occurred yet.

Evidence: candidate09/bc-wa-repair; user-facing settings limitation remains outside this storage-only repair.


Published to stable DEV at2026-09-09T16:07:06.608688+00:00. Hosted BC→WA completed87,013m in25.2seconds includingCLI; WA→BC completed87,990m in16.1seconds. Actual published pack identities verified in both results. Three accepted Inverness baseline legs retain exact route geometry and fuel-stop IDs. Stable health confirms29a05c. No physical-device acceptance claimed; custom ride settings remain NS/NB-only. Other memory/timeout reports not retested.
