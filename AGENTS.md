# DIRT — start here

DIRT's app, supporting services, and pack tools belong to this repository. Open
`Dirt.xcodeproj` from the checkout assigned to the current task. Preserve existing
work and confirm the checkout and branch before editing; do not reset or switch
to an older checkpoint merely because an old report names it.

## Routing authority

[docs/ROUTING-SOURCE-OF-TRUTH.md](docs/ROUTING-SOURCE-OF-TRUTH.md) is the sole
authority for routing, fuel, graph/pack contracts, source selection, active routing
workspaces, execution limits, routing acceptance, and routing release boundaries.
Read it before routing work. Component indexes, benchmark output, old worktrees,
and Git history do not provide additional routing instructions.

## Simulator storage policy

- Reuse one existing simulator. Do not create or clone additional simulators,
  boot additional devices concurrently, or enable parallel simulator testing
  without Richard's explicit authorization. A general request to build or test
  does not authorize extra simulators. If no suitable device exists, ask first.
- Keep both DIRT Dev test targets non-parallel. For simulator `xcodebuild`
  test runs, specify one existing destination by UDID and pass
  `-parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1`.
  Do not override this policy for faster testing without authorization.
- Before any authorized temporary simulator creation or clone-producing run,
  record existing device IDs in both the normal CoreSimulator set and
  `~/Library/Developer/XCTestDevices`; track the exact devices owned by the run.
  Arrange cleanup before starting, including failed and cancelled runs.
- After use, shut down and delete only the temporary simulators/clones created
  by that run using `simctl` with the correct device set. Verify removal before
  reporting completion. If cleanup is interrupted, finish it at the next
  opportunity and disclose leftovers. Do not delete pre-existing devices, their
  data, or another task's devices; never use blanket `delete all`. Shut down a
  reused device only if this task booted it and it is no longer in use.

## General safeguards

- Follow current owner authorization for device and external actions. Never
  bypass a locked Mac or expose credentials in source, logs, or mobile bundles.
- Keep development and production data isolated. Use synthetic accounts for
  testing. See [environment and release guidance](docs/ENVIRONMENTS-AND-RELEASES.md).
- Preserve security, privacy, accessibility, and existing product functionality.
  Record what was actually verified; compilation and automated checks do not
  establish physical-device acceptance or a published release.

## Other product areas

- Navigation, cues, HUD, and in-ride interactions:
  [navigation authority](docs/00-NAVIGATION-SOURCE-OF-TRUTH.md).
- Non-routing Android requirements:
  [Android parity](docs/ANDROID-PARITY.md).
- Rider Services layers:
  [accepted Rider Services boundary](docs/RIDER-SERVICES-FREEZE-2026-09-05.md).
- Privacy: [application data map](docs/APP-PRIVACY-DATA-MAP.md).
- Public release: [App Store checklist](docs/APP-STORE-LAUNCH-CHECKLIST.md).
- Public website: [website copy handoff](docs/WEBSITE-LAUNCH-COPY-HANDOFF.md).

Read the relevant non-routing contract when working in those areas. Their
references to routing defer to the sole routing authority above.
