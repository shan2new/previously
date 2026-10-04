import { inArray } from 'drizzle-orm'
import type { AniListMedia } from '../anilist/types.js'
import { db } from '../db/index.js'
import { franchise, franchiseMember, media } from '../db/schema.js'
import { env } from '../env.js'
import { makeAniListFetcher, upsertMedia } from '../services/mediaStore.js'
import { basicAniListEnrichment, enqueueFranchiseEnrichment } from '../services/catalogEnrichment.js'
import { upsertCatalogLink } from '../services/catalogLinks.js'
import { stripHtml } from '../util/text.js'
import { expandComponent, type MediaFetcher } from './graph.js'
import {
  DeterministicGrouper,
  groupingTier,
  makeGrouper,
  type GroupedFranchise,
  type GroupingInput,
  type GroupingResult,
  type LlmGrouper,
} from './llm.js'
import { partKindForFormat } from './partKind.js'
import { planAttach, SEASON_RANK } from './attach.js'
import { validateGrouping } from './validate.js'
import { isOptionalPart, partRelationship } from './relationship.js'
import type { ArtworkGallery, FranchiseEnrichment, FranchiseUpcoming } from '../types/api.js'

export interface GroupOptions {
  grouper?: LlmGrouper
  fetcher?: MediaFetcher
  model?: string
  /**
   * false: do not queue the new franchise's catalogue enrichment. For a bulk caller that paces
   * its own AniList reads (history import builds hundreds in a row; the queue's unpaced requests
   * ran AniList's budget out under it). The show page and Search still enrich it on first sight.
   */
  enrich?: boolean
}

export interface GroupOutcome {
  franchiseId: string
  created: boolean
  attached: number // how many new members attached to an existing franchise
}

// Either the pool handle or a transaction handle — lets the persistence helpers run inside
// the create transaction or standalone.
type Executor = typeof db | Parameters<Parameters<typeof db.transaction>[0]>[0]

/**
 * Build (or extend) the canonical franchise that contains `seedId`.
 * - Expands the relation-graph component (caching media as it goes).
 * - If any member already belongs to a franchise, attach the rest as new parts.
 * - Otherwise run the grouper (LLM or deterministic) and persist new franchise(s).
 * Returns the franchise that ends up containing `seedId`.
 */
export async function groupFromSeed(seedId: number, opts: GroupOptions = {}): Promise<GroupOutcome> {
  const fetcher = opts.fetcher ?? makeAniListFetcher()
  const component = await expandComponent(seedId, fetcher)
  if (component.size === 0) throw new Error(`media ${seedId} not found on AniList`)
  return groupKnownComponent(component, seedId, opts)
}

/**
 * Group an already-expanded relation component (skips the network BFS). Lets callers that
 * have expanded many seeds up front dedupe overlapping components and group each one once.
 */
