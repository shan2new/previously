# Shipping a TestFlight beta

The mechanical steps for getting a build in front of testers, and the reasons behind the
non-obvious ones. Written 3 Sep 2026 for the first beta (v1.0 build 1).

**Bundle IDs** — app `com.cognipin.previously`, widget `com.cognipin.previously.widgets`. Team `YLPZXZS2F4`.
These replaced the original IDs on 2 Oct 2026, so builds 1–6 belong to the old
App Store Connect record. The new IDs need their own App IDs, provisioning profiles and App Store
Connect record (§2) before build 7 can upload.
**Display name** on the phone is `Previously.` (`CFBundleDisplayName`), independent of the App
Store listing name.
**Deployment target** is **iOS 18.0** (see the note at the top of `ios/project.yml` for why 18 and
not 17 or 26), so the beta reaches iPhone XR / XS and later. iOS 26 flourishes are gated, not
removed — `DesignSystem/GlassHelpers.swift`.

## Build with the RELEASE Xcode, not the beta

`xcode-select -p` points at `Xcode-beta.app` (Xcode 27, iOS 27 SDK) for day-to-day work.
**App Store Connect rejects builds made against a beta SDK.** Every archive command below therefore
pins the stable toolchain explicitly:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

Xcode 26.6 ships the iOS 26.5 SDK, which is what an 18.0 deployment target builds against
(`minos 18.0 / sdk 26.5` in the shipped binary). The app no longer ships any Metal shader (the
old splash's `SplashShaders.metal` went with the 4 Sep launch rebuild), so the stable Xcode needs
no Metal toolchain download; if one is ever added back, Xcode 26 stopped bundling `metal` and
needs `xcodebuild -downloadComponent MetalToolchain` once.

**26 Sep 2026:** the machine now has ONE Xcode, `/Applications/Xcode.app` = Xcode 27.0 (27A266a,
iOS 27.0 SDK) — the release that shipped with iOS 27 — and `xcode-select` points at it. Archives are
built with it; if App Store Connect ever answers "built with a beta SDK", this line is wrong and the
release Xcode must be installed before archiving.

## 1. Legal pages — served by the landing site, not the backend

The app's Privacy Policy and Terms URLs point at the **landing site** (`landing/`, deployed to
Vercel), and those pages are already live. Nothing has to be deployed for them.

This reversed the 3 Sep decision, on 7 Sep. The backend used to serve its own copy
(`server/src/routes/legal.ts`, now deleted) so the URLs would sit on the one HTTPS domain the app
already used. Two things were wrong with that once the landing site existed:

- **It put the one URL Apple re-checks on a home Mac mini** behind a Cloudflare tunnel. Apple
  re-fetches the privacy URL after approval, so a dead link is a live-listing compliance problem,
  not just a broken page. Vercel stays up when the mini does not.
- **Two hand-written copies of the same documents drift, and had.** The backend text was dated
  3 September 2026 and read as final; the landing text still labelled itself a working draft.

Verify the pages from anywhere:

```bash
for p in privacy terms support delete-account; do
  printf "%-16s " "/$p"
  curl -s -o /dev/null -w "%{http_code}\n" "https://landing-ten-theta-55.vercel.app/$p"
done   # want 200 four times
```

The landing site is on a **default `vercel.app` URL**. That is fine for the beta; put it on a real
domain before any public listing.

### Does the Mac mini need a deploy?

For the legal pages, no — they no longer live there. Check whether the *app's* server code has
moved at all before assuming a deploy is needed:

```bash
git diff --stat <deployed-commit> -- server/    # empty output = nothing to deploy
```

When it is not empty, deploying means pulling and restarting *on the mini*, not on the laptop —
the laptop's `tsx watch` on :8787 looks deployed and is not:

```bash
# on the Mac mini
cd ~/…/previously && git pull && cd server && npm install && npm run db:migrate
# then restart however the process is supervised (launchd / pm2 / tmux)
```

Either way, confirm production still refuses the dev bearer — `assertAuthConfig` enforces it at
boot, but check the deploy rather than trust it:

```bash
curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer dev:probe" \
  https://anime.cognipin.com/me/library    # want 401
```

## 2. Create the App Store Connect record

Apple's **app name must be globally unique**, and `Previously.` is a common word — expect it to be
taken. The listing name and the name on the home screen are separate, so a listing called
`Previously — TV Tracker` still installs as `Previously.`; only `CFBundleDisplayName` decides the
latter.

