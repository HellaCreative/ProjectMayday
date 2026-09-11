# Private hybrid diagnostics v1

Machine contract: `hybrid-diagnostics.schema.json`. It describes the fuel result's
`phases` and envelope's `resources`; the benchmark combines these into one record.
Road-only requests currently have their existing road timings and the resource
snapshot, not the full fuel phase breakdown. Product API compatibility is pending.

Phase fields use seconds. `roadSearchSeconds` is primary search;
`alternativeSearchSeconds` is additional whole-route generation;
`fuelCertificateSeconds` is on-path/escape certification; `fuelRepairSeconds`
is repair and its scheduling/certification; `geometryAssemblySeconds` serializes
road geometry into the response object. Transport JSON serialization, queueing
and process load remain separately measured. `roadAndCertificateSeconds` is an
older overlapping aggregate, so do not add it to the other phase durations.

In the opt-in strict landmark artifact, internal costs are divided by 1,000.
Public route `weight`, road-candidate `weight` and portfolio `originalCost` are
converted back to the original objective units. Diagnostic repair-trial `cost`
remains in internal units; multiply by `internalCostScale` before comparing it
with those public weights. Distances and fuel quantities are always metres.
Repair `labels` describes the selected policy; sum the individual trial label
counts to inspect work across policies. It is not a request-wide allocation cap.

All memory fields use bytes. Heap before/after includes uncollected garbage;
committed heap is not used heap. Serving-lifetime sampled heap peak starts when
the hybrid telemetry initializes and is shared by concurrent requests. It excludes
earlier import/preparation and may miss peaks between50ms samples. Mapped buffer
capacity is virtual file-mapping capacity, not mapped residency or total OS cache.
Non-heap and direct-buffer fields are separate categories, not a complete native
memory account. External process-group RSS remains necessary.

GC count/time deltas are process-wide and include concurrent requests. Allocation
is cumulative bytes allocated by this request's thread, not live/peak memory;
it excludes transport serialization and any other threads. Unsupported allocation
measurement is null. A post-work idle memory snapshot may explicitly request GC;
this is a diagnostic action, never part of timed normal routing. Do not call heap
use 'retained live memory' without explaining how collection was measured.

Local service protocol additions:
- Request: unique `requestId`, optional integral `timeoutMillis`1–90000.
  Queue delay reduces the remaining execution budget; expired jobs return
  `queue_deadline` without beginning graph work. A bounded queue rejects overflow.
- Cancel: `cancelRequestId`. CONTROL acknowledges whether an active/queued job
  accepted cancellation. Exactly one terminal RESULT is emitted for the request;
  accepted cancellation suppresses a late successful result. Graph weighting,
  fuel exploration and geometry assembly observe thread interruption.
- Idle diagnostic: `memorySnapshotId`, optional `requestGc:true`. Refused while
  tracked jobs remain active/queued. Returns CONTROL with resource measurements
  and explicit-GC disclosure. No system-wide cache purge occurs.

Deadlines are checked at algorithm/preparation boundaries; this is not an OS-level
hard real-time guarantee. Cancellation/queue tests are local, not hosted protocol
or client integration qualification.