export async function groupKnownComponent(
  component: Map<number, AniListMedia>,
  seedId: number,
  opts: GroupOptions = {},
): Promise<GroupOutcome> {
  const ids = [...component.keys()]

  // Already grouped? Attach any ungrouped members to the existing franchise.
  const existing = await db.select().from(franchiseMember).where(inArray(franchiseMember.mediaId, ids))
  if (existing.length > 0) {
    const outcome = await attachToExisting(existing, component, seedId)
    await ensureAniListOwnerLink(outcome.franchiseId)
    return outcome
  }

  // Fresh grouping. The grouper (LLM/deterministic) can take seconds, so it runs OUTSIDE the
  // transaction — we must not pin a DB connection for its duration.
  const input = buildInput(component)
  const grouper = opts.grouper ?? pickGrouper(input, opts.model)
  // The LLM grouper can fail (provider down, rate limit, malformed response). When it does, fall
  // back to deterministic relation-graph grouping rather than letting the whole component go
  // ungrouped — an ungrouped component has no franchiseMember rows, which makes its media vanish
  // from search results entirely. A degraded (single-franchise) grouping is far better than that.
  let result: GroupingResult
  try {
    result = await grouper.group(input)
    validateGrouping(result, input)
  } catch (err) {
    if (grouper instanceof DeterministicGrouper) throw err // nothing left to fall back to
    console.warn(`grouping LLM failed for seed ${seedId}; using deterministic fallback:`, err)
    result = await new DeterministicGrouper().group(input)
  }
  decoratePartOrder(result, input)

  const outcome = await persistFranchises({
    result,
    seedId,
    allIds: ids,
    metaFor: (f) => {
      const memberIds = f.parts.map((p) => p.id)
      const primary = pickPrimary(memberIds, component)
      const genres = dedupeGenres(memberIds, component)
      return {
        title: f.canonicalName,
        primaryMediaId: primary?.id ?? null,
        cover: primary?.coverImage.extraLarge ?? primary?.coverImage.large ?? null,
        banner: primary?.bannerImage ?? null,
        artwork: primary ? {
          portraits: (primary.coverImage.extraLarge ?? primary.coverImage.large) ? [{
            url: (primary.coverImage.extraLarge ?? primary.coverImage.large)!, source: 'anilist',
            width: null, height: null, language: null, score: null,
          }] : [],
          landscapes: primary.bannerImage ? [{
            url: primary.bannerImage, source: 'anilist', width: null, height: null, language: null, score: null,
          }] : [],
          logos: [],
        } : null,
        description: stripHtml(primary?.description ?? null),
        genres,
        groupingSource: result.model ? 'llm' : 'relations',
        groupingModel: result.model,
        confidence: result.confidence,
        source: 'anilist',
        externalId: null,
        enrichment: basicAniListEnrichment(primary, genres),
      }
    },
    onRaced: (raced, tx) => attachToExisting(raced, component, seedId, tx),
  })
  await ensureAniListOwnerLink(outcome.franchiseId)
  if (opts.enrich !== false) enqueueFranchiseEnrichment(outcome.franchiseId)
  return outcome
}

async function ensureAniListOwnerLink(franchiseId: string): Promise<void> {
  const [row] = await db
    .select({ primaryMediaId: franchise.primaryMediaId })
    .from(franchise)
    .where(inArray(franchise.id, [franchiseId]))
    .limit(1)
  if (row?.primaryMediaId == null) return
  await upsertCatalogLink({
    franchiseId,
    provider: 'anilist',
    mediaType: 'anime',
    externalId: row.primaryMediaId,
    matchMethod: 'catalogue_owner',
    confidence: 1,
  })
}

/** Per-franchise row values supplied by the caller of persistFranchises. */
export interface FranchisePersistMeta {
  title: string
  primaryMediaId: number | null
  cover: string | null
  banner: string | null
  artwork?: ArtworkGallery | null
  description: string | null
  genres: string[]
  groupingSource: string
  groupingModel: string | null
  confidence: number | null
  source: 'anilist' | 'tmdb'
  externalId: number | null
  upcoming?: FranchiseUpcoming | null
  enrichment?: FranchiseEnrichment | null
}

/**
 * Persist a GroupingResult as franchise + member rows, with the create-race handling shared by
 * every source (anime's LLM/deterministic grouping and the deterministic TMDB show path).
 * The grouper/LLM never appears here — callers hand over a finished `result` plus row metadata.
 */
