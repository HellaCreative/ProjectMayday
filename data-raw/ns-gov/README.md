# NSTDB raw archive

This folder holds the audit export from `scripts/pack-ns-gov-roads.js`.
It includes eligible and excluded source features with exclude reasons.

**Do not ship this into `app/data` or load it from the browser client.**

Regenerate with:

```bash
node scripts/pack-ns-gov-roads.js
```

The large `raw-features.geojson.gz` is gitignored. Production display/routing
chunks live under `app/data/ns-gov-chunks/`.
