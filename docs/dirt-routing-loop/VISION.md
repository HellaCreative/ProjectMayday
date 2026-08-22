# Dirt vision (routing) — frozen unless GATE + human

Dirt is dual-sport routing: **phone packs and live `/api/route` are the same graph bytes** (R2). Delivery differs (download vs cellular), not the road network.

## Profiles (must stay distinct)

| Profile | Intent |
| --- | --- |
| **dirt** | Maximize usable dirt/resource; fuel-on must still feel like Dirt, not Balanced |
| **balanced** | ~half dirt / half paved (bench band 45–55% dirt) |
| **direct** | Prefer short; stay within shortest+15 km |
| **clean** | Minimize dirt (≤15% dirt on bench) |

**Allow unknown** is explicit: unknown surface/access only when the rider turns it on.

## Fuel

Tank planning uses usable range (~237.5 km). Fuel-on routes must respect hop limits. Stations come from packed `fuel.v1.json` / live fuel API — same fabric.

## Ship rule

If we change a pack, it goes to R2 or we did not test it. Live must not point at longhaul extracts. Canada packs are promoted stable; US packs are live-candidates until physical OK + promote.

## Success for this loop

NS bench green count climbs and **stays** up. Previously green cases must not flip red for a “fix” elsewhere. Physical routes on live feel like the profile name.