export async function persistFranchises(opts: {
  result: GroupingResult
  seedId: number
  /** Every media id involved — used for the in-transaction race re-check. */
  allIds: number[]
  metaFor: (f: GroupedFranchise) => FranchisePersistMeta
  /** Called when another request grouped (part of) `allIds` first. */
  onRaced: (existing: { mediaId: number; franchiseId: string }[], tx: Executor) => Promise<GroupOutcome>
}): Promise<GroupOutcome> {
  const { result, seedId, allIds } = opts
  try {
    return await db.transaction(async (tx) => {
      // Re-check inside the tx: a concurrent request may have grouped this component while the
      // grouper ran. If so, attach onto the winner rather than creating a duplicate franchise.
      const raced = await tx.select().from(franchiseMember).where(inArray(franchiseMember.mediaId, allIds))
      if (raced.length > 0) return opts.onRaced(raced, tx)

      let seedFranchiseId: string | null = null
      for (const f of result.franchises) {
        const [row] = await tx
          .insert(franchise)
          .values(opts.metaFor(f))
          .returning({ id: franchise.id })

        const fid = row!.id
        // No onConflictDoNothing: a PK collision here means we lost a create race, and we want
        // the whole transaction to roll back (no orphan franchise row) and fall to the catch.
        // Insert in ascending mediaId order so concurrent creates acquire the franchiseMember PK
        // row locks in the same order — removes the lock-cycle deadlock window.
        await tx.insert(franchiseMember).values(
          [...f.parts]
            .sort((a, b) => a.id - b.id)
            .map((p) => ({
              mediaId: p.id,
              franchiseId: fid,
              partKind: p.partKind,
              sequence: p.sequence,
              watchOrder: p.watchOrder ?? p.sequence,
              relationship: p.relationship ?? null,
              optional: p.optional ?? false,
              label: p.label,
            })),
        )
        if (f.parts.some((p) => p.id === seedId)) seedFranchiseId = fid
      }

      if (!seedFranchiseId) throw new Error('grouper did not place the seed media into any franchise')
      return { franchiseId: seedFranchiseId, created: true, attached: 0 }
    })
  } catch (err) {
    // Only a unique-violation (lost create race) is recoverable: another request grouped this
    // component concurrently and our transaction rolled back cleanly (no orphan). Resolve and
    // return the winner. Any other error — including a genuine "seed not placed" bug — is real
    // and must surface, so we rethrow it rather than masking it behind a re-read.
    if ((err as { code?: string })?.code !== '23505') throw err
    const winners = await db.select().from(franchiseMember).where(inArray(franchiseMember.mediaId, allIds))
    if (winners.length > 0) {
      const fid = winners.find((m) => m.mediaId === seedId)?.franchiseId ?? mostCommon(winners.map((m) => m.franchiseId))
      if (fid) return { franchiseId: fid, created: false, attached: 0 }
    }
    throw err
  }
}

/** Resolve the franchise that already owns part of `component` and attach the rest onto it. */
async function attachToExisting(
  existing: { mediaId: number; franchiseId: string }[],
  component: Map<number, AniListMedia>,
  seedId: number,
  exec: Executor = db,
): Promise<GroupOutcome> {
  const seedFranchise = existing.find((m) => m.mediaId === seedId)?.franchiseId
  const targetFranchiseId = seedFranchise ?? mostCommon(existing.map((m) => m.franchiseId))!
  const attached = await attachNewMembers(targetFranchiseId, component, new Set(existing.map((m) => m.mediaId)), exec)
  return { franchiseId: targetFranchiseId, created: false, attached }
}

/** Attach component members not yet grouped onto an existing franchise (new seasons/episodes). */
async function attachNewMembers(
  franchiseId: string,
  component: Map<number, AniListMedia>,
  alreadyMembers: Set<number>,
  exec: Executor = db,
): Promise<number> {
  if (![...component.keys()].some((id) => !alreadyMembers.has(id))) return 0

  // What each new member becomes (its kind, order, relationship and label) is grouping/attach.ts.
  const existingParts = await exec.select().from(franchiseMember).where(inArray(franchiseMember.franchiseId, [franchiseId]))
  const values = planAttach(existingParts, component, alreadyMembers).map((member) => ({ ...member, franchiseId }))
  if (values.length === 0) return 0
  await exec.insert(franchiseMember).values(values).onConflictDoNothing()
  await exec.update(franchise).set({ updatedAt: new Date() }).where(inArray(franchise.id, [franchiseId]))
  return values.length
}

/**
 * Choose the grouper for a freshly-expanded component based on how much it actually needs the
 * model (see groupingTier). Components with no split decision skip the LLM entirely; the rest use
 * the cheap default model, escalating only the genuinely ambiguous multi-side-story cases.
 * An explicit `modelOverride` (e.g. the bulk cron model) is honored for the non-escalate tiers.
 */