In App Store Connect → Apps → **+** :

| Field | Value |
|---|---|
| Platform | iOS |
| Name | `Previously.` (fall back to a qualified variant if taken) |
| Primary language | English (U.S.) |
| Bundle ID | `com.cognipin.previously` |
| SKU | anything private, e.g. `previously-ios-1` |
| User access | Full Access |

If the bundle ID is not in the dropdown, the App ID has not been registered against the paid team
yet — archiving once with `-allowProvisioningUpdates` (step 3) registers it.

## 3. Archive and upload

```bash
cd ios && xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -scheme Previously -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/Previously.xcarchive -allowProvisioningUpdates archive
```

`-allowProvisioningUpdates` is what lets Xcode create the **Apple Distribution** certificate and
the App Store provisioning profiles for both bundle IDs. The machine only had an *Apple
Development* certificate before the first archive.

Then either open `build/Previously.xcarchive` in Xcode's Organizer and use **Distribute App →
App Store Connect**, or export and upload from the CLI:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -exportArchive \
  -archivePath build/Previously.xcarchive -exportOptionsPlist ExportOptions.plist \
  -exportPath build/export -allowProvisioningUpdates
```

**Upload from the CLI with no API key** (26 Sep, build 3): `-exportArchive` with
`ios/ExportOptions-upload.plist` (the same options plus `destination: upload`) exports AND uploads,
authenticating as the Apple ID signed in to Xcode → Settings → Accounts:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -exportArchive \
  -archivePath build/Previously.xcarchive -exportOptionsPlist ExportOptions-upload.plist \
  -exportPath build/upload -allowProvisioningUpdates    # ends "Upload succeeded."
```

**When the CLI says "App Store Connect access for YLPZXZS2F4 is required"** (builds 16 and 18,
15 and 19 Oct — even with the Apple ID signed in to Xcode → Settings → Accounts), upload from the
**Organizer**: copy the archive to `~/Library/Developer/Xcode/Archives/<date>/` (or `open` the
`.xcarchive`), select it, **Distribute App → App Store Connect → Distribute**. The Organizer uses the
same account and uploads; its logs land in `$TMPDIR/Previously_<stamp>.xcdistributionlogs`
(`ContentDelivery.log` ends "UPLOAD SUCCEEDED with no errors" and the delivery UUID).

`xcrun altool --upload-app` is the other CLI path and needs an App Store Connect API key (Users and
Access → Integrations → App Store Connect API → generate, download the `.p8` once).

**Bump `CURRENT_PROJECT_VERSION` in `ios/project.yml` before every upload** — App Store Connect
rejects a build number it has already seen, and `manageAppVersionAndBuildNumber` is deliberately
`false` in `ExportOptions.plist` so nothing edits it behind your back.

### Enrolment went live 7 Sep — this section is history

The paid team was confirmed active on 7 Sep 2026: the portal issued `iOS Team Store Provisioning
Profile` entries for both bundle IDs with **one-year** expiry (`2027-09-07`, against the 7-day
profiles a free personal team had been issuing), created the `Apple Distribution: Shantanu Sinha
(YLPZXZS2F4)` certificate, and `-exportArchive` succeeded. Team ID did not change, so no
`DEVELOPMENT_TEAM` / `teamID` edits were needed.

Two things that look like failures and are not: `TeamName` still reads "Shantanu Sinha" (that is
the individual-enrolment name, not a free-team tell — lifetime is the tell), and
`security find-identity` does not list the distribution cert, because Xcode 26 keeps
automatically-managed identities in the data-protection keychain that the legacy `security` CLI
cannot enumerate. Confirm signing from the artefact instead:

```bash
codesign -dvvv /path/to/Payload/*.app 2>&1 | grep Authority   # want "Apple Distribution: …"
```

Keep the diagnosis below for the next time signing breaks.

### If the export fails with "does not have permission to create iOS App Store profiles"

Seen on the first attempt, 3 Sep, with `No provider associated with App Store Connect user`. It
means the Apple ID is still acting as a **free personal team**, whatever the purchase receipt says.
The tell is profile lifetime: run

```bash
security cms -D -i ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision \
  | plutil -p - | grep -E "TeamName|ExpirationDate"
```

A free personal team issues **7-day** profiles; a paid team issues **one-year** ones. Check, in
order:

1. **Is enrolment actually active?** developer.apple.com/account → Membership details. Payment
   taken is not the same as activated — individual enrolments typically take 24–48 h and can need
   ID verification.
