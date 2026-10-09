import os from 'node:os'
import { query } from '@anthropic-ai/claude-agent-sdk'
import { z } from 'zod'
import { env } from '../env.js'
import type { FranchiseUpcoming, MediaSource } from '../types/api.js'
import { safeHttpsUrl, sanitizeEvidence } from '../feed/evidence.js'
import { parseReleaseWindow } from '../services/releaseWindow.js'
import { isCatalogueUpcoming, releaseWindowEnd } from '../services/catalogUpcoming.js'
import { researchWithCodex } from './codex.js'

export const UPCOMING_STATUSES = [
  'airing',
  'upcoming_dated',
  'announced',
  'announced_no_date',
  'recently_aired',
  'rumored',
  'concluded',
  'unknown',
] as const

const newsResultSchema = z.object({
  installmentScope: z.enum(['same_series', 'separate_series', 'none']),
  status: z.enum(UPCOMING_STATUSES),
  next: z.string(),
  release: z.string(),
  note: z.string().nullable(),
  source: z.string().nullable(),
  evidence: z.array(z.object({
    url: z.string().url(),
    publisher: z.string().nullable(),
    publishedAt: z.string().nullable(),
    tier: z.enum(['official', 'trade', 'reputable', 'catalogue', 'unknown']),
    primary: z.boolean(),
  })).max(5),
})

// Research must establish identity before it can change a show's status. Scope is an internal
// validation field, not part of the stored/public news contract.
export type NewsResult = Omit<z.infer<typeof newsResultSchema>, 'installmentScope'>

export function parseNewsResult(raw: unknown, nowMs = Date.now()): NewsResult | null {
  const parsed = newsResultSchema.safeParse(raw)
  if (!parsed.success) return null
  const { installmentScope, ...result } = parsed.data
  if (result.status === 'unknown') return null
  const hasNext = !['concluded', 'recently_aired'].includes(result.status)
  // A separate show's announcement proves nothing about whether this one will return or end.
  // Reject it rather than manufacturing a conclusion or publishing it under the wrong title.
  if (installmentScope !== (hasNext ? 'same_series' : 'none')) return null
  if (hasNext !== (result.next.trim().length > 0)) return null
  // A syntactically valid JSON object is not evidence. Require a safe source actually included
  // in the supplied evidence, and reject unsupported precision and already-expired future dates.
  const evidence = sanitizeEvidence(result.evidence)
  const primarySource = evidence.find(e => e.url === result.source)
  if (!safeHttpsUrl(result.source) || !primarySource || primarySource.tier === 'unknown') return null
  // A fan wiki is not one of our catalogue providers, even when the model calls it "catalogue".
  if (primarySource.tier === 'catalogue' && !isCatalogueUpcoming(result)) return null
  const window = parseReleaseWindow(result.release)
  if (result.status === 'upcoming_dated' && window.precision !== 'day') return null
  if (result.status === 'announced' && window.precision === 'unknown') return null
  if (result.status === 'announced_no_date' && window.precision !== 'unknown') return null
  if (['announced', 'upcoming_dated'].includes(result.status) && (releaseWindowEnd(result.release) ?? Infinity) <= nowMs) return null
  return { ...result, next: result.next.trim(), evidence }
}

// Raw JSON Schema for the SDK's structured-output enforcement (kept explicit rather than
// derived so the wire contract is visible at a glance).
const NEWS_JSON_SCHEMA = {
  type: 'object',
  properties: {
    installmentScope: { type: 'string', enum: ['same_series', 'separate_series', 'none'] },
    status: { type: 'string', enum: [...UPCOMING_STATUSES] },
    next: { type: 'string' },
    release: { type: 'string' },
    note: { type: ['string', 'null'] },
    source: { type: ['string', 'null'] },
    evidence: {
      type: 'array',
      maxItems: 5,
      items: {
        type: 'object',
        properties: {
          url: { type: 'string' },
          publisher: { type: ['string', 'null'] },
          publishedAt: { type: ['string', 'null'] },
          tier: { type: 'string', enum: ['official', 'trade', 'reputable', 'catalogue', 'unknown'] },
          primary: { type: 'boolean' },
        },
        required: ['url', 'publisher', 'publishedAt', 'tier', 'primary'],
        additionalProperties: false,
      },
    },
  },
  required: ['installmentScope', 'status', 'next', 'release', 'note', 'source', 'evidence'],
  additionalProperties: false,
} as const

export interface NewsResearchInput {
  title: string
  /** Selects source-appropriate language and authorities for anime versus general television. */
  catalogueSource: MediaSource
  catalogueUrl?: string | null
  identityContext?: string | null
  /** Short descriptions of the parts we already track, e.g. "Season 2 (TV, FINISHED, 2024)". */
  knownParts: string[]
  /** What we currently believe (last run's result), if anything. */
  current: FranchiseUpcoming | null
  /** Upcoming installments already recorded, e.g. "Season 4 (announced_no_date)". */
  knownAnnouncements: string[]
}

