# National restriction reader compatibility

Sequential actual-pack decode/createV4Graph audit on0ce8c2e completed63regions:35pass,28fail. No memory crashes; maximum observed processRSS312MiB. Raw cached restrictionJSON unchanged for passingregions. This is graph-only construction, not fullsearch/memory/concurrency qualification.

Failing regions: ab, al, ar, az, bc, ca, co, fl, ga, hi, ia, il, ky, la, ma, mn, mo, ne, nj, ny, oh, or, pa, qc, sc, sk, tx, va.

All failures are ambiguous_via_way_entry; details and first offendingOSMrelation/edge indexes perregion are in candidate09/restriction-compatibility/summary.json. This captures only FIRST failure perregion. Distinctclasses include repeatedsameedge and differentedges sharingbothendpoints. WA's narrowlyproven normalization does not resolve these. National-engine readiness cannot be inferred from the earlier63fileintegrity audit. No sealedpack changes or nationalactivation performed.


## Full classification and writer provenance

All63packs scanned for everyambiguousentry:199unhandled records from54uniqueOSMrelations;177identicalfrom/via,22distinctedges sharingbothnodes. Another5records satisfy existingWAproof. Every199storedentry is a sharednode and yields contiguousvia/to sequence.114records have directedarrivalandfullpath;85include direction-impossible variants. Full perregion structurededge/access/walk evidence is in restriction-classification; raw54relations extracted fromlockedPBFs withzero sourcewaymembership mismatches.

Exactfactorya4589c2 resolveViaWayPaths enumerates sharedsourcejunctioncombinations, orderedWayPath preserves uniquecontiguouswayedgepaths, and emission stores path.entryNode asviaNode. It is source-resolved, not an arbitrary choice. Multiplevariants mayexist and directions are notfiltered atwriterresolution. The osm-graph.js source is identical inreusedfactoryae8aa948. Reader should validate/use recordedentry and preservefullstatefulrules; no blanketflattening or droppingunreachableonlyrules. This analysis is not a complete proof ofintendedOSMsemantics for malformedrelations.
