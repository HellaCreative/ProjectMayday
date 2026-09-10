# Regional fuel completion repair — September 10

Owner logs 200948Z and 201432Z, app 2 (34), range 420 km / 10% reserve:
378 km usable. Existing pack release is unchanged.

Failures include an all-alternatives completion gate rejecting valid Dirt
candidates when the paved search hits its label cap; a no-repeat-only fast
path rejecting legal Clean roads; and a far-north Quebec route that fails a
directed fuel connectivity relaxation at 378 km. The same far-north route
completes with four stops at a diagnostic 600 km usable range. That does not
change app settings or certify real-world station availability.

Three DEV-only controls: DIRT_FUEL_COMPLETION_POLICY=feasible-v1,
DIRT_PASSING_REFILL_ADVISORY=candidate-v1,
DIRT_FUEL_CONNECTIVITY_PROBE=candidate-v1. NS/NB-only scope is preserved.
Removed an experimental extra label-limit retry: it consumed work without
repairing these tests. Fixed-road refills keep turn history, reserve and
legal destination escape. The incomplete alternative comparison is disclosed.

Private evidence and full window-by-window replays are under the root Dirt
.build/fuel-health-evidence directory. Publication status is recorded there
and in the launch preparation log. Production and physical-device acceptance
remain separate. No map pack regeneration or Xcode build is required for DEV
clients to use a published server correction.