function pickGrouper(input: GroupingInput, modelOverride?: string): LlmGrouper {
  const tier = groupingTier(input)
  if (tier === 'deterministic') return new DeterministicGrouper()
  if (tier === 'escalate') return makeGrouper(env.OPENROUTER_MODEL_ESCALATE || modelOverride || env.OPENROUTER_MODEL)
  return makeGrouper(modelOverride ?? env.OPENROUTER_MODEL)
}

function buildInput(component: Map<number, AniListMedia>): GroupingInput {
  const candidates = [...component.values()].map((m) => ({
    id: m.id,
    title: m.title.english || m.title.romaji || `Anime #${m.id}`,
    format: m.format,
    status: m.status,
    seasonYear: m.seasonYear,
    season: m.season,
    episodes: m.episodes,
    synopsis: stripHtml(m.description),
  }))
  const ids = new Set(component.keys())
  const edges = [...component.values()].flatMap((m) =>
    (m.relations?.edges ?? [])
      .filter((e) => e.node.type === 'ANIME' && ids.has(e.node.id))
      .map((e) => ({ from: m.id, to: e.node.id, type: e.relationType })),
  )
  return { candidates, edges }
}

/** Add one global, source-grounded order without asking the grouping model to invent chronology. */
function decoratePartOrder(result: GroupingResult, input: GroupingInput): void {
  const candidates = new Map(input.candidates.map((candidate) => [candidate.id, candidate]))
  for (const grouped of result.franchises) {
    const ids = new Set(grouped.parts.map((part) => part.id))
    const ordered = grouped.parts
      .slice()
      .sort((a, b) => {
        const aa = candidates.get(a.id)
        const bb = candidates.get(b.id)
        const ak = (aa?.seasonYear ?? 9999) * 10 + (SEASON_RANK[aa?.season ?? ''] ?? 0)
        const bk = (bb?.seasonYear ?? 9999) * 10 + (SEASON_RANK[bb?.season ?? ''] ?? 0)
        return ak - bk || a.sequence - b.sequence || a.id - b.id
      })
    // The relations inside THIS franchise only: the model may have split the component.
    const within = input.edges.filter((edge) => ids.has(edge.from) && ids.has(edge.to))
    ordered.forEach((part, index) => {
        // The earliest member is the work's root; every other part is what the edges say it is
        // (grouping/relationship.ts).
        const relationship = index === 0 ? null : partRelationship(part.id, within)
        part.watchOrder = index + 1
        part.relationship = relationship
        part.optional = isOptionalPart(relationship, part.partKind)
      })
  }
}

function pickPrimary(ids: number[], component: Map<number, AniListMedia>): AniListMedia | undefined {
  const members = ids.map((id) => component.get(id)).filter((m): m is AniListMedia => !!m)
  // Prefer the earliest TV season; else most popular.
  const seasons = members
    .filter((m) => partKindForFormat(m.format) === 'season')
    .sort((a, b) => (a.seasonYear ?? 9999) - (b.seasonYear ?? 9999))
  if (seasons[0]) return seasons[0]
  return members.sort((a, b) => (b.popularity ?? 0) - (a.popularity ?? 0))[0]
}

function dedupeGenres(ids: number[], component: Map<number, AniListMedia>): string[] {
  const set = new Set<string>()
  for (const id of ids) for (const g of component.get(id)?.genres ?? []) set.add(g)
  return [...set].slice(0, 6)
}

function mostCommon<T>(arr: T[]): T | undefined {
  const counts = new Map<T, number>()
  let best: T | undefined
  let bestN = 0
  for (const x of arr) {
    const n = (counts.get(x) ?? 0) + 1
    counts.set(x, n)
    if (n > bestN) {
      bestN = n
      best = x
    }
  }
  return best
}

/** Persist freshly-fetched media (used by sync/seed before grouping). */
export async function cacheMedia(items: AniListMedia[]): Promise<void> {
  await upsertMedia(items)
}

// keep `media` import referenced for type-only inference symmetry
export type { AniListMedia }
void media
