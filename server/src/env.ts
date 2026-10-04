import 'dotenv/config'
import { z } from 'zod'
import { safeHttpsUrl } from './feed/evidence.js'

// Proper env-boolean: "1"/"true"/"yes"/"on" → true, everything else (incl. "0", "", "false") → false.
// NOTE: z.coerce.boolean() does Boolean(string), so "0" would wrongly become true — don't use it.
const envBool = (def: boolean) =>
  z
    .string()
    .optional()
    .transform((v) => (v == null ? def : ['1', 'true', 'yes', 'on'].includes(v.trim().toLowerCase())))

const schema = z.object({
  // Which deployment this process is. It gates the non-production `dev:` bearer issuer, so an
  // unset APP_ENV is treated as development — the boot guard (auth/authConfig.ts) is what makes a
  // production host fail loudly instead of quietly accepting a dev token.
  APP_ENV: z.enum(['development', 'test', 'production']).default('development'),

  PORT: z.coerce.number().default(8787),
  CORS_ORIGIN: z.string().default('*'),
  DATABASE_URL: z.string().default('postgres://localhost:5432/previously'),

  CLERK_JWT_KEY: z.string().optional(),
  CLERK_SECRET_KEY: z.string().optional(),
  // Accept `Authorization: Bearer dev:<clerkId>`. Read ONLY by auth/authConfig.ts, which refuses
  // it outright when APP_ENV=production. Never branch on this anywhere else.
  DEV_AUTH_BYPASS: envBool(false),

  OPENROUTER_API_KEY: z.string().optional(),
  // Franchise grouping is schema-constrained classification at temperature 0 — a "flash"-tier
  // model handles it as well as a frontier model at a fraction of the price. Flash Lite is the
  // default for the interactive search path and the daily bulk cron; the pricier escalate tier
  // is reserved for the genuinely ambiguous side-story splits (see groupingTier()).
  OPENROUTER_MODEL: z.string().default('google/gemini-3.1-flash-lite'),
  OPENROUTER_MODEL_BULK: z.string().default('google/gemini-3.1-flash-lite'),
  OPENROUTER_MODEL_ESCALATE: z.string().default('anthropic/claude-haiku-4.5'),
  GROUPING_LLM_DISABLED: envBool(false),

  // Cerebras hosts very-fast OpenAI-compatible inference (gpt-oss-120b) at a fraction of
  // frontier-model cost. When set it's the default for BOTH franchise grouping (preferred over
  // OpenRouter) and spell-correcting a search that returned nothing from AniList (AniList ANDs
  // query tokens with no typo tolerance, so one misspelled word zeroes the whole search).
  CEREBRAS_API_KEY: z.string().optional(),
  CEREBRAS_MODEL: z.string().default('gpt-oss-120b'),
  SEARCH_CORRECT_DISABLED: envBool(false),

  TRENDING_SEED_COUNT: z.coerce.number().default(300),

  // Announcement/news research agent (Claude Agent SDK, web tools only). Runs daily over
  // subscribed franchises; writes franchise.upcoming + announcement rows and fans out
  // notifications to subscribers. Auth: rides the machine's Claude Code login (Max
  // subscription) — ANTHROPIC_API_KEY is deliberately stripped from the agent subprocess.
  NEWS_AGENT_DISABLED: envBool(false),
  NEWS_AGENT_MODEL: z.string().optional(), // unset → the Agent SDK's default model
  NEWS_AGENT_MAX_TURNS: z.coerce.number().default(16),
  NEWS_AGENT_TIMEOUT_MS: z.coerce.number().default(300_000),
  // Availability fallback uses the machine's Codex ChatGPT login, never an API key.
  NEWS_CODEX_FALLBACK_ENABLED: envBool(true),
  NEWS_CODEX_COMMAND: z.string().min(1).default('codex'),
  NEWS_CODEX_MODEL: z.string().optional(), // unset → the installed CLI's supported default
  NEWS_CODEX_TIMEOUT_MS: z.coerce.number().int().positive().default(180_000),
  NEWS_MAX_FRANCHISES_PER_RUN: z.coerce.number().default(25),
  NEWS_CHECK_INTERVAL_HOURS: z.coerce.number().default(20),

  // TMDB v4 read access token (Bearer). Powers the general-TV source; when unset, TV
  // search/sync is silently disabled and the app is anime-only (same spirit as
  // GROUPING_LLM_DISABLED: absence degrades, never crashes).
  TMDB_ACCESS_TOKEN: z.string().optional(),

  // Social layer (the Today feed). Comments/replies can be switched off while legal/Clerk launch
  // blockers are open; likes, saves, reminders, ratings keep working. GET /me/feed reports it as
  // capabilities.comments.
  // OFF unless a host says otherwise: a production .env that predates the social build has no such
  // key, and public comments must never switch themselves on with a deploy. `.env.example` sets 1,
  // so a local copy is on; production turns it on explicitly once the published terms carry the
  // UGC clause and the production Clerk instance exists (docs/beta-release.md).
  SOCIAL_COMMENTS_ENABLED: envBool(false),
  // Community-rules version a user must have accepted (POST /me/terms) before posting. Bump it
  // whenever the rules text the app shows changes (ios Copy+Social `rulesItems`), so everyone
  // accepts the new text before posting again.
  SOCIAL_TERMS_VERSION: z.string().min(1).default('2026-09-25.2'),
  SOCIAL_AUTO_HIDE_REPORTS: z.coerce.number().int().min(1).default(3),
  SOCIAL_LIKE_NOTIFY_COOLDOWN_MINUTES: z.coerce.number().int().min(0).default(60),
  SOCIAL_BAN_CACHE_SECONDS: z.coerce.number().int().min(0).default(60),
  // A report counts toward the auto-hide threshold only when the reporter's account is at least this
  // old (services/comments.ts `fileReport`): a fresh sign-up cannot hide anyone single-handed.
  // Every report is still stored, logged and alerted. 0 counts every account.
  SOCIAL_REPORTER_MIN_AGE_HOURS: z.coerce.number().int().min(0).default(24),
  // Where report alerts go (services/moderationAlert.ts): an https webhook (a Slack/Discord incoming
  // hook, ntfy…). Unset or empty = the server log only. Anything but a plain https URL refuses to
  // boot. The payload carries no comment text and no handle — only ids, the reason and the CLI line.
  MODERATION_ALERT_WEBHOOK_URL: z
    .string()
    .optional()
    .transform((v) => (v == null || v.trim() === '' ? undefined : v.trim()))
    .refine((v) => v === undefined || safeHttpsUrl(v) != null, {
      message: 'MODERATION_ALERT_WEBHOOK_URL must be a plain https URL',
    }),
  // Per-user, in-process rate limits (util/rateLimit.ts). Keyed on the Clerk id (the identity, which
  // outlives a deleted-and-recreated users row), never the IP. Disabling them is for local work
  // only: a production process with it set refuses to boot (socialConfig.ts).
  SOCIAL_RATE_LIMIT_DISABLED: envBool(false),
  SOCIAL_RATE_COMMENTS_PER_MINUTE: z.coerce.number().int().min(1).default(5),
  SOCIAL_RATE_COMMENTS_PER_HOUR: z.coerce.number().int().min(1).default(60),
  SOCIAL_RATE_TOGGLES_PER_MINUTE: z.coerce.number().int().min(1).default(120),
  SOCIAL_RATE_REPORTS_PER_HOUR: z.coerce.number().int().min(1).default(20),
  SOCIAL_RATE_BLOCKS_PER_HOUR: z.coerce.number().int().min(1).default(30),
  SOCIAL_RATE_PROFILE_PER_DAY: z.coerce.number().int().min(1).default(10),
  SOCIAL_RATE_EXPORTS_PER_HOUR: z.coerce.number().int().min(1).default(3),
  // An account younger than a day gets this hourly comment budget instead of the full one, so a
  // throwaway sign-up buys little flooding (the per-minute rule still applies).
  SOCIAL_RATE_NEW_COMMENTS_PER_HOUR: z.coerce.number().int().min(1).default(10),
  // Refusals are not free: every 422 from POST /social/comments or PUT /me/profile spends one, and
  // once they are spent the answer is 429 — the content filter cannot be probed at full speed.
  SOCIAL_RATE_REJECTED_PER_HOUR: z.coerce.number().int().min(1).default(20),
  // The heavy reads: GET /me/feed, GET /social/comments, GET /feed/posts/:id.
  SOCIAL_RATE_READS_PER_MINUTE: z.coerce.number().int().min(1).default(120),
})

/** The env schema itself, so `env.test.ts` can hold `.env.example` to every key it declares. */
export const envSchema = schema

export const env = schema.parse(process.env)
export type Env = z.infer<typeof schema>
