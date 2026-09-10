# Washington restriction16478624

The new engine rejected fromEdge1926698 also appearing as viaEdges[0]. Fresh locked-source OSM extraction confirms relation16478624 itself repeats way1215208058 as from AND via, to332485613, only_left_turn. The duplicate did not originate in compression or production copy.

The from/via source is one-way ramp3396261548→3396261545; graph1926698 is595716→595714, forwardallowed/reversedenied. Destination edge918365 starts595714. Onlyone such repeated entry occurs in Washington. Raw source and decoded evidence are retained under candidate09/wa-restriction-audit.

Proposed interpretation: structurally verified consecutive-role redundancy can be represented as an only-turn node rule from1926698 to918365 at595714, preserving source relation, vehicle applicability and kind. This must be narrowly validated: identical single from/via edge, nonloop, exactlyone legal direction, uniquely connected destination. Do not generalize to ambiguous cases or remove the rule. This is a proposed normalization of malformed source roles; it is not yet implemented, tested, or approved as an engine change. Routing task asked to coordinate derived compatibility view versus versioned pack correction. No sealedobjects or serviceactivation changed.


Routing task selected derived adapter normalization under the exact structural conditions above, with regression tests and provenance. Sealedpackbytes remain unchanged; no rebuildneeded. Independent review requested actual only-turn enforcement and rejection for bidirectional/selfloop/wrong-end/multiple-via cases, preserving applicability and rawcachedpackmetadata. Implementation/test evidence pending.


## Independent implementation review passed

Reviewed0ce8c2e2e51b7a389de6584d1eab280ec4ade321;19targetedtests pass. Actual fullWashingtonadapter builds. Arrival on1926698 permits declaredexit918365 and rejects realcompetingexit1926691 at595714. EntirecachedrestrictionJSON unchanged. Evidence candidate09/wa-restriction-audit/independent-adapter-review.json. Urbanpreparation candidate narrowing also reviewed with unchangedintervalunionsemantics and equivalencefixtures. No packrewrite required. This local review does not replace hosted national verification or authorize unsupportedscopeclaims.