export function buildNewsPrompt(input: NewsResearchInput): string {
  const parts = input.knownParts.length
    ? input.knownParts.map((p) => `- ${p}`).join('\n')
    : '- (none tracked yet)'
  const current = input.current
    ? `Our current belief (from a previous check on ${input.current.checked ?? 'unknown date'}): status=${input.current.status}, next="${input.current.next}", release="${input.current.release}". Verify whether this is still accurate or has progressed.`
    : 'We have no prior information about upcoming installments.'
  const known = input.knownAnnouncements.length
    ? `\nUpcoming installments we already recorded (unverified prior beliefs):\n${input.knownAnnouncements.map((a) => `- ${a}`).join('\n')}\nOnly if an entry belongs to this series and is still accurate, reuse EXACTLY the same name in \`next\`. Correct prior mistakes; do not preserve a separate show's name.`
    : ''

  const subject = input.catalogueSource === 'tmdb' ? 'television series' : 'anime franchise'
  const task =
    input.catalogueSource === 'tmdb'
      ? 'Search the web for the latest news about the NEXT installment of this series (new season, continuation, reunion/special, or direct follow-up). Cover official announcements with dates, official renewals without dates, and credible production reports or rumors. Prefer the official streamer/network or production company, then reputable trade publications such as Deadline, Variety, and The Hollywood Reporter. For Netflix titles, prefer Netflix Tudum or About Netflix. Ignore fan speculation and unsourced renewal predictions.'
      : 'Search the web for the latest news about the NEXT installment of this franchise (new season, sequel film, next part/cour, or direct continuation). Cover official announcements with dates, official announcements without dates, and credible production reports or rumors. Prefer the official site or official X/Twitter account, Anime News Network, Crunchyroll News, Natalie, or Oricon. Ignore fan speculation with no sourcing.'

  return `You are researching official news about the ${subject} "${input.title}".
Canonical catalogue identity: ${input.catalogueUrl ?? '(see tracked parts below)'}. Match this exact
adaptation, country and medium; similarly named shows and reboots are not interchangeable.
${input.identityContext ?? ''}

Installments we already track:
${parts}

${current}${known}

Today's date: ${new Date().toISOString().slice(0, 10)}.

Task: ${task}

Scope: research the tracked series itself, not everything in its fictional universe. A separately
titled spin-off, prequel series, sequel series, reboot, or shared-universe show is a separate series;
its announcement does NOT mean the original series is returning. For example, Vought Rising is
not another installment of The Boys. A new season of a spin-off counts only when that spin-off is
itself the tracked title. For anime, direct story continuations (including sequel films and cours)
belong to the tracked story; unrelated side stories do not. A known catalogue row or prior
announcement is context to verify, not permission to report a separate series as this one's next.
If only separate-series news exists, keep researching the tracked series and report its own
concluded/recently_aired state when supported. Never infer that it ended just from finding a spin-off.

Important: "next" means the earliest installment the viewer has not received yet, not an
installment after every row in our catalogue. If Installments we already track contains a
RELEASING or NOT_YET_RELEASED season/film, report and verify that installment first. Do not call a
series concluded merely because that already-catalogued future installment is its announced final
season.

Classify the situation into exactly one status:
- airing: the next installment is currently airing
- upcoming_dated: officially announced with a specific premiere date (day-level)
- announced: officially announced with a coarse release window (a season/quarter/year, e.g. "Fall 2026")
- announced_no_date: officially announced ("in production") with no date or window at all
- rumored: only credible rumors or unconfirmed reports exist
- recently_aired: the latest installment finished within roughly the last 3 months and nothing new is announced
- concluded: the tracked series has explicitly ended or been cancelled, supported by a source
- unknown: no verifiable information found, sources unavailable, or identity cannot be established.
  Absence of a renewal announcement is NOT evidence of cancellation or conclusion.

Field conventions:
- installmentScope: same_series only when the reported next installment continues the tracked
  series/story; separate_series if the finding is actually about another show (it will be rejected);
  none for concluded/recently_aired/unknown, with an empty next. Verify this independently of prior beliefs.
- next: the SHORTEST stable name for the installment. For a numbered TV season use exactly "Season N" (no subtitle), "<subtitle> (movie)" for films, "Final Season Part N" style only when that is the official naming. Empty string when status is recently_aired or concluded.
  Use official numbering, not our internal sequence or the number of catalogue rows. Preserve a
  cour/part designation (for example "Season 3 Part 2"); two cours are not two numbered seasons.
- release: a human-readable date or window ("2027-01-09", "January 2027", "Fall 2026"). "TBA" when unknown.
- note: one short sentence of context (what was announced, by whom, when) or null.
- source: the URL of the single most authoritative source you found, or null.
- evidence: up to 5 sources that directly support the classification. Prefer an official primary
  announcement plus an independent reputable/trade report when both exist. Set tier=official for
  the studio/network/streamer/production account, trade for industry publications, reputable for
  established news outlets, catalogue only for AniList/TMDB, and unknown otherwise. Set primary
  true only for the original announcement. Include source in this list. Open and read the supporting
  page, verify the claimed installment and date, and do not invent URLs or publication dates.
  Never include search-result pages or fan speculation. A broken/unreadable source is not proof.`
}

