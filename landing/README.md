# Previously. landing website

Public-facing product introduction for **Previously.**, the TV and anime companion. This website is separate from the iPhone app, backend API and retired `legacy-web` app.

## Local development

```sh
npm ci
npm run dev -- --hostname 127.0.0.1 --port 4321
npm run lint
npx tsc --noEmit
npm run build
npm start -- --listen tcp://127.0.0.1:4322
```

Stack: official Next.js 16.3.8 with a static export, React 19, TypeScript and the existing Base UI/Shadcn primitives. Product and legal copy are rendered at build time. The app tour and FAQ use client components for tabs, image dialogs and accordions. Font and artwork assets are local. The tour makes no app API requests or account changes. There are no Vercel functions, image optimization functions, app-owned analytics scripts, database bindings or account cookies on this website. Normal hosting requests still occur. The previous Vinext/Cloudflare/Nitro adapters have been removed from this Vercel target.

## Content and launch settings

- `app/page.tsx`: landing page and truthful SoftwareApplication JSON-LD.
- `app/experience.tsx`: the app-led hero and source-checked FAQ.
- `app/product-tour.tsx` and `app/product-tour.css`: responsive Home, Schedule, Library and Search tabs with actual iPhone captures, enlarged images and a native season-picker example.
- `app/gallery.css`: the Netflix/Apple TV-inspired poster-wall hero, header and FAQ layout.
- `app/globals.css`: shared Previously. theme, legal layouts, FAQ and footer styles.
- `lib/site-config.ts`: the public canonical origin, set through `NEXT_PUBLIC_SITE_URL` at build time. The default is `https://previously.cognipin.com`, whose DNS and anonymous HTTPS routes were verified on 6 October. Metadata, robots, sitemap and JSON-LD all use the same origin. Explicit build settings must use this owned origin too.
- `app/layout.tsx`, `app/robots.ts`, `app/sitemap.ts`: page metadata and search discovery. The support page is discoverable; draft policies enter the sitemap when finalized.
- `public/brand`: the exact 152×152 split-flap P/red-dot PNG from the signed 1.0(13) archive, byte-copied without editing or upscaling; header/footer, favicon, touch and social metadata share it.
- `public/app`: real native simulator captures: Home from 5 October 2026 (1179×2556 PNG), Library/Schedule/Search from 2 October 2026 (original 369×800 JPG). Preview and full view share each original unchanged file. The 6 September seasons capture remains a historical native example. These are dated app-interface snapshots, not fresh production authentication proof. Source hashes and provenance: ../docs/qa/2026-10-06/branding/publication/asset-provenance.json.
- `docs/research/app-grounding-2026-09-06.md`: current product evidence, asset provenance and verification.
- `docs/research/visual-spike-2026-09-05.md`: earlier measured benchmarks, user-selected Netflix/Apple TV references and rejected directions.
- `docs/spike.md`: earlier research, verified feature boundaries and original asset sources.
- `docs/research/artwork-2026-09-05.json`: newly integrated artwork provenance.

There is no verified App Store/TestFlight URL in the repository. The page honestly states that its public download link is not yet available. Update the primary call to action, availability label and FAQ when a verified link is provided. Do not use `anime.cognipin.com` as an app destination: it is the backend API.

Search eligibility requires a publicly accessible deployment. The code allows search crawlers and includes textual product answers, canonical metadata, a sitemap and JSON-LD; it does not guarantee indexing or rankings. No generated reviews, download counts, prices, endorsements or unsupported app features are included.

## Verification

Application lint, TypeScript and production build are checked alongside browser verification of the tour, dialogs, FAQ and mobile layout. The lint script checks application-owned source. The current revision introduces the product with a real Library screen, then replaces the illustrative collection, progress, schedule and updates interfaces with actual app screens. The screenshot dates are snapshots, not a live release feed. See the current research report for the evidence and verification limits.

Only the landing directory is publishable. Never include parent environment files, SQL dumps, iPhone/backend source or local caches in a deployment. Build artifacts and dependency folders are ignored.

