# Previously landing: Vercel release handoff

Latest effective-policy publication: **6 October 2026**, deployment `dpl_EAcNw6zcnWPrMxkg2Nea3AkeNBBM`, now verified at `https://previously.cognipin.com`. `draft:false` and the visible effective date are published. The exact production candidate passed eight anonymous routes, 27 unchanged image/font hashes, 11 retired 404s per origin, five source-copy/link checks, eight fresh candidate and five fresh canonical mobile legal layouts, four navigation checks and canonical/candidate eight-response parity. Only `lib/legal-content.ts` changes from the prior 3nW artifact; native icon, Dynamic Island and product-tour code are unchanged. Project, Hobby plan and deployment protection are unchanged. Prior3nW remains technical rollback evidence. Receipt: `docs/qa/2026-10-06/landing-final/effective-publication/qualification-receipt.json` from the repository root. This is website publication, not real native consumer deletion, sign-in or Files QA or App Store submission. Earlier draft publications below are historical.

Latest publication at 14:00 UTC is `dpl_3nWUk4d8w6tw6Kf3v8VL7qTZv9jB`, remotely built from source manifest `a7a7dadf8ea6cf930945bb3722d265e23aeb756a4b4b03611ce798e4b1ea6211` and promoted as the exact qualified candidate. Rollback is `dpl_9wXk1mXyNzMzXjmTWXTH2iN5KTsM` (`https://landing-9jo84k2v7-shan2news-projects.vercel.app`). Only `app/experience.tsx` and `app/gallery.css` changed from that rollback: a decorative CSS Dynamic Island hardware capsule is positioned in the hero phone’s empty status-row center, with the existing rotation applied to its common screen frame. Original native screenshot pixels, app text/status placement, all 27 public image/font files and legal copy are unchanged. Three fresh desktop/390/320 hero layouts and the Library hero-link/dialog/Escape-focus flow passed. Eight routes and 27 original asset hashes passed through staging and canonical, all eight canonical response hashes match the candidate, and all 11 retired assets still return 404. Evidence: `docs/qa/2026-10-06/branding/dynamic-island-publication/qualification-receipt.json` from the repository root. The previous branding qualification and Clerk saved proof remain valid only within their explicitly unchanged scopes. `draft:true`/`effectiveDate:null` remain; this website pass changes no root-owned production or App Store readiness flag.

Earlier native-brand publication at 13:53 UTC: `dpl_9wXk1mXyNzMzXjmTWXTH2iN5KTsM` served the canonical site; qualified 7LeP remains historical rollback evidence. Source manifest `daa643cdf21e27f9314026d89190c19693f28a935bb733387ffe68cfcf9c928c`. The shared header/footer, favicon, touch and social metadata use the actual signed archive13 split-flap P/red-dot PNG, byte-identical at 152×152; the wordmark period uses native `#F0563F`. The hero and four-feature gallery use original dated native simulator captures: Home 5 October (1179×2556 PNG), Library/Schedule/Search 2 October (369×800 JPG). No image was edited, redrawn or upscaled. These accurately represent current appearance/navigation; they do not prove current production authentication. Public dialog captions describe app features/sample data. The existing September season-picker example has no retired brand mark and remains historical. All eleven obsolete bookmark/four-tab assets are retired. Evidence: `docs/qa/2026-10-06/branding/publication/qualification-receipt.json` and `asset-provenance.json` from the repository root.

The exact remote build passed eight anonymous routes, 27 current original asset hashes and 11 retired 404s through staging and canonical; all eight canonical response hashes match the candidate. Five new responsive layouts (Home 390/320, Privacy 390/320 and Home dialog 320) and four 390 gallery image/dialog/Escape-focus checks passed. The prior six legal layouts, two device-paragraph layouts and 19 Home-run checks are separately scoped historical references for unchanged copy/interaction implementation. They are not fresh tests of the changed visuals. Clerk application Logo and Favicon were also saved from the original archive 152 PNG and survived a reload; its CDN displays a resized 76px rendition. The Pro branding-removal toggle remains off. No auth/provider/DeviceTrust setting changed.

This branding pass leaves `lib/legal-content.ts` byte-unchanged: `draft:true`, `effectiveDate:null`. The earlier SDK-source audit and its recorded pending archive inventory remain distinct from root’s later actual-archive work and App Store privacy publication. The approved June dump is already removed. Retention jobs and identity migration were not performed by this website task; the latest root operations/auth receipts must establish their actual deployed state. Keep existing consumer-readiness flags false until root verifies their evidence. No local build/install, DNS, project, plan, SSO or paid integration change occurred.