// The agent subprocess resolves credentials like Claude Code: an ANTHROPIC_API_KEY in its
// environment takes precedence over the machine's Claude Code (subscription) login. The
// server's .env carries an API key, so strip it here — news research rides the subscription,
// not metered API billing.
function subprocessEnv(): Record<string, string> {
  const out: Record<string, string> = {}
  for (const [k, v] of Object.entries(process.env)) {
    if (v != null && k !== 'ANTHROPIC_API_KEY') out[k] = v
  }
  return out
}

/**
 * Try Claude first, then Codex on provider unavailability. A completed research response
 * rejected by validation is terminal: another model must not bypass that decision.
 */
let providerRetryAfter = 0

export async function researchFranchiseNews(input: NewsResearchInput): Promise<NewsResult | null> {
  if (env.NEWS_AGENT_DISABLED) return null
  const prompt = buildNewsPrompt(input)
  const primary = await researchWithClaude(input, prompt)
  if (primary.available) return primary.result
  if (!env.NEWS_CODEX_FALLBACK_ENABLED) return null
  console.log(`[news] "${input.title}": Claude unavailable; trying Codex`)
  const raw = await researchWithCodex(prompt, NEWS_JSON_SCHEMA)
  if (raw == null) return null
  const result = parseNewsResult(raw)
  if (!result) console.warn(`[news] "${input.title}": Codex output failed validation or had no verified information`)
  else console.log(`[news] "${input.title}": ${result.status} (Codex)`)
  return result
}

type ResearchAttempt = { available: false } | { available: true; result: NewsResult | null }
async function researchWithClaude(input: NewsResearchInput, prompt: string): Promise<ResearchAttempt> {
  if (Date.now() < providerRetryAfter) return { available: false }
  let q: ReturnType<typeof query> | undefined
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    q = query({
      prompt,
      options: {
        allowedTools: ['WebSearch', 'WebFetch'],
        permissionMode: 'dontAsk',
        outputFormat: { type: 'json_schema', schema: NEWS_JSON_SCHEMA },
        maxTurns: env.NEWS_AGENT_MAX_TURNS,
        ...(env.NEWS_AGENT_MODEL ? { model: env.NEWS_AGENT_MODEL } : {}),
        // Isolated from this repo: no CLAUDE.md / settings / skills, neutral cwd.
        settingSources: [],
        cwd: os.tmpdir(),
        env: subprocessEnv(),
      },
    })

    const stream = q
    const attempt = async (): Promise<ResearchAttempt> => {
      for await (const message of stream) {
        if (message.type !== 'result') continue
        if (message.is_error) {
          // A quota failure can have subtype="success". Do not try every remaining title against
          // the same exhausted account, or mistake it for a research/JSON-validation result.
          if ((message as { api_error_status?: number }).api_error_status === 429) {
            providerRetryAfter = Date.now() + 60 * 60 * 1000
          }
          console.warn('[news] provider research failed')
          return { available: false }
        }
        if (message.subtype === 'success') {
          const raw = (message as { structured_output?: unknown }).structured_output
          const cost = (message as { total_cost_usd?: number }).total_cost_usd
          const result = parseNewsResult(raw)
          if (!result) {
            console.warn(`[news] "${input.title}": structured output failed validation or referred to a separate series`)
            return { available: true, result: null }
          }
          // total_cost_usd is the SDK's token-cost estimate — informational only when the
          // agent runs on subscription auth (no API key in the subprocess env).
          if (cost != null) console.log(`[news] "${input.title}": ${result.status} (~$${cost.toFixed(4)} tokens est.)`)
          return { available: true, result }
        }
        console.warn(`[news] "${input.title}": agent ended with ${message.subtype}`)
        return { available: false }
      }
      return { available: false }
    }
    return await Promise.race([
      attempt(),
      new Promise<ResearchAttempt>(resolve => {
        timer = setTimeout(() => {
          console.warn(`[news] "${input.title}": Claude research timed out`)
          void stream.interrupt().catch(() => {})
          resolve({ available: false })
        }, env.NEWS_AGENT_TIMEOUT_MS)
      }),
    ])
  } catch (err) {
    console.warn(`[news] "${input.title}": agent error:`, 'diagnostic details redacted')
    return { available: false }
  } finally {
    clearTimeout(timer)
    q?.close()
  }
}
