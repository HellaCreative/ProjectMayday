# Active physical-test rollback — DIRT Dev 2 (19)

Owner requested rollback to legal directions / Highway 104 checkpoint and unchanged packs.

Active DEV source: cfa69055dae13595de7cb304f9d92afa73731856 on local branch recovery/legal-checkpoint-v4-20260908, parent 71aa7fd6d396bbf215bc1637ba1e3959f6fcdd6a. The original working tree remains preserved and is NOT the active deployed source. Continue from the rollback branch/source for any accepted next repair; do not accidentally deploy original HEAD or unfinished compass/history experiments.

Source archive: /Users/richardsmith/SandBox01/MAYDAYiOS/routing-recovery-20260907-230537/legal-checkpoint-71aa7fd.

Core JS find-path-v2, fuel-chain and Swift OnDeviceRouter are byte-identical to 71aa7fd. Retained compatibility: current compact V4 readers and graph fetching; 3da6de4 regional loader/router integration; current DEV catalog and original road URLs, connection revision 03; stored routeSeedsData for schema continuity. GraphPackStore later endpoint assignments removed to match original router interface. No road, fuel or connection pack writes.

Validation: five focused JS one-way/reader checks passed; device build succeeded; local NS short route 7303 m in 672 ms; deployed same request complete 7303 m, exact new service identity and original sealed NS graph/geometry SHA. Full routing quality, fuel, and seams remain unqualified pending physical comparison.

Stable DEV deployment dpl_4WofYUgXaJsQkxdRSBixkYyzXpva, pack-fabric-j4cbgn02p-goricksmith-7678s-projects.vercel.app, promoted to pack-fabric.vercel.app. Stable health confirmed source cfa6905. DIRT Dev build 19 installed successfully on White. Production and GitHub untouched.


## Superseded by build 20, September 8 08:11 local

Current DEV/device source is 609df6eeed7cd9cd4b8772ea5ca45de57baaf57a on recovery/legal-checkpoint-v4-20260908; same source directory. Build 20 fixes shared-seam regional ownership in service route/fuel flow, directional V4 permission in JS and Swift search, and restores weak live-pack cache identity in native lookup. No pack writes or profile tuning.

46 JS tests and six Swift reader/one-way tests pass. Initial native test crashed on stale pack lookup; the actual cache class from 3da6de4 was restored and the complete six-test selection then passed. Exact NS→Maine replay now passes the NB middle hop but fails on the disconnected ME island seam. All 128 ME/NB stored anchors lie at 44.8108–44.8952 latitude; mainland coverage remains unresolved and was disclosed to Richard before installation. Do not describe all crossings as repaired.

DEV deployment dpl_7SkBM52WCV6EYLCCCUSzm4Gw3FSc, pack-fabric-f8pi13itf-goricksmith-7678s-projects.vercel.app, promoted to stable pack-fabric.vercel.app; health verifies exact source. Preview short route complete 7303 m with matching identity. Build 20 installed on White. Production/GitHub/road/fuel/seam pack objects untouched.
