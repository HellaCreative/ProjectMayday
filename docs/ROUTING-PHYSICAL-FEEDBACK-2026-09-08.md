# Physical feedback — September 8, 2026, build 22

Richard reports fast, good Nova Scotia routing including fuel stops; US routing fails; Quebec is slow with no fuel. This is positive NS route-building feedback, not blanket engine or navigation acceptance.

Evidence: `/Users/richardsmith/Downloads/dirt-app-debug-2026-09-08T200606Z.txt` and `/Users/richardsmith/.codex/attachments/2d69d71a-d7ff-4f05-ac0c-69c068ece6e6/pasted-text.txt`. All cited requests report live source ecf746ef8497df49c996c0853fe84743de331f7f.

## Findings

- NS: adventure-preview-v1 on fabric-v4-20260908-02. Cape Breton request fuel-7ab67775 completes in 1706 ms with two fuel stops and destination. Other observed NS requests complete in 1202–1778 ms. Individual samples, not performance percentiles.
- Quebec pin: 46.112541326743006,-74.52358866884316. Preserve actual logged coordinate rather than substitute the named landmark in Richard's recollection. Fuel-44a882fa fails in 8610 ms: match_failed, regional segment 2/3. Response identities cover NS/NB02. This points to an intermediate segment endpoint match; it does not prove the rider's destination is invalid or that there are no stations. Road-only fallback route-498a6dce then completes in 44017 ms, 1909103 m, on NS/NB/QC02; search accounts for 29253 ms. Combined wait is approximately 53 seconds. UI commits an unverified tail with zero preserved pumps.
- US pin: 42.42887651518565,-72.66903969731547, classified ma by client. Fuel-6f3a030b times out at 23025 ms. Road-only fallback route-22edd325 fails after 42207 ms: search limit hop 4/5 at seam:ma-nh. Combined wait approximately 65 seconds. No geographic no-path or fuel scarcity was established.
- US destination fuel lookup returns NY, stable-or-local identity. This is a coverage/selection flag requiring server inspection; it is not proof that every route hop used NY.
- A later NB request takes roughly 40 seconds: 5.4 s fuel reachability, rejected 10.1 s first station route, 7.7 s alternative route, 15.5 s continuation. It exposes legacy candidate-then-route retries, unlike the integrated NS search.
- Phone logs mention an installed NS01 file and connections03, but explicitly select live. Server response hashes identify online routing data. Updating downloaded phone packs would not repair these live failures.

## Scope and next integration gate

The new live adapter explicitly accepts single-region NS02 only. Cross-region routes retain the old engine. National03 publication can update coverage and connections but does not extend the replacement algorithm by itself. Keep successful NS02 behavior pinned.

The pack owner has received both exact failing fixtures for combined national preview acceptance, including the US region-selection flag. Next engine integration priority is coherent cross-region search with fuel included and one total request budget, preserving turn state and remaining fuel across boundaries. Do not claim success from a road-only fallback or from publishing newer pack bytes.

Reconstructed request fixtures are in `scripts/pack-fabric/bench/fixtures/device-feedback-20260908.json`; omitted unlogged fields are not claimed to reproduce the byte-exact original body. Cross-region fuel windows return at most one stop: acceptance must follow continuation windows through the actual destination, not stop at the first successful window. Verify contiguous road geometry, reserve-adjusted range at every stop, destination escape, style identity and precise per-region pack identity. Log matching failures separately from search limits and genuine geographic infeasibility.

No engine fix or new deployment is claimed by this diagnosis. Android behavior is unchanged; these fixtures represent shared rider outcomes for eventual parity.

## Accepted NS toggle sequence — 20:15 export

Richard calls the Porters Lake → Cape Breton sequence a big win: fast Dirt routing without fuel, more interesting dirt after Allow Unknown, then fast fuel-supported rebuild. Evidence: `/Users/richardsmith/Downloads/dirt-app-debug-2026-09-08T201531Z.txt` and screenshot at `/Users/richardsmith/Downloads/Screenshot 2026-09-08 at 5.14.51 PM.png`.