After the lower tour was grounded in the app, the user requested an improvement to the upper section too. The hero now pairs a larger, left-aligned Outfit headline with the actual Library screen. Existing poster artwork provides a quieter backdrop. The page retains its amber accents and coming-soon status. The app icon uses the current split-flap P/red-dot identity. The four-feature tour shows actual Home, Schedule, Library and Search captures with current five-tab navigation and explains those workflows. Tab and dialog controls support keyboard input; closing a dialog restores focus. Touch targets are at least 44px tall and new motion respects reduced-motion preferences.

The refinement pass keeps the approved composition and connects it more closely to the tour: the hero screen links to Library, desktop tabs explain each section, and the tab bar stays within reach while scrolling. Selecting a tab keeps the URL in sync and brings its introduction into view when needed. Full-screen image controls sit below the captures, leaving the app screens unobstructed. The tour, FAQ and footer share the same warm neutrals.

**Outfit is the brand typeface throughout the website.** The gallery inherits the global Outfit family. Local static files are accurately declared at 400, 500, 600 and 700; the Bold file comes from the iPhone app's existing font assets. Use 700 for the hero and 600 for section headings and primary controls. Do not replace Outfit with a system font when interpreting visual references.

## Consumer release preparation (6 October 2026)

The `/privacy`, `/terms` and `/delete-account` copy is prepared for the production configuration being implemented. It describes durable deletion with truthful pending status, owner-scoped local cleanup, comments off, paid model APIs disabled, sanitized seven-day app logs, seven-day database backups and 30-day aggregate snapshots. It also describes basic Apple/Google identity sign-in, no Gmail-message access, fresh Apple authorization during deletion, and the manual Apple settings fallback when revocation is unavailable. Links to processor privacy notices and Apple’s current account-settings instructions are included. These statements are **not yet a verified description of the deployed service**. Keep `legalPublication.draft=true` and its date unset until the release owner verifies the corresponding evidence, then set the actual effective date. `/support` remains usable and discoverable with the confirmed operator contact, Shantanu Sinha at shantanusinha95@gmail.com. No arbitrary support-email deletion deadline or hardware-loss recovery promise is made.

`docs/store-readiness.md` is a historical September audit and contains findings superseded by October work. The current handoff and checks are in `docs/vercel-release-2026-10-06.md`. Public download availability remains coming soon until a consumer App Store link actually works.

The existing Vercel project is `landing` (`prj_osATa26wuWMoLf7yLOEaXvYuiial`). Production deployment `dpl_EMPz5q73ktnuHwhEesBQX4ZjBdhN` was promoted on 6 October and serves `https://landing-ten-theta-55.vercel.app` and `https://thepreviously.vercel.app`. The previous production deployment `dpl_6nzwjys7thtUHrV4pdV8dU4GqLM8` is retained for rollback. `vercel.json` selects Next.js and `npm run build`; leave the project output-directory override unset so the Next builder extracts its framework output correctly. Local Next still exports to `out/`. The package and project pin Node `24.x`.

The release owner subsequently added only the owned `previously` DNS A record, attached `previously.cognipin.com` to this existing project, and assigned it to the same production deployment. Vercel issued its TLS certificate and all eight anonymous custom-domain route probes passed at 12:16 UTC. Evidence: `../docs/qa/2026-10-06/app-store/previously-domain-https.json`. This proves delivery of the existing draft deployment, not publication of the final policy or the local canonical-origin changes.

The existing authenticated CLI verified account `shan2news-projects` has an active Hobby plan on 6 October. No new project, paid plan or DNS change was made. Do not enable a Pro trial, paid integrations, paid analytics or runtime functions. Hobby’s non-commercial use boundary needs to remain true as the product evolves.

Deploy from `landing/` only. `.vercelignore` excludes local credentials, Sites configuration, docs, local `out`/`dist` exports, `.vercel`, and old adapter/tool caches. No backend or iPhone source belongs in the upload. The promoted deployment passed 19 anonymous public browser checks, 16 route checks across both aliases and 33 public asset SHA256 comparisons. Evidence is in `../docs/qa/2026-10-06/landing-release/vercel-production/`. Legal content remains draft; public download availability remains coming soon until the consumer App Store listing resolves.