2. **Is the Program License Agreement accepted?** The commonest cause. Until the Account Holder
   accepts it, App Store Connect reports no provider and distribution is blocked entirely.
   developer.apple.com/account → Agreements, or the banner in App Store Connect.
3. **Is Xcode's session stale?** Xcode → Settings → Accounts → sign out and back in, then
   *Download Manual Profiles*. A cached personal-team session survives enrolment.
4. **Did enrolment create a NEW team ID?** An Apple ID can hold a personal team *and* a paid one at
   once. If Membership details shows a Team ID other than `YLPZXZS2F4`, update **both**
   `DEVELOPMENT_TEAM` entries in `ios/project.yml` and the `teamID` in `ios/ExportOptions.plist`,
   then `xcodegen generate`.

Nothing else in the pipeline is waiting on this — `archive` already succeeds. Once the membership
is live, `-exportArchive` is one command.

## 4. Testers

**Internal** (up to 100 App Store Connect users): Users and Access → **+** → invite the tester's
Apple ID, role *Developer* or *Marketing*, then TestFlight → Internal Testing → add them to the
group. **No Beta App Review**, available as soon as the build finishes processing (~5–20 min).
This is the fast path for one trusted friend; it does give them some App Store Connect visibility.

**External** (up to 10 000, public link, no ASC access): needs **Beta App Review** on the first
build of a version — roughly a day — plus, in App Information / TestFlight:

- Privacy Policy URL — `https://landing-ten-theta-55.vercel.app/privacy`
- Feedback email — the support address in `project.yml`
- Beta app description and **review notes**. Say plainly that the backend is a self-hosted personal
  server, that sign-in is email-based via Clerk, and that the catalogue comes from AniList/TMDB and
  the app neither hosts nor links to video. Reviewers reject media apps they suspect of piracy;
  pre-empting that costs one sentence.

## Already handled in the repo

Things that bite on a first submission and are done — don't redo them:

- `ITSAppUsesNonExemptEncryption: false` in the Info.plist, so no export-compliance prompt per
  upload. The app's only cryptography is HTTPS via the OS.