- Start 44.764834,-63.340240; original Cape Breton pin 46.873410,-60.531752; subsequently snapped pin 46.873425,-60.531758.
- Dirt, unknown off, no fuel: route-233f611a, 5532 ms HTTP.
- Dirt, unknown on, no fuel: route-e13d2a8b, 2435 ms HTTP. Screenshot shows 593.5 km, 82% dirt / 18% paved, Allow Unknown on and fuel OFF. Do not attribute screenshot totals to the later fuel-supported route.
- Fuel enabled with 225000 m usable/initial range: fuel-02243e0f, 4101 ms HTTP, three planned pumps plus destination; all four legs committed. strategy=adventure-preview-v1, selected=dirt-30.
- Earlier southwest NS request fuel-ca7923a6: 2888 ms, three pumps, 198000 m usable range.
- All responses identify ecf746e and NS fabric-v4-20260908-02 with unchanged hashes. Timings are individual device samples including transport, not percentiles.

Diagnostic flag: the final fuel request correctly logs allowUnknown=1, but the generic FUEL diagnostic summary prints allowUnknown=0. This requires checking the summary mapping; do not infer the engine ignored the option from a defaulted diagnostic field. Current live adapter reads accessPolicy.motorizedUnknown into the normalized intent.

Preserve this successful physical route-building baseline. Current owner scope is NS and NB, including cross-provincial tests; Quebec/US engine work deferred. No full navigation or station-access qualification is implied.

## 20:50 / 20:56 Atlantic feedback and local correction

Physical Dirt Porters Lake→NB request fuel-56fa7e58 passed per rider: fast,
interesting and fuel supported. Clean used a DIFFERENT destination
46.792506,-67.569371, so its time is not a direct style comparison. Clean sent
avoidMotorways=true, which the canary excluded; logs prove legacy
forward_graph_reachability_across_seams and subsequent legacy fuel planning.
The ordinary phone preference was missing from hosted acceptance requests.

Dalhousie request fuel-62eabc66 (44.764831,-63.340263→47.986597,-66.328424,
Dirt known access,225km usable) is a physical PARTIAL FAIL. Exact local replay:
1005.302km,74.446%dirt,65.610km repeated roads; fourth pump Trout Brook XTR.
Excluding that generated pump in a counterfactual yields Sunny Corner Irving,
958.049km,72.340%dirt,4.095km repeated roads; every hop plus final escape verified
within range. This demonstrates an avoidable detour, not a geographic fuel gap.

Local correction: complete the common base candidate pool first, then bounded
one-pump alternatives for substantial fuel-linked circuits. No station-specific
blacklist. Never move fixed station anchors; interrupted/infeasible alternatives
cannot replace originals. Accept only shorter alternatives with less retracing,
no more avoidance exposure, and higher fresh-known-dirt distance per actual
kilometre travelled. Display surface percentages remain actual physical totals.
One trial per objective under the same request deadline/work cap; residual
retrace and other alternatives remain possible. 1km repeated-road trigger is
an investigation threshold, not a prohibition on necessary fuel access.

Clean now accepts the phone preference and minimizes motorway/core exposure
before ride cost. Legal unavoidable connections remain available. Road classes
are returned on materialized segments for review. NB02 lacks BOTH urbanCores
and settlements. A source-locked, versioned NB classification review supplies
Moncton/Saint John/Fredericton/Dieppe boxes, threshold city/town population20k.
Small rural towns stay allowed; source/radii/unknown population records are in
nb-urban-review-20260908-01.json. These approximate boxes do not prove complete
urban classification. Original packs remain sealed and unchanged.

Clean replay with the supplement:704.381km,99.991%paved,zero measured motorway
and reviewed-core exposure. It still contains106.955km classified trunk and
391.296km primary. This is NOT a Clean back-road quality pass. OSM primary/trunk
classification alone does not establish whether the actual roads are divided
freeways or appropriate rural highways. That review remains open.
