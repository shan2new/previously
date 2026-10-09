import { and, inArray, sql, type SQL } from 'drizzle-orm'
import { db } from '../db/index.js'
import { franchise, franchiseMember, media } from '../db/schema.js'
import type { MediaFetcher } from '../grouping/graph.js'

/** The existing Discover rule; Ecchi, mature ratings and absent facts do not imply this flag. */
export function isExcludedContent(value: {
  isAdult?: unknown
  adult?: unknown
  enrichment?: { isAdult?: unknown } | null
  genres?: unknown
}): boolean {
  return value.isAdult === true || value.adult === true || value.enrichment?.isAdult === true ||
    (Array.isArray(value.genres) && value.genres.includes('Hentai'))
}

export class ContentExcludedError extends Error {
  readonly reason = 'adult_content' as const
  constructor() { super('title excluded by content policy') }
}

const genreArray = (column: SQL): SQL => sql`(case when jsonb_typeof(${column}) = 'array' then ${column} else '[]'::jsonb end)`

/** Consumer visibility only. Ingestion, storage and the owner's export remain intact. */
export function consumerFranchiseConditions(): SQL[] {
  return [
    sql`(${franchise.enrichment} -> 'isAdult') is distinct from 'true'::jsonb`,
    sql`not (${genreArray(sql`${franchise.genres}`)} @> '["Hentai"]'::jsonb)`,
    // Older grouping rows kept only six franchise genres. A known excluded member must not
    // contribute its art merely because Hentai was beyond that old truncated list.
    sql`not exists (
      select 1 from ${franchiseMember} inner join ${media} on ${media.id} = ${franchiseMember.mediaId}
      where ${franchiseMember.franchiseId} = ${franchise.id}
        and ${genreArray(sql`${media.genres}`)} @> '["Hentai"]'::jsonb
    )`,
  ]
}

type Executor = typeof db | Parameters<Parameters<typeof db.transaction>[0]>[0]

export async function consumerFranchiseIds(ids: string[], executor: Executor = db): Promise<Set<string>> {
  if (ids.length === 0) return new Set()
  const rows = await executor.select({ id: franchise.id }).from(franchise)
    .where(and(inArray(franchise.id, [...new Set(ids)]), ...consumerFranchiseConditions()))
  return new Set(rows.map((row) => row.id))
}

/** Reject the requested seed; omit excluded relation nodes without altering the shared fetcher. */
export function consumerAnimeFetcher(seedId: number, fetcher: MediaFetcher): MediaFetcher {
  return async (ids) => {
    const items = await fetcher(ids)
    if (items.some((item) => item.id === seedId && isExcludedContent(item))) throw new ContentExcludedError()
    return items.filter((item) => !isExcludedContent(item))
  }
}