- `ios/Resources/PrivacyInfo.xcprivacy` — the privacy manifest. Declares email address, **user
  id** (the Clerk id and, since the feed build, the community handle), **name** (the community
  display name), **other user content** (the library, replies, episode ratings, reports) and
  **product interaction** (likes, saves, reminders, hidden posts and muted shows, blocks, "Not
  interested", and the `last_opened_at` / `prev_opened_at` visit stamps), all linked, all *App
  Functionality*, none for tracking, and `UserDefaults` under reason `CA92.1`. Its comment says
  what is public: display name, handle and reply text; like counts and rating averages only as
  aggregates. Apple diffs this against the App Privacy answers in App Store Connect, so answer
  those to match. **Update it in the same commit as any change to what the app collects.**
- In-app account deletion (guideline 5.1.1(v)) — Profile → Delete account → `DELETE /me`, and the
  same from the suspended-account screen (a banned account may still delete itself and export its
  data; every other route answers it `403 account_suspended`). `DELETE /me` erases every
  user-owned table — the feed's social rows included — in one transaction, and since the feed build
  it then deletes the **Clerk identity** too (`services/erasure.ts`; a suspended identity is banned
  in Clerk instead, so the same email cannot come back for a fresh id). That last step needs
  `CLERK_SECRET_KEY` on the mini (see below): without it the log says `clerk: skipped`, the email
  stays in Clerk, and the person can sign straight back in to an empty account — which is not
  deletion, and blocks a public listing. A failed Clerk call is logged
  (`account.clerk_delete_failed`) and retried with `npm run moderation -- clerk-delete <clerkId>`.
  Profile → Export library → JSON is the account's own copy (`GET /me/export`).
- No entitlements are needed: the Live Activity requires only `NSSupportsLiveActivities`, episode
  alerts are local notifications, and there is no App Group or push certificate.
- The developer sign-in panel is double-gated (`#if DEBUG` **and** `AppConfig.isLocalBackend`), so
  it cannot appear in a TestFlight build even if one were pointed at a local server.
- `qa/` (1.3 GB of capture PNGs) is gitignored.

## Shipping the Today feed build: server first, then TestFlight

The 25 Sep build replaces Today with the feed and adds the social layer and Discover's genres. It
calls routes an older server does not have (`/me/feed`, `/feed/posts/:id`, `/social/*`,
`/me/profile`, `/me/export`, `/discover/genres`), and it needs `POST /me/opened` to keep the
*previous* visit (`users.prev_opened_at`) for "new since your last visit" to be true. So the order
is fixed:

1. **Migrate.** On the mini: pull, `npm install`, `npm run db:migrate` (migration `0010`: the
   social tables, `users.prev_opened_at`, the new notification columns) — before the restart, for
   the reason below.
2. **Restart**, then check the deploy rather than trust it: the boot line
   `{"event":"social.config","commentsEnabled":false}`, and the feed route exists —
   `curl -s -o /dev/null -w "%{http_code}\n" https://anime.cognipin.com/me/feed` answers `401`
   (no token), never `404`.
3. **Only then upload the TestFlight build.** Against a server without `/me/feed` the build does
   not break — Today degrades to the stories tray, one line saying the feed isn't available,
   Suggested and Trending (the client's `unavailable` state) — but a tester reads that as broken.
4. **Production runs with comments OFF**: put `SOCIAL_COMMENTS_ENABLED=0` in the mini's
   `server/.env` explicitly (it is also the default) until the Terms' UGC clause and the
   production Clerk instance have shipped — the next section. With it off the app hides every
   reply and discussion affordance; likes, saves, reminders, hides, ratings and the stories keep
   working.

5. **In the SAME App Store Connect submission as the feed build**, change the answers the manifest
   cannot carry: *App Privacy* adds **Name**, **User ID** (now also the public handle) and
   **Product Interaction**, and widens **Other User Content** (replies and ratings, which other
   users can see), each linked and App Functionality; the *age rating* questionnaire's
   **User-Generated Content** is **Yes**. The build ships the reply surfaces even while
   `SOCIAL_COMMENTS_ENABLED=0`, so these answers go with the build, not with the switch.

The server change is additive for older app builds (TestFlight builds already installed keep
working against the new server), so there is no lockstep: server first, app second, always.

## Shipping the Home build (1.0 build 3, 26 Sep): app only

Home becomes the landing (the departures board: billboard, Recently aired, Up next, This week), the
feed moves to its own tab with SF Pro post words and the X pass, Schedule is pushed from Home, and
the Split-Flap icon and flip launch ship. **No server change**: `git diff --stat fb76a9e -- server/`
is empty and every route the build calls is on production (`/me/feed`, `/discover/genres` answer
401, never 404). So the order is just: archive, export, upload, add the build to the tester group.
App Privacy answers are unchanged (nothing new is collected).

## Shipping build 4 (1.0 build 4, 26 Sep): app only

Schedule is a tab again (Home · Schedule · Feed · Library · Discover), Home's billboard always
offers something you can watch before anything upcoming, posters are chosen by eye on the device
(`PosterPick`) with the show's logo drawn on clean art (dark logos white), the billboard GLOWS
(arrival on the launch's curtain, scroll parallax, tilt, halo), Recently aired is a shelf of DROPS,
and Schedule is LIT (the Tonight card as Home's billboard at card size, faces in their show's colour,
today's countdown, the landing fixed). **No server change** — every route is the one build 3 used —
so again: archive, export + upload, add the build to the tester group. App Privacy is unchanged
(CoreMotion's device attitude, read only while Home's billboard is on screen, needs no prompt and
is never stored or sent).

## Comments stay off until you switch them on

The Today feed's replies and episode discussions are user-generated content, behind the server
switch `SOCIAL_COMMENTS_ENABLED`. **The server's default is off**: the Mac mini's `.env` predates the
feed and has no such key, so deploying the feed build leaves comments off (likes, saves, reminders,
hides and ratings work either way). Every boot logs `{"event":"social.config","commentsEnabled":…}`
— check it after a deploy. Only `.env.example` says `1`, for local work.

Turning comments on in production is a deliberate step, in this order:

1. **The published Terms carry the UGC / EULA clause** — zero tolerance for objectionable content
   and abusive users, removal and bans, the minimum age for posting publicly — and the privacy
   policy lists the new data: update the categories in `landing/lib/legal-content.ts` to name the
   display name, the handle, comments, episode ratings, likes and saves, reports, and what is
   PUBLIC (name, handle and reply text; like counts and rating averages as aggregates), matching
   `PrivacyInfo.xcprivacy`'s comment. The landing pages are still drafts on this; App Review 1.2
   reads them.
2. **The production Clerk instance exists** (see the first risk below): handles and bans key on
   Clerk ids, which do not carry over from the development instance.
3. **The in-app community rules match the Terms.** Whenever their text changes, bump
   `SOCIAL_TERMS_VERSION` (server `.env` and the default in `server/src/env.ts`) so everyone accepts
   the new text before posting again.
4. Set `SOCIAL_COMMENTS_ENABLED=1` in the Mac mini's `server/.env`, restart, and confirm the boot
   line says `"commentsEnabled":true`.

Never set `SOCIAL_RATE_LIMIT_DISABLED` on the mini: with `APP_ENV=production` the server refuses to
boot with it, because the per-user limits are the abuse control App Review expects.

**Migrate before you restart.** The ban check in `authenticate` reads `moderation_bans`; a server
restarted before `npm run db:migrate` cannot read it. It fails OPEN (every request is served as not
suspended and `moderation.ban_cache_unavailable` is logged on each check) rather than answering every
route with a 500 — but until the migration runs, no ban holds. Keep the order in step 1: pull,
install, migrate, then restart.

Before switching comments on, also set on the mini:

- `MODERATION_ALERT_WEBHOOK_URL` — an `https` webhook (a Slack/Discord incoming webhook or any
  endpoint that takes a JSON POST). Unset, reports reach only the server log and the CLI queue.
  The payload is ids and a category — never the comment text, a handle or a Clerk id.
- `CLERK_SECRET_KEY` — without it, `DELETE /me` erases the account's data but cannot delete the
  Clerk sign-in identity (the log says `clerk: skipped`), which the privacy policy promises.

## Moderation runbook (App Review 1.2: act on a report within 24 hours)

There is one operator, so the server pushes instead of waiting to be read: the webhook fires on a
comment's **first** open report, on every **auto-hide** (3 counted reports), and **hourly** while any
report has waited more than 12 hours (`moderation.stale_reports` in the log as well). Check the
queue at least once a day, and whenever an alert arrives:

```bash
cd server
npm run moderation -- list                  # open reports, most-reported first
npm run moderation -- show <commentId>      # the comment, its author (clerk id, ban state), every report
npm run moderation -- hide <commentId>      # remove it: reports resolved as hidden, author + reporters told
npm run moderation -- dismiss <commentId>   # keep it: reports resolved as dismissed, reporters told
npm run moderation -- restore <commentId>   # undo an auto-hide: visible again, count reset, reporters told
npm run moderation -- ban <clerkId|@handle> --reason "…" --hide-comments   # remove the user
npm run moderation -- reset-identity <clerkId|@handle>   # an offensive name or handle, short of a ban
npm run moderation -- clerk-delete <clerkId>             # retry after account.clerk_delete_failed
```

A report or auto-hide log line (`moderation.report`, `moderation.auto_hidden`) carries the author's
Clerk id: if the author deletes their account (which deletes the reports about their comments), the
log is what keeps `ban <clerkId>` possible. Reports from accounts younger than
`SOCIAL_REPORTER_MIN_AGE_HOURS` (24) are queued and alerted but do not count toward the auto-hide.

**App Review notes** (paste into the review notes once comments are on — and check every sentence
against the build you submit first; a claim the reviewer cannot find is a rejection):

> Previously includes user comments on news posts and episode discussions. Before posting, a user
> must accept the community rules (zero tolerance for objectionable content or abusive users). A
> server-side filter refuses blocked terms and links. Every comment has Report and Block in its menu;
> a blocked user's comments disappear in both directions. Three reports hide a comment automatically
> pending review; the operator is alerted on the first report, reviews every report within 24 hours,
> and removes offending users with a ban. The author and the reporters are notified of the outcome.
> Users can contact us from Profile → Support, delete their own comments, and delete their account
> in the app.

## Known beta risks

- **Clerk is on a development instance** (`pk_test_…`). Fine for a handful of testers; it is capped
  and social sign-in uses Clerk's shared OAuth credentials. Moving to production needs a `pk_live_`
  key, CNAMEs on `cognipin.com` and a matching `CLERK_JWT_KEY` on the server — do it before opening
  the beta widely.
- **One self-hosted backend, no redundancy.** If the Mac mini is down the app still opens on its
  offline library cache, but nothing syncs. The Terms say as much.
- **Support contact is a personal Gmail**, and it is published on both legal pages. Consider an
  alias before the listing is public.
