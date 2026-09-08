# Legal-direction checkpoint rollback


## September 8 owner-directed rollback candidate

Routing behavior is restored to 71aa7fd (September 6 legal directions/Highway 104 work). Current sealed V4 road/fuel files and connection revision 03 are unchanged. Compatibility overlay retains compact V4 readers, streamed/lazy loading, catalog URLs, V4 regional topology selection and installed multi-region loader integration. The later-only native customer endpoint assignments are omitted because the restored router has no such interface. SavedRoute.routeSeedsData remains present solely for installed-store schema continuity. No new route costs, search rules, fuel ranking or compass work is included. This candidate is for physical comparison, not qualification; Android must use the restored behavior before parity is claimed.

Later experimental work and build 18 are preserved in the original working tree and backup/before-legal-checkpoint-rollback-20260908. No original pack bytes, production deployments, or GitHub refs changed.
