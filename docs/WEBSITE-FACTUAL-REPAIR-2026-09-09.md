# Website factual repair prepared — September 9, 2026

Source located: `/Users/richardsmith/SandBox01/MAYDAY-HTML/Untitled`.

Narrow changes prepared in eight static HTML pages and their generator:

- Correct Save to free; GPX export requires PRO and navigation requires PRO after two included starts.
- Describe shipped Profile account deletion and keep Apple subscription cancellation separate.
- Describe precise/approximate location, routing/map geographic requests, group content/sharing, incident reports and opted-in road-edge contributions, plus the known processing services.
- Preserve existing retention, children, rights, international-transfer, liability, governing-law, pricing and contact policies. No legal promises or new retention periods added.
- No design/CSS/assets changed. Generator updated but not regenerated wholesale, preserving later hand-edited site design.

Review patch: `.build/website-factual-repair-20260909/website-factual.patch`.
Before/after files and SHA256 manifest are in that folder. Site Git repository has no tracked baseline and no configured remote, so this independent backup is necessary; nothing was staged there.

Validation: `node --check scripts/generate-pages.mjs` passed. Scanned current HTML/template for the replaced stale Save/deletion phrases. The affected live pages returned HTTP200 with browser user-agent; all eight live HTML SHA256 values exactly matched the saved pre-edit local source. No final browser visual pass because Mac is locked; markup structure was retained except adding a privacy list item.

Publishing mechanism: existing PRODUCT/CHANGELOG specify plain static-file upload to SiteGround. No FTP/SFTP/deployment configuration, Git remote, or publisher script was found. No SSH config exists at the default path. The site is not Vercel and should not be redeployed as a new Vercel app. Publish only the eight changed HTML files to corresponding SiteGround document-root paths after parent review; preserve all other files. Update the last-updated date on the changed policy/support pages when actually published (the source date currently remains August6 so unreviewed legal revision dates are not silently advertised).

**Not published.** Live website continues to serve the old facts until a SiteGround publishing session or existing deployment credential is available.
