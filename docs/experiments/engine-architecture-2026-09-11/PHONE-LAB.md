# Physical phone regional routing experiment

White, the owner's **iPhone 16 (iPhone17,3), iOS 26.6.2 / 23G90**, completed two
six-check runs on September 11, 2026. The owner explicitly authorized installation
and testing on White after correcting the originally stated iPhone 17. RED was
not operated. The iPhone 17 simulator was used only for functional development.

This demonstrates a bounded **regional, fuel-off native capability on real phone
hardware**. It does not qualify the complete DIRT app, fuel planning, multiple
regions, continental routing or a general device resource threshold. The isolated
policy still has no production-qualified phone record. GraphHopper–DIRT remains
the controlled server implementation; there is no automatic server escalation.

## What ran

The separate `DIRT Phone Lab` app bundles the unchanged NS graph and geometry
bytes used by the hybrid experiment. It builds from the pinned `native-v6-cancel`
Swift snapshot, including its private cooperative cancellation hooks. It does not
embed GraphHopper or replace the installed DIRT app. No main app source, published
pack, stable DEV, production, GitHub or Apple portal changed.

The same regional fixture was used for Clean, Dirt and Balanced, with additional
deliberate cancellation, time-budget interruption and recovery. Its route lengths
are about 188–202 km, not short urban hops. Allow Unknown was false, seed 1, fuel
off. No unsupported preferences, waypoints or arrival history were dropped.

The lab has one serial routing worker, a visible Stop action, latched cancellation,
memory-warning/background stop handlers, an independent 100 ms resource sampler,
and a 100 ms main-thread heartbeat. Incomplete work cannot replace the last
completed candidate. The saved candidate still requires the independent source
audit; the UI does not present it as a certified fuel itinerary.

Experiment triggers are 512 MiB physical footprint, 384 MiB remaining dirty-memory
headroom, 1 GiB headroom before starting, 20 seconds per search and 90 seconds per
suite; serious/critical thermal state also stops work. These are conservative
**experimental triggers, not measured safe limits or hard allocation/deadline
guarantees**. Pack decoding and some preparation still cannot be interrupted
immediately. The small pinned NS pack bounds this first test; larger packs are
not admitted by implication.

## Physical results

| Measurement | Run 1 | Run 2 |
| --- | ---: | ---: |
| Entire six-check sequence | 13.974 s | 14.343 s |
| Pack validation, identity and decode | 0.0841 s | 0.0826 s |
| Clean baseline | 0.2127 s | 0.2129 s |
| Clean recovery | 0.1999 s | 0.2002 s |
| Dirt recovery | 3.9771 s | 4.0816 s |
| Balanced baseline | 9.1972 s | 9.4687 s |
| Sampled peak physical footprint | 201.860 MiB | 174.579 MiB |
| Sampled peak resident memory | 264.109 MiB | 296.563 MiB |
| Minimum available dirty-memory headroom | 3,174.140 MiB | 3,201.421 MiB |
| Largest main-thread heartbeat interval | 100.975 ms | 101.043 ms |
| Thermal state throughout | Nominal | Nominal |
| Reported battery level | 45% → 45% | 45% → 45% |

Physical footprint and resident memory are different OS measures and are reported
separately. Samples may miss brief allocation peaks. The heartbeat measures
main-thread scheduling, not frame rate or every touch interaction. Short runs and
coarse battery percentages do not establish battery drain or sustained thermal
capacity. The first run used a freshly launched process; the second reused it.
Neither run establishes storage-cold behavior. The harness decodes a fresh pack
for each suite, so the second run is not evidence of an implemented cross-request
graph/index cache.

Both deliberate 20 ms interruption cases returned **incomplete in approximately
100 ms**, about 80 ms after the scheduled cancellation/deadline. That is measured
preparation overshoot, not a 20 ms guarantee. The physical test did not induce
actual low memory, a memory warning, serious heat or OOM.

All **eight completed road results** (including repeated Clean recovery results)
match the earlier native baseline exactly: source legs, coordinates, distances
and known-dirt percentages. All eight pass the independent V4 direction, access,
continuous turn-history and distance audit. Clean is 194.532 km / 0% known dirt;
Dirt 202.314 km / 66%; Balanced 187.998 km / 54%. Explicit endpoint approach
geometry remains separately reported and unverified as an off-road approach.
No local fuel entrance, fuel chain or optimality claim follows from this audit.

