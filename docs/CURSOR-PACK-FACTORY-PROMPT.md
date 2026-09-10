# Cursor prompt — DIRT legal-topology Pack Factory (NS V4 canary)

Use this prompt. The checked-in `docs/PACK-FACTORY.md` is authoritative.
Do **not** build or promote remaining V3 regions.

---

You are fixing DIRT’s regional pack factory and proving one Nova Scotia
legal-topology canary. This is a safety migration, not another V3 restamp.

Work only in `/Users/richardsmith/SandBox01/MAYDAYiOS/Dirt` on
`feature/routing-itinerary-rebuild`.

Stop every US/provincial V3 pack build. Do not publish, upload, promote,
change a public catalog, or point production LIVE at new packs. Do not reset
or overwrite the dirty worktree. Do not change frozen route costs, search
widths, fuel selection, stage-edit ownership, warnings, UI, or rider-services.

Read completely: `AGENTS.md`, `docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md`,
`docs/ROUTING-FREEZE-2026-09-03.md`, `docs/PACK-FACTORY.md`,
`docs/PACK-DATA-V4-AUTHORITY.md`, `docs/PACK-DATA-V3-AUTHORITY.md` (rollback
only), `docs/ANDROID-PARITY.md`, `.cursor/rules/live-and-pack-lockstep.mdc`.

Report uncommitted changes before editing.

Implement `graph.v4.bin` + `pack-manifest.v2` + capability `legal-topology.v1`
in a new R2 namespace. Keep public V1/V3 intact. Readers in JavaScript, Swift,
and Kotlin must reject unsupported versions, missing capabilities, identity
mismatches, mixed-contract routing, and missing safety sections.

Do not rebuild Nova Scotia until factory, format readers, fixtures, and
validators are green. Then build NS **once** as a DEV-only candidate. Do not
build a second region until the owner physically accepts NS. Do not alter
production.

Stop and report if a requirement would change frozen costs/search law or fuel
selection. Access eligibility for V4 motorcycle (ATV must not override
`motorcycle=no`) is an explicit legal-topology change documented in
`docs/PACK-FACTORY.md`; it is not a cost retune.

Handback: files, V4 spec, provenance, JS/Swift/Kotlin results, NS counts and
rejections, candidate identity, proof that production/V3/other regions were
untouched, proof stitches and coordinate-identity are gone, device test card,
proposed national order — do not start the national rebuild.