Prepared and deployed 6 October 2026. Scope: the landing website and public support, privacy, terms and deletion pages. Backend and iPhone verification are separate. The earlier **device-disclosure draft** deployment was `dpl_7LeP7Y1i3y8F48AJbJpwbLTZqLKB`, promoted at 13:29 UTC and anonymously qualified at `https://previously.cognipin.com`. It adds the exact Clerk device-data disclosure from `lib/legal-content.ts`, retains `draft: true` and has no effective date. Previous qualified draft `dpl_2BUUc6ZREKY29QVMdaF6zEr4BeGg` is preserved for rollback; the earlier EMPz deployment and receipts remain historical. This draft publication changed no DNS, project, plan or SSO protection.

Earlier device-disclosure evidence is in `docs/qa/2026-10-06/landing-final/device-id-draft-publication/`: source/upload manifest, exact candidate/readiness, staging qualification, promotion/rollback receipt, canonical HTTP/assets and alias readback. Source manifest SHA256: `38b4e8c44c7dc8036801749a9e1bac4dafc9c5ec39e9a25ae63bed19a99d7922`. The 124-file upload changed only `lib/legal-content.ts` from the prior qualified source. Eight anonymous routes and 33 unchanged image/font hashes passed on staging and canonical, with all eight route response hashes matching the exact candidate. Five visible page copies match the prior qualified public copy plus one precise Clerk paragraph replacement. Two new privacy-provider layouts at 390/320 pixels passed CUA with no document overflow. Prior six legal layouts and 19 home behavior checks remain explicitly scoped historical evidence; they are not counted as new checks.

## Implementation

The existing visual composition, Outfit fonts, amber page accents and product-tour interactions are preserved. The latest native icon and four dated captures replace their retired versions as described above. The build uses pinned official Next.js 16.3.8 with `output: 'export'`. Vercel serves generated HTML, CSS, JavaScript and local images from `out/`. No runtime function, image transformation service, database, analytics script or authentication integration is needed for the website. Client components retain the existing tour, image dialogs and FAQ.

`NEXT_PUBLIC_SITE_URL` is a public build-time HTTPS origin without a path, query or credentials. It is used by canonical metadata, Open Graph, sitemap, robots and SoftwareApplication JSON-LD. The source defaults to `https://previously.cognipin.com`; the owner verified its DNS, TLS certificate and eight anonymous routes at 12:16 UTC. The latest draft-copy build explicitly used this origin, and its deployed canonical metadata, robots and sitemap now match. This setting is not an authentication secret. Future builds must use the same owned origin even if an explicit environment override exists.

The migration removes Vinext beta, Nitro, Cloudflare/Vite adapters and the old Vite config from this deployment target. `postcss.config.mjs` replaces the Vite-specific Tailwind wiring. `vercel.json` selects Next.js and `npm run build`; the project output-directory override is unset so Next inspects `.next` and extracts its framework output. Local Next still exports static files to `out/`. An unpromoted candidate with an explicit `out` override failed because the Next builder looked there for `routes-manifest.json`; its failure was preserved and the override removed. Static headers prevent MIME sniffing and disable unused camera, microphone and geolocation access. Package and project Node versions are pinned to `24.x`. Generated dependencies, local `.env` files, Sites settings, source research, `out`/`dist`, `.vercel` and old adapter/tool caches are excluded from an upload.

## Existing deployment inspected through the connector

| Item | Verified value |
| --- | --- |
| Project | `landing` |
| Project ID | `prj_osATa26wuWMoLf7yLOEaXvYuiial` |
| Account ID | `team_WGVvWCwyPJLQHHMvAUdYU9td` |
| Current framework setting | `nextjs` |
| Current Node setting | `24.x` |
| Current root / output overrides | Both unset (`null`); deployed from `landing/`, framework output detection |
| Stable public alias | `https://landing-ten-theta-55.vercel.app` |
| Promoted production deployment | `dpl_3nWUk4d8w6tw6Kf3v8VL7qTZv9jB` (branding/hardware draft) |
| Previous production deployment | `dpl_9wXk1mXyNzMzXjmTWXTH2iN5KTsM` (qualified branding draft rollback) |
| Previous deployment URL | `https://landing-9jo84k2v7-shan2news-projects.vercel.app` |
| Previous deployment state | `READY`, production |
| Other inspected aliases | `thepreviously.vercel.app`, `landing-shan2news-projects.vercel.app`, `landing-git-main-shan2news-projects.vercel.app` |

