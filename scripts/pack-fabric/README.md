# Pack-fabric implementation index

Routing, fuel, pack formats, acceptance, and publication are defined only in
[the routing source of truth](../../docs/ROUTING-SOURCE-OF-TRUTH.md).
This file identifies repository components, not a build or deployment procedure.

| Location | Contents |
| --- | --- |
| `api/` | Hosted endpoint handlers |
| `routing/` | Routing implementation, adapters, formats, and fixtures |
| `scripts/` | Pack construction, inspection, and release tooling |
| `bench/` | Benchmark runners and recorded results |
| `vercel.json` | Hosted deployment configuration |

Tool names and old examples do not establish the current source format, release,
active implementation, or authorization to publish. Consult the sole authority
before invoking tools that modify packs or services.
