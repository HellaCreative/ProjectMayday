# Graph loading experiment checkpoint — September 10, 2026

Owner requested a recoverable checkpoint before trying demand-loaded working areas.

Accepted live DEV source: `139a173` (regional fuel repair, owner-tested Quebec and Bangor).
Stable DEV deployment: `pack-fabric-gez7gslte-goricksmith-7678s-projects.vercel.app`.
This checkpoint also retains private, unfinished multi-region selection and memory repairs.
They have not been promoted. Six-region fuel-off replay still reaches 90 seconds.
Latest measured cold preparation: 41.7 seconds loading/joining, 16.9 seconds graph
preparation, 23.6 seconds reverse bounds, 7.1 seconds forward search.

Experiment: compare 5,000 / 10,000 / 30,000 edge working sets with full-data
reference. Count loading, memory, search work and connection/fuel correctness
separately. Do not truncate edges at the cap, treat missing pages as impassable,
or claim post-route background loading validates an earlier unproved route.
Existing pack artifacts stay unchanged. No app build or production promotion.
