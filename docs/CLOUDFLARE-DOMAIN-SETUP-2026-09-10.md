# dirtmoto.app domain setup — September 10, 2026

## Current verified state

Hover delegates to elliott.ns.cloudflare.com and raphaela.ns.cloudflare.com. Cloudflare is active on the Free plan. Website and mail remain on SiteGround; apex/www DNS are not proxied. Website returned HTTP 200 and all three existing MX records remain present.

- `packs.dirtmoto.app` is connected to R2 bucket `dirt-packs`, Active and Enabled.
- `tiles.dirtmoto.app` is connected to the existing `dirt-shortbread-tiles` Worker. Replaced only its previous SiteGround placeholder A record (35.209.251.68). No Worker code changed.
- Retained `pub-eb539dc7777942b889388ebb4b701697.r2.dev` and `dirt-shortbread-tiles.dirt-shortbread-edge.workers.dev` for shipped clients.
- Pack manifest matches the legacy hostname byte-for-byte. Archive range request returned HTTP 206, 64 bytes and correct Content-Range.
- Tile verifier passed manifest, health, sample R2 tile, immutable cache headers, attribution, CORS, and outside-archive fallback through the new hostname.
- Active cache rule `DIRT versioned pack assets` makes only packs.dirtmoto.app `/shortbread/v1/releases/` assets eligible, respecting origin Cache-Control and bypassing absent directives. Mutable manifests are not included. Do not extend long caching to mutable catalog paths.

Evidence: `.build/domain-setup-20260910/live-domain-verification.json`; pre-cutover DNS equality in `dns-comparison.json`. Range/cache headers recorded under /tmp/dirt-pack-range*.txt.

## Adoption and rollback

No Xcode configuration or app endpoint switched in this step. The new hostnames are ready for a separately verified client/service adoption. Domain activation alone does not rewrite absolute URLs in existing manifests. Keep old endpoints enabled through that transition. Do not claim that existing distributed apps already use the new addresses.

Reverting the tile binding requires removing its Worker custom domain and restoring the saved A record only if needed for the prior placeholder. Website/email delegation and record copies are documented in the DNS evidence. No paid plan or final App Store submission performed.