The checkout is linked through ignored `.vercel/project.json` to the existing project. The connector read the project and deployment, but its team endpoint returned scope403 and team-list returned no teams. The existing authenticated CLI fallback read the exact team successfully: slug `shan2news-projects`, billing plan `hobby`, status `active`, then completed the approved existing-project deployment. No plan change occurred. Never accept a paid plan or trial as a workaround.

## Policy statements requiring release evidence

`lib/legal-content.ts` is prepared copy, still visibly draft with no effective date. Finalize it after these facts match the deployed candidate:

| Statement | Evidence required |
| --- | --- |
| Actual Clerk identity deletion | Production instance configured, backend secret present, real accepted deletion and status reconciliation exercised |
| Apple and Google sign-in | Enabled production providers, basic identity scopes only, and real production account access verified |
| Apple deletion authorization | Bound fresh proof exchanges and revokes only the deleting account’s Apple grant; proof is never persisted or logged |
| Apple manual fallback | Cancellation sends no DELETE; an unavailable grant still permits app-data erasure and preserves manual Settings guidance across relaunch |
| Pending cleanup survives failures | Durable ledger migration applied, worker retry and process restart behavior verified |
| Local account cleanup | Owner-scoped native stores, pending writes, recents and temporary exports verified through sign-out, deletion and cold launch |
| Comments/replies disabled | Production flag and actual UI/routes checked |
| Paid model calls disabled | Launch environment and actual paths inspected; no user search correction to a paid model |
| Seven-day capped sanitized app logs | Operational rotation installed and exercised; raw URL, body and identity leakage reviewed |
| Seven-day database backup expiry | Owned backup job installed, successful dump and expiry evidence, isolated restore tested |
| Deletion-safe restore | Current deletion ledger preserved separately and applied before reopening restored service |
| Thirty-day aggregate snapshots | Collector and pruning installed; output contains counts and route patterns without individual events |
| Support route | Mailto works and the operator inbox is available; retention remains as needed to handle requests/required records |

The copy distinguishes an accepted app-data deletion from pending authentication cleanup. A lost response is not proof of failure or success. It discloses the retained minimal hashed deletion marker, the deletion ledger’s temporary raw identifier while cleanup is pending, separately retained existing moderation/security restriction records, expiring backups, separately saved exports and infrastructure-provider records. `moderation_bans` currently retains a raw authentication identifier, reason and timestamps after erasure; do not describe the entire service as holding only hashed identifiers after deletion without changing and verifying that table. It includes feed likes, saves, reminders, ratings, recommendation feedback and imports, even while public comments are off. It does not claim “no data collected.”

The resolved Clerk iOS 1.5.8 source audit records authentication requests carrying the vendor device identifier, device type/model, OS version, app version and bundle identifier, plus signed-in client identity. The published Clerk paragraph now explicitly includes vendor device identification, session/device tokens, device model, OS and app information. This is an SDK-source finding, not a claim that the final Release archive has been inventoried. `docs/qa/2026-10-06/sdk-privacy-audit.json` recorded archive13 inspection as pending; the separate App Store Connect receipt `app-store/device-id-privacy-draft-saved.json` records a saved, unpublished Device ID category for App Functionality, linked to the user and not tracking. Actual archive inventory and final privacy publication remain the root owner’s release work. Existing development identities must be mapped and qualified against the production Clerk realm; this website publication does not migrate accounts or establish production sign-in/deletion proof.

