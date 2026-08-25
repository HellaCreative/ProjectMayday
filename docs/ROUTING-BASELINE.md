# Routing Regression Baseline

Captured 2026-08-25 from the live service before applying the routing-research work.

- Live `serviceBuild`: `dcd63082d315bc9ef49369669afbf2889507f91c`
- Fixed session seed: `3511091208`
- Fuel setup: 230 km tank, 10% reserve, 207 km usable
- Access: dual-sport motorcycle, permissive access allowed, unknown access off
- Clean baseline: major-highway avoidance on
- NS graph: `c2d7b2c6042ed8b6ee9d17a3dc7cf6d5473b88b9e00fd3b937ef773dc537eaa9`
- NB graph: `ef2b554099463fa04613d89a4aef0b8a610175cf878773d9627c94a1fc550db8`

The live oracle uses the app's actual forward workflow: find one reachable fuel anchor, route and commit that hop, reset fuel, then continue. Fuel percentages below are distance consumed as a percentage of the configured 230 km tank.

| Scenario | Profile | km | Dirt | Gravel | Paved | Fuel stops (% tank) |
|---|---:|---:|---:|---:|---:|---|
| Short intra-metro | Clean | 6.6 | 0% | 0% | 100% | None |
| Short intra-metro | Balanced | 9.9 | 46% | 27% | 54% | None |
| Short intra-metro | Dirt | 8.2 | 37% | 26% | 63% | None |
| Rural pair | Clean | 56.9 | 0% | 0% | 100% | None |
| Rural pair | Balanced | 73.6 | 58% | 58% | 42% | None |
| Rural pair | Dirt | 64.2 | 92% | 83% | 8% | None |
| Cross-province | Clean | 348.7 | 5.5% | 0% | 94.5% | Wilson's 68.4% |
| Cross-province | Balanced | 329.6 | 53.6% | 42.6% | 46.4% | Wilsons 85.8% |
| Cross-province | Dirt | 362.7 | 67.9% | 55.1% | 32.1% | Wilsons 90% |
| One-stop | Clean | 277.1 | 0.9% | 0% | 99.1% | Fas Gas Plus 83.1% |
| One-stop | Balanced | 265.4 | 53.1% | 45.1% | 46.9% | Mobil 80.8% |
| One-stop | Dirt | 320.0 | 81.1% | 75.1% | 18.9% | Mobil 90% |
| Multi-stop | Clean | 930.9 | 3.5% | 0% | 96.5% | XTR 78.9%; Irving 89.8%; Coast Gas 75.2%; Maclean's 87.8%; Ultramar 58.5%; four short Sydney-area hops 2.3–4.3% |
| Multi-stop | Balanced | 703.0 | 46.8% | 31.5% | 53.2% | Esso 69.3%; Coast Gas 72%; Irving 75.5% |
| Multi-stop | Dirt | 818.3 | 63% | 55.3% | 37% | Esso 86.2%; Coast Gas 89.7%; Petro-Canada 90% |
| Canso Causeway | Clean | 300.6 | 8.7% | 0% | 91.3% | Maclean's 77.5% |
| Canso Causeway | Balanced | 306.0 | 50.1% | 49.1% | 49.9% | Ultramar 85.3% |
| Canso Causeway | Dirt | 299.6 | 49.1% | 40.8% | 50.9% | Ultramar 90% |

## Guard rules

Run `npm run bench:routing-oracle -- --expected-build <live-head> --compare` after deployment.

- Route distance tolerance: 2 km or 2%, whichever is larger.
- Surface tolerance: 2 percentage points.
- Fuel station sequence: exact.
- Fuel-stop tank consumption tolerance: 2 percentage points.
- Any movement outside the profile/scenario deliberately targeted by an approved item is a suspected cascade and stops the sequence.

The Clean multi-stop result includes a known pre-existing Sydney-endpoint anomaly: the live workflow adds four very short station hops near the destination. This is recorded, not accepted as correct; it prevents a later change from hiding or worsening it without an explicit diagnosis.
