# Optional ride settings — September 9

User scope: Loop closes the current plan to its start; ride wander slider and avoid cities/towns and highways switches beside fuel; installed pack Update/Delete.

The optional `options.ridePreferences` object contains `wander` (0…1), `avoidCities` and `avoidHighways` (booleans). Requests without this object retain accepted behavior. Wander narrows the proven candidate pool by distance before applying the selected surface preference, within minimum avoidance exposure. At 1 the accepted pool remains available. Choices cannot bypass access or fuel constraints. City/highway avoidance minimizes exposure while retaining required connections; highway avoidance includes motorway/trunk/primary and their links.

Current qualification boundary: NS/NB live canary. Explicit custom requests outside the supported flow return an unavailable result rather than silently ignoring settings. Offline customization remains unimplemented and must be surfaced honestly; existing default/offline navigation is unchanged. No production qualification is claimed.

202 local adventure tests passed, including actual route changes for both switches, optional payload validation, and default-pool preservation. Hosted checks pending.