The earlier Mac native searches were 0.366 s Clean, 5.623 s Dirt and 11.392 s
Balanced on this fixture. The phone observations are encouraging, but different
hardware, wrappers and sampling mean they are not a controlled engine speedup
comparison. The previously measured unmodified native cancellation tail was
5.525 s on the Mac; that baseline was not rerun unmodified on White.

## Review and functional verification

The simulator v3 suite returned four baseline-identical roads, all passing source
audits, plus two intended incomplete results. An injected memory-warning event
stopped the suite without publishing a new candidate and preserved the prior
candidate byte-for-byte. The visible Stop button stopped active Dirt work in
56 ms after the request. Run and Export were disabled during work, then restored.
Export opened the native share sheet with the correct JSONL evidence file.

The final timing/write-status update was exercised with the simulator v4 suite:
the same six outcomes, 22.250 s total. iOS v5 then adds the authorized launch
argument; both physical runs exercise that final app source. The earlier v2
compile failure was a Swift `try` placement error in the publication guard and
was fixed before any installation of that version.

UI review used the existing iPhone 17 simulator at 1206×2622, default text sizing,
dark appearance, native controls and accessibility labels. Ready, running,
incomplete, completed, disabled and export states were inspected. No clipping
or blocked primary action was found in that view. Screen text explicitly labels
road-only scope and incomplete outcomes. Larger accessibility text, landscape,
VoiceOver navigation, hardware keyboard use and physical-device visual/touch
acceptance are **not verified**. No accessibility conformance is claimed.

The lab is experiment tooling. It changes no accepted rider behavior or stored
app contract; therefore it has no Android product counterpart in this commit.
Any later integration still requires platform parity and full fuel/history rules.

## Candidate, evidence and recovery

Source: `scripts/routing-architecture/device-workload/phone/`.
Builds and full logs are under:
`/Users/richardsmith/.codex/experiments/routing-architecture-20260911/device-workload`.

- Final physical build: `phone-ios-v5`; signed copy: `phone-white-v5-signed`.
- Bundle: `local.dirt.experiments.phonelab20260911` (separate from DIRT).
- Manifest SHA-256: `2f0372d3351a4899f2d06a0214a4bf2cf272c8f028247f6b9c37a5fb5a719e4e`.
- Signed executable SHA-256: `3f23f66cc331fdd20e9f97ea7a053faf81bb870cf28bfc33d4db51d84992c54f`.
- Run logs: `white-run-1.jsonl`, `white-run-2.jsonl`, copied from owner exports.
- Summary/audit receipts: `white-run-{1,2}-summary.json` and
  `white-run-{1,2}-source-audit.json`.
- Portable comparison and identities: [phone-lab-evidence.json](phone-lab-evidence.json).
- Simulator evidence: `phone-sim-suite-v3.jsonl`, `phone-sim-suite-v4.jsonl`,
  `phone-sim-memory-warning-v3.jsonl`, `phone-sim-user-cancel-v3.jsonl`, screenshots
  `phone-sim-ready.png` and `phone-sim-export.png`.

`build-phone.py` verifies the pinned native snapshot and unchanged NS bytes,
creates a fresh bundle and preserves source/resource hashes. The device build
starts unsigned. `sign-phone.py` signs a fresh copy using an existing local
development profile after checking its allowed bundle, certificate and device.
It performs no portal, installation or launch operation. Never overwrite an
accepted build or use another phone without that device's authorization.

The authorized launcher argument is `--run-authorized-regional-suite`; opening
the app normally leaves a Run button. `summarize-phone.py` produces timing and
memory summaries; `audit-native-road.js` performs the independent source audit.
The app can export its local evidence without a server. Preserve logs before
uninstalling `DIRT Phone Lab`; its sandbox is separate from DIRT's.

The existing simulator was reused, its test evidence copied out, its private lab
app removed and the simulator shut down. No simulator clone was created. The
private lab remains on White for review; completed runs leave no routing worker
or sampler active. The two completed hardware runs are sufficient for this
bounded first check; repeated runs alone would not close the fuel/history or
multi-region integration gaps.
