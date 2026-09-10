# White build 18: physical acceptance failed

Richard rejected DIRT Dev 2 (18) after the September 8 physical test. Do not treat the successful install, focused automated checks, or individual connected routes as routing qualification. No further device testing is requested pending a bounded diagnosis.

## Exact evidence

Source: `/Users/richardsmith/Downloads/dirt-app-debug-2026-09-08T104100Z.txt`, exported 10:41:00 UTC. Service identity 108d7b9145a3c1c7e7f9f99301dcc9b8fa1cb923; connection revision connections-v4-20260908-03; sealed road release fabric-v4-20260907-01. All tested routing selected LIVE with no installed road packs. The unfinished compass/path-history experiments were excluded from build 18.

- Richard reports very slow plotting, successful fuel insertion, approximately 5% Dirt in Cape Breton, an unnecessary ferry, and no visible effect from Allow Unknown. The log preserves exact Cape Breton endpoints 44.764800,-63.340267 to 46.971015,-60.472779. Initial fuel work ran 10:31:50–10:32:26 UTC across two windows. First window skipped full-route selection because destination distance exceeded remaining tank range; it performed 10 profile searches and timed out with a resumable pump prefix. The second performed seven profile searches. These are measured causes of work, not proof that they alone caused the poor dirt share.
- Allow Unknown was sent and echoed as 1 at 10:32:59 and 10:34:49. The toggle-to-service connection works for these requests. Whether access classification, eligibility, route ranking, or rebuild scope explains the unchanged result remains open. The log does not establish missing pack roads.
- Richard reports NS–NB connected but hugged paved coast; early legs approximately 30% and 23% Dirt; a Balanced selection reduced a visible leg from 30% to 24%; Clean remained too similar to Dirt. Exact journey endpoints: 44.764835,-63.340237 to 47.403738,-67.532875, subsequently snapped to 47.404129,-67.533068. Per-hop overrides and whole-chain statistics must be distinguished when reproducing the display. One Balanced response reports a 50.3% whole candidate chain; this does not invalidate Richard’s observed leg result.
- The fresh Clean run at 10:38:53–10:39:09 explicitly used clean_unpaved_last_resort and reports a 25.6% dirt candidate chain. Why pavement was rejected requires tracing; do not call this fallback justified merely because its flag is present.
- Pennsylvania attempts to 41.012231,-78.523020 and 41.043110,-78.489210 both failed in regional segment 2/5. The final route error says no eligible edge within 500 m of START, hop 2/5, destination seam:nb-qc. This locates the regional handoff failure; it does not establish that the destination seam itself is the sole bad object or that all seams are broken.

## Attribution and next boundary

The full-route skip when beyond one tank predates the September 7 evolution: git blame identifies d78440f0 (September 2); cross-region skip identifies af45346d (September 3). This is not a full attribution of the regression and does not exonerate later changes. The shipped search still contains straight-line corridor gates; the draft compass was not shipped.

Freeze broad tuning and production changes. Preserve build 18 and its exact inputs as the failed comparison baseline. Diagnose eligibility/pack coverage versus route selection on the exact Cape Breton case, profile and fuel interaction on the NB case, and the exact failed regional handoff. Do not change thresholds, rebuild packs, or restore old code based only on an inferred cause. Prefer one demonstrated correction and a matched device candidate over another open-ended algorithm revision.

This document records acceptance evidence only; no runtime or Android behavior changes are introduced.
