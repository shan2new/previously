# Previously

An airing-first anime tracker built around **canonical franchises**, not fragmented seasons.

AniList (like MyAnimeList) models every season, movie, OVA and special as a *separate*
entry. Previously groups those back into one canonical anime — using AniList's relation graph
plus an LLM refinement step — so you subscribe **once** and every new season and episode
surfaces under the show you already follow.

## Architecture

```
┌────────────────────────┐      Bearer (Clerk JWT)      ┌─────────────────────────────┐
│  iOS app (SwiftUI,      │  ─────────────────────────▶  │  Node backend (Fastify)     │
│  Liquid Glass, iOS 26)  │                              │  • franchise grouping       │
│  ios/                   │  ◀─────────────────────────  │  • AniList cache + sync     │
└────────────────────────┘        JSON view-models       │  • Clerk auth               │
                                                          │  server/                    │
                                                          └──────────────┬──────────────┘
                                                                         │
                                            ┌────────────────────────────┼───────────────┐
                                            ▼                            ▼               ▼
                                   local Postgres            AniList GraphQL     OpenRouter LLM
                                                             (cached/proxied)   (franchise refine)
```

- **`server/`** — Node + TypeScript (Fastify + Drizzle + Postgres), self-hosted (Mac mini).
  Proxies/caches AniList, groups franchises (relation-graph BFS → LLM refine via OpenRouter),
  runs scheduled sync (node-cron), authenticates users with Clerk, stores each user's library.
- **`ios/`** — pure SwiftUI app on iOS 26 Liquid Glass, generated with XcodeGen. Auth via the
  Clerk iOS SDK. Talks only to the backend.
- **`icon/`** — app icon: layered SVGs + Icon Composer handoff for the iOS 26 layered glass
  icon, plus a rendered `icon-1024.png` fallback already wired into the app.
- **`docs/api-contract.md`** — the REST contract both sides build against.
- **`legacy-web/`** — the original React/Vite web app, kept for reference.

## Run the backend (local)

```bash
cd server
cp .env.example .env          # set DATABASE_URL, Clerk + OpenRouter keys
npm install
createdb previously
npm run db:migrate
npm run dev                   # http://localhost:8787
# seed some trending franchises (optional):
npm run seed -- 60
# group one franchise by AniList media id:
npm run group -- 16498        # Attack on Titan
```

Auth: set `CLERK_JWT_KEY` (PEM) for networkless verification. For local testing without a
real Clerk session, leave `DEV_AUTH_BYPASS=1` and send `Authorization: Bearer dev:<anyId>`.

Grouping: with no `OPENROUTER_API_KEY` (or `GROUPING_LLM_DISABLED=1`) the server uses the
deterministic relation-graph grouping. Add the key to enable LLM-refined grouping.

News research uses the Claude Agent SDK, falling back to the installed `codex` CLI when Claude
hits a quota, fails or times out. Run `codex login` with the server's OS account to enable its
ChatGPT subscription authentication. Codex runs ephemeral, read-only live web research with app
credentials and mutation tools excluded. Both providers share the same fact validation; failed
research preserves existing facts. See `NEWS_CODEX_*` in `server/.env.example` for the executable,
optional model, timeout and disable switch. Leave the model empty to use the CLI's default.

## Run the iOS app

```bash
cd ios
brew install xcodegen
xcodegen generate            # produces Previously.xcodeproj
open Previously.xcodeproj       # build in Xcode 26 (iOS 26 SDK)
```

Set your signing team in Xcode. The Clerk publishable key and `API_BASE_URL` are configured
in `project.yml`. Without a Clerk key the app runs in dev-bypass mode against the local backend.
