# Route controls — September 9, 2026

Implemented: Loop appends the current plan’s first waypoint; full-screen ride settings beside fuel offer wander and city/highway avoidance; downloaded packs have Update and working Delete across cached revisions. Replacement packs are staged and verified before switching. Navigation protection is checked again after awaits before deleting or publishing a replacement.

Verification: 19 Swift tests passed in RidePreferencesTests and PackFirstRoutingTests, including Loop identity/rebuild boundary, optional payload isolation, old options decoding, and deletion of old/current NS revisions without deleting NB. Simulator settings layout checked in portrait and landscape, including cancelling edits. No physical-device installation or acceptance is claimed.

Backend work remains separately committed in routing-rebuild (513f014, 337020c). 202 adventure tests passed. Final isolated preview https://pack-fabric-qe2ckrazy-goricksmith-7678s-projects.vercel.app preserves default southwest NS route geometry and fuel stops exactly. Custom direct and exploring/highway-avoidance requests both complete. Custom settings are currently qualified only for live NS/NB; offline custom planning explicitly reports unavailable.

Release coordination remains open: the pack-owner task is uploading/verifying the national catalog. Do not update AppConfig catalog/seams or promote this preferences preview over that work. Combine the preference commits with its verified national candidate, repeat default and custom hosted checks, then update both catalog and seam paths and produce the DEV app. Current stable DEV and the phone have not received these controls yet.