Google sign-in is identity access, not Gmail mailbox access. Apple sign-in can use Hide My Email. Apple deletion can ask for a fresh system authorization before submitting the deletion request. The server persists only `revoked`, `manual_required` or `not_applicable`, never the short-lived authorization code or identity token. The prepared deletion page links to [Apple’s current settings instructions](https://support.apple.com/en-us/102571), which account for menu-label changes between supported iOS versions. The native/backend source contracts are still awaiting final qualification and production proof.

The trailer disclosure describes the actual `youtube-nocookie.com` privacy-enhanced iframe and nonpersistent web data store being qualified. It does not promise that YouTube receives no network information or serves no ads. The app runs no advertising program of its own. The terms describe the current same-hardware backup limit and direct people to library export for a copy under their own control.

The owner-approved obsolete June database dump was removed at 12:45 UTC; today’s verified backup was preserved (`docs/qa/2026-10-06/operations/legacy-backup-retired.json`). The seven-day backup/log and 30-day aggregate retention jobs were still prepared but uninstalled during this publication. Dump retirement alone does not establish operational retention.

Do not add licensing outreach to this release: the user explicitly deferred that work until market validation. Store content-rights declarations must still be answered truthfully by the owner in their actual form.

## Validation and promotion

Local qualification completed at the timestamp in `docs/qa/2026-10-06/landing-release/browser-report.json`: lint, strict TypeScript, Next static build and 19 browser checks passed. All eight routes are static. The checks cover five HTML documents, canonical metadata, actual contact links, draft/noindex behavior, robots/sitemap, 404, tour/dialog/FAQ flows at 1440/983/390/320 pixels, legal-page mobile overflow, keyboard focus, Escape restoration, reduced motion, deep links and zero external requests/console errors. All managed preview processes were stopped. These are local checks, not deployment or native-app claims. Evidence includes screenshots and a SHA256 manifest of the static output.

Browser inspection found missing Tailwind utility generation in the old scaffold: the dialog and backdrop rendered as static page content. The production stylesheet now imports Tailwind and its animation utilities, and the custom tour explicitly retains its vertical root layout. The final check verifies fixed dialog positioning inside each viewport. Unused shadcn generator dependencies were removed, the formatter updated, and compatible patched compression/source-map/URI versions resolved; the complete dependency audit reports zero advisories. The approved hero, screenshots and brand remain intact.

The **earlier EMPz** production promotion receipt records that exact ready deployment and its then-prior deployment. Its public qualification passed 19 anonymous Chromium checks, 16 HTTP route checks (eight through each public alias) and 33 public asset SHA256 comparisons. Responsive widths 1440/983/390/320, tour/dialog/focus/FAQ/reduced-motion/deep-link flows, draft policies and zero external requests/console errors were checked. The initial immediate-image wait failure is preserved; the final bounded 15-second image-load check passed. These are historical public website checks, not backend or iPhone claims. Evidence: `docs/qa/2026-10-06/landing-release/vercel-production/{promotion-receipt.json,public-http-assets.json,public-browser/browser-report.json}` from the repository root. The latest draft publication adds the separate checks described at the start of this handoff.

For the earlier device-disclosure candidate, existing Vercel SSO protection (`all_except_custom_domains`) was preserved. A remotely built production-environment candidate used `--prod --skip-domain`, then the already-existing secondary alias `landing-ten-theta-55.vercel.app` was assigned for anonymous qualification. Its prior 2BUU target was captured first; the canonical custom domain remained on 2BUU until the new eight-route/33-asset and two privacy-layout checks passed. Promotion reused the exact candidate without another build. No local compilation competed with native QA. Final effective-policy activation is still a separate root cutover step.

For a future change, run after any shared-host capacity test is complete:

```sh
cd /Users/shan2new/Projects/previously/landing
npm ci
npm run lint
npx tsc --noEmit
npm run build
npm start -- --listen tcp://127.0.0.1:4322
```

Inspect static HTML for `/`, `/privacy`, `/terms`, `/support`, `/delete-account`, `robots.txt` and `sitemap.xml`. Expect one H1, the correct canonical origin, functional contact/deletion mailto links, no draft marker after finalization and actual effective date. Check a missing URL returns 404. Verify desktop and 390/320-pixel layouts, four tour tabs, image dialog focus/escape/restore, FAQ and reduced motion. The website must make no app API or analytics requests.

Create a preview under the existing project using explicit Next.js/static settings and Node24, with no paid build machine. Record deployment ID, source manifest hash and `READY` state. Check anonymous HTTPS responses rather than relying on the dashboard state. Recheck the same layouts and keyboard paths on the deployed preview. Promote that exact verified deployment to production, preserve the old deployment ID, then verify the stable alias anonymously. A consumer App Store download link can be added when its public listing actually resolves; uploading for review is not public availability.

If production HTML or assets are wrong, re-point the aliases to the captured old deployment. This landing rollback does not roll back the app database or backend. Do not republish an old privacy statement that contradicts already deployed account behavior.

## Free-plan boundary

The site needs static delivery only. Hobby has no automatic paid overage; resource exhaustion can pause a feature. Its non-commercial personal-use requirement must remain true as the product evolves. The user confirmed free initially and commercial later, so commercial transition is a future hosting decision rather than permission outreach at launch. Do not add paid monitoring or storage to this site. Backend reliability/usage metrics live on the Mac Mini.

Sources verified 6 October 2026: [Next.js static exports](https://nextjs.org/docs/app/guides/static-exports), [Next.js on Vercel](https://vercel.com/docs/frameworks/full-stack/nextjs), [Vercel Hobby](https://vercel.com/docs/plans/hobby). Current registry metadata confirmed Next.js 16.3.8 and compatibility with React19 before pinning.
