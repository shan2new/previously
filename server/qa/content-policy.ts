// Explicit QA only: production routes/auth/services, deterministic provider transport, real PG.
// Never imported by the production server. No external traffic, listener, cron, or worker starts.
import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { writeFile } from 'node:fs/promises'
import { Socket } from 'node:net'
import type { AniListMedia } from '../src/anilist/types.js'
import { syntheticLoadMedia } from './load-provider-stubs.js'

const target = new URL(process.env.DATABASE_URL ?? '')
assert.equal(target.hostname, '127.0.0.1')
assert.match(target.pathname, /^\/previously_qa_content_[a-f0-9]{32}$/)
assert.equal(process.env.DOTENV_CONFIG_PATH, '/dev/null')
assert.equal(process.env.APP_ENV, 'test')
assert.equal(process.env.DEV_AUTH_BYPASS, '1')
for (const key of ['CLERK_SECRET_KEY', 'CLERK_JWT_KEY', 'OPENROUTER_API_KEY', 'CEREBRAS_API_KEY',
  'TMDB_ACCESS_TOKEN', 'ANTHROPIC_API_KEY', 'MODERATION_ALERT_WEBHOOK_URL']) {
  assert.equal(process.env[key], '', `${key} must be explicitly empty`)
}
for (const key of ['GROUPING_LLM_DISABLED', 'SEARCH_CORRECT_DISABLED', 'NEWS_AGENT_DISABLED']) {
  assert.equal(process.env[key], '1')
}
assert.ok(process.env.PREVIOUSLY_QA_RESULTS)
assert.ok(process.env.PREVIOUSLY_OPS_ROOT?.includes(target.pathname.slice(1)))

interface Fixture { id: string; mediaId: number; malId: number; title: string; genres: string[]; adult?: unknown; memberGenres?: string[] }
const definitions: { key: string; title: string; genres: string[]; adult?: unknown; memberGenres?: string[] }[] = [
  { key: 'safe', title: 'QA Normal Show', genres: ['Drama'], adult: false },
  { key: 'ecchi', title: 'QA Ecchi Show', genres: ['Ecchi'], adult: false },
  { key: 'unknown', title: 'QA Unknown Show', genres: ['Drama'], adult: null },
  { key: 'missing', title: 'QA Missing Flag Show', genres: ['Drama'] },
  { key: 'stringFlag', title: 'QA String Flag Show', genres: ['Drama'], adult: 'true' },
  { key: 'flagged', title: 'BLOCKED_ADULT_FLAG_TITLE', genres: ['Drama'], adult: true },
  { key: 'hentai', title: 'BLOCKED_HENTAI_TITLE', genres: ['Hentai'], adult: false },
  { key: 'memberHentai', title: 'BLOCKED_MEMBER_HENTAI_TITLE', genres: ['Drama'], adult: false, memberGenres: ['Drama', 'Hentai'] },
  { key: 'adultTarget', title: 'BLOCKED_STALE_ADULT_RECOMMENDATION', genres: ['Drama'], adult: true },
  { key: 'hentaiTarget', title: 'BLOCKED_STALE_HENTAI_RECOMMENDATION', genres: ['Hentai'], adult: false },
  { key: 'normalTarget', title: 'QA Normal Recommendation', genres: ['Drama'], adult: false },
  { key: 'seedOnlyTarget', title: 'QA Adult Seed Only Recommendation', genres: ['Drama'], adult: false },
  { key: 'late', title: 'BLOCKED_LATE_POLICY_TITLE', genres: ['Drama'], adult: false },
]
const fixtures = Object.fromEntries(definitions.map((item, index) => [item.key, {
  ...item, id: randomUUID(), mediaId: 310_200_000 + index, malId: 910_000 + index,
}])) as Record<string, Fixture>
const get = (key: string) => { const value = fixtures[key]; assert.ok(value); return value }
const allowed = ['safe', 'ecchi', 'unknown', 'missing', 'stringFlag'].map(get)
const excluded = ['flagged', 'hentai', 'memberHentai'].map(get)
const owned = [...allowed, ...excluded]
const pendingIds = { flagged: 310_201_001, hentai: 310_201_002, mixedSafe: 310_201_003, mixedAdult: 310_201_004 }
const pendingMal = { flagged: 911_001, hentai: 911_002, mixedSafe: 911_003 }
const rawRelatedAdultId = 310_299_001
const rawRelatedAdultTitle = 'BLOCKED_UNMATERIALIZED_RELATED_TITLE'
const images = (title: string) => ({ portrait: `https://qa.invalid/${encodeURIComponent(title)}/portrait.jpg`,
  landscape: `https://qa.invalid/${encodeURIComponent(title)}/landscape.jpg` })
const byId = new Map<number, AniListMedia>()
const byMal = new Map<number, number>()
const sourceFacts = new Set<number>()
for (const item of Object.values(fixtures)) {
  const value = syntheticLoadMedia(item.mediaId, item.title)
  value.isAdult = item.adult === true
  value.genres = item.memberGenres ?? item.genres
  value.coverImage.extraLarge = images(item.title).portrait
  value.bannerImage = images(item.title).landscape
  byId.set(item.mediaId, value)
  byMal.set(item.malId, item.mediaId)
}
for (const [key, id] of Object.entries(pendingIds)) {
  const value = syntheticLoadMedia(id, key === 'mixedSafe' ? 'QA Mixed Safe Seed' : `BLOCKED_PENDING_${key.toUpperCase()}_TITLE`)
  value.isAdult = key === 'flagged' || key === 'mixedAdult'
  value.genres = key === 'hentai' ? ['Hentai'] : ['Drama']
  value.coverImage.extraLarge = images(value.title.english!).portrait
  value.bannerImage = images(value.title.english!).landscape
  byId.set(id, value)
}
byMal.set(pendingMal.flagged, pendingIds.flagged)
byMal.set(pendingMal.hentai, pendingIds.hentai)
byMal.set(pendingMal.mixedSafe, pendingIds.mixedSafe)
byId.get(pendingIds.mixedSafe)!.relations = { edges: [{ relationType: 'SEQUEL', node: {
  id: pendingIds.mixedAdult, type: 'ANIME', format: 'TV',
} }] }
const rawRelatedAdult = syntheticLoadMedia(rawRelatedAdultId, rawRelatedAdultTitle)
rawRelatedAdult.isAdult = true
rawRelatedAdult.coverImage.extraLarge = images(rawRelatedAdultTitle).portrait
byId.set(rawRelatedAdultId, rawRelatedAdult)

const transport = { anilistCalls: 0, malMappings: 0, mediaReads: 0, searches: 0,
  blockedFetches: 0, blockedSockets: 0, unsupportedQueries: 0 }
const originalFetch = globalThis.fetch
const providerFetch: typeof globalThis.fetch = async (input, init) => {
  const url = new URL(input instanceof Request ? input.url : String(input))
  if (url.href !== 'https://graphql.anilist.co/') {
    transport.blockedFetches++
    throw new Error('Content QA blocked external fetch')
  }
  transport.anilistCalls++
  const body = init?.body ?? (input instanceof Request ? await input.text() : null)
  assert.equal(typeof body, 'string')
  const { query, variables } = JSON.parse(body as string) as { query: string; variables: Record<string, unknown> }
  const json = (data: unknown) => new Response(JSON.stringify({ data }), { status: 200,
    headers: { 'content-type': 'application/json' } })
  if (/idMal_in/.test(query)) {
    transport.malMappings++
    return json({ Page: { media: (variables.ids as number[]).flatMap(id => {
      const mediaId = byMal.get(id)
      if (mediaId == null) return []
      const facts = byId.get(mediaId)
      return [{ id: mediaId, idMal: id, ...(sourceFacts.has(mediaId) ? { isAdult: facts?.isAdult, genres: facts?.genres } : {}) }]
    }) } })
  }
  if (/MediaListCollection/.test(query)) {
    assert.equal(variables.name, 'qa-explicit-content-list')
    return json({ MediaListCollection: { hasNextChunk: false, lists: [{ isCustomList: false,
      entries: [pendingIds.flagged, pendingIds.hentai, get('safe').mediaId].map(id => ({
        mediaId: id, status: 'CURRENT', progress: 3, media: byId.get(id),
      })),
    }] } })
  }
  if (/media\(search:/.test(query)) {
    transport.searches++
    const needle = String(variables.search ?? '').toLowerCase()
    return json({ Page: { media: [...byId.values()].filter(item => item.title.english?.toLowerCase().includes(needle)).slice(0, 20) } })
  }
  if (/media\(id_in:/.test(query)) {
    transport.mediaReads++
    return json({ Page: { media: (variables.ids as number[]).flatMap(id => byId.has(id) ? [byId.get(id)] : []) } })
  }
  if (/Media\(id:/.test(query)) {
    transport.mediaReads++
    return json({ Media: byId.get(Number(variables.id)) ?? null })
  }
  transport.unsupportedQueries++
  throw new Error('Content QA received unsupported provider operation')
}
globalThis.fetch = providerFetch
const originalConnect = Socket.prototype.connect
Socket.prototype.connect = function (this: Socket, ...args: unknown[]) {
  const value = Array.isArray(args[0]) ? args[0][0] : args[0]
  const options = value && typeof value === 'object' ? value as { host?: string; hostname?: string; path?: string } : null
  const host = options ? options.path ? '[unix-socket-denied]' : options.host ?? options.hostname ?? 'localhost'
    : typeof value === 'number' ? typeof args[1] === 'string' ? args[1] : 'localhost' : '[unsupported-address]'
  if (!['127.0.0.1', 'localhost', '::1'].includes(host)) {
    transport.blockedSockets++
    throw new Error('Content QA blocked external socket')
  }
  return Reflect.apply(originalConnect, this, args)
} as typeof Socket.prototype.connect

async function runtime<T>(name: string): Promise<T> { return import(`../dist/${name}.js`) as Promise<T> }
const { buildServer } = await runtime<typeof import('../src/server.js')>('server')
const { sql } = await runtime<typeof import('../src/db/index.js')>('db/index')
const policy = await runtime<typeof import('../src/services/consumerContent.js')>('services/consumerContent')
const recommendationService = await runtime<typeof import('../src/services/recommendations.js')>('services/recommendations')
const watchAvailability = await runtime<typeof import('../src/services/watchAvailability.js')>('services/watchAvailability')
const enrichmentService = await runtime<typeof import('../src/services/catalogEnrichment.js')>('services/catalogEnrichment')
const app = await buildServer()
const ACCOUNT = 'qa-content-owner'
const IMPORTER = 'qa-content-import-ready'
const LATE_IMPORTER = 'qa-content-import-late'
const PENDING_IMPORTER = 'qa-content-import-pending'
const MIXED_IMPORTER = 'qa-content-import-mixed'
const SOURCE_IMPORTER = 'qa-content-import-source'
const LIST_IMPORTER = 'qa-content-import-list'
const userIds = new Map<string, string>()
const announcementIds = new Map<string, string>()
const cases: { name: string; status: 'passed' | 'failed'; durationMs: number; evidence?: unknown; error?: string }[] = []
const now = new Date()
let fatal: string | undefined
let beforeExport: any
let beforeOwned: unknown
const sleep = (ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms))
async function call(account: string, method: 'GET' | 'POST', url: string, payload?: unknown) {
  const response = await app.inject({ method, url, headers: { authorization: `Bearer dev:${account}` },
    ...(payload === undefined ? {} : { payload }) })
  return { status: response.statusCode, body: response.body ? JSON.parse(response.body) : null }
}
function noExcludedExposure(body: unknown) {
  const text = JSON.stringify(body)
  assert.ok(!text.includes('BLOCKED_'), 'Response exposed excluded title/art/link marker')
}
async function run(name: string, test: () => Promise<unknown> | unknown) {
  const started = performance.now()
  try { cases.push({ name, status: 'passed', evidence: await test(), durationMs: Math.round(performance.now() - started) }) }
  catch (error) { cases.push({ name, status: 'failed', durationMs: Math.round(performance.now() - started),
    error: error instanceof Error ? error.stack ?? error.message : String(error) }) }
  console.log(`${cases.at(-1)!.status.toUpperCase()} ${name}`)
}
async function ownedSnapshot() {
  const userId = userIds.get(ACCOUNT)!
  const tables = ['subscriptions', 'progress', 'watch_sessions', 'notifications', 'saves', 'reminders']
  const values: Record<string, unknown> = {}
  for (const table of tables) values[table] = [...await sql.unsafe(`select row_to_json(t)::text as row from ${table} t where user_id = $1 order by row_to_json(t)::text`, [userId])]
  return values
}
async function pollImport(account: string, id: string) {
  const deadline = Date.now() + 50_000
  while (Date.now() < deadline) {
    const result = await call(account, 'GET', `/me/import/${id}`)
    assert.equal(result.status, 200)
    if (result.body.state === 'done') return result.body
    await sleep(50)
  }
  throw new Error('Import did not settle within owned QA deadline')
}
const malRequest = (items: { malId: number }[]) => ({ source: 'mal', rows: items.map(item => ({ malId: item.malId, status: 'Watching', watched: 3 })) })
function skips(body: any, count: number) {
  assert.deepEqual(body.skipped, { count, reasons: { adult_content: count } })
}
async function seed() {
  const [identity] = await sql`select current_database() as name`
  assert.equal(identity?.name, target.pathname.slice(1))
  const [count] = await sql`select count(*)::int as n from users`
  assert.equal(count?.n, 0, 'Scratch database must be fresh')
  for (const account of [ACCOUNT, IMPORTER, LATE_IMPORTER, PENDING_IMPORTER, MIXED_IMPORTER, SOURCE_IMPORTER, LIST_IMPORTER]) {
    assert.equal((await call(account, 'GET', '/me/profile')).status, 200)
    const [user] = await sql`select id from users where clerk_id = ${account}`
    assert.ok(user)
    userIds.set(account, user.id)
  }
  for (const item of Object.values(fixtures)) {
    const art = images(item.title)
    const value = { level: 'full', themes: ['Drama'], ...(item.adult === undefined ? {} : { isAdult: item.adult }),
      contentRatings: [], people: { creators: [], directors: [], cast: [] }, related: [], videos: [],
      videoFallback: { status: 'disabled', checkedAt: now.toISOString() }, checkedAt: now.toISOString() }
    await sql`insert into media (id,title_english,title_romaji,format,status,episodes,genres,cover,banner,season_year,popularity,trending)
      values (${item.mediaId},${item.title},${item.title},'TV','FINISHED',12,${JSON.stringify(item.memberGenres ?? item.genres)}::jsonb,${art.portrait},${art.landscape},2024,10000,100)`
    await sql`insert into franchise (id,title,primary_media_id,genres,cover,banner,enrichment,grouping_source)
      values (${item.id},${item.title},${item.mediaId},${JSON.stringify(item.genres)}::jsonb,${art.portrait},${art.landscape},${JSON.stringify(value)}::jsonb,'manual')`
    await sql`insert into franchise_member (franchise_id,media_id,part_kind,sequence,watch_order,label)
      values (${item.id},${item.mediaId},'season',1,1,'Season 1')`
    await sql`insert into watch_availability_snapshots (franchise_id,country,status,providers,link,expires_at)
      values (${item.id},'US','available',${JSON.stringify([{ id: 1, name: item.title, logo: art.portrait, access: 'subscription' }])}::jsonb,
      ${`https://qa.invalid/${encodeURIComponent(item.title)}/watch`},${new Date(Date.now() + 86_400_000).toISOString()}::timestamptz)`
  }
  const userId = userIds.get(ACCOUNT)!
  for (const item of owned) {
    await sql`insert into subscriptions (user_id,franchise_id,status) values (${userId},${item.id},'watching')`
    await sql`insert into progress (user_id,media_id,episodes_watched) values (${userId},${item.mediaId},2)`
    const announcement = randomUUID()
    announcementIds.set(item.id, announcement)
    await sql`insert into announcements (id,franchise_id,dedupe_key,status,next,release,note,source)
      values (${announcement},${item.id},'season 2','announced_no_date','Season 2','TBA',${`New chapter of ${item.title}`},'https://qa.invalid/news')`
    await sql`insert into announcement_observations (franchise_id,announcement_id,dedupe_key,status,next,release,note)
      values (${item.id},${announcement},'season 2','announced_no_date','Season 2','TBA',${`New chapter of ${item.title}`})`
    await sql`insert into notifications (user_id,franchise_id,announcement_id,kind,title,body,post_id)
      values (${userId},${item.id},${announcement},'news_announced',${item.title},${`Update for ${item.title}`},${`news:${announcement}`})`
    for (const table of ['saves', 'reminders']) {
      await sql.unsafe(`insert into ${table} (user_id,post_id,franchise_id) values ($1,$2,$3)`, [userId, `news:${announcement}`, item.id])
    }
  }
  await sql`insert into watch_sessions (id,user_id,franchise_id,ordinal,episodes,completed_at)
    values (${randomUUID()},${userId},${get('flagged').id},1,2,${Date.now()})`
  const targets = ['adultTarget', 'hentaiTarget', 'normalTarget', 'seedOnlyTarget'].map(get)
  for (const item of targets) {
    const art = images(item.title)
    await sql`insert into recommendation_targets
      (source,external_id,title,year,images,format,status,episodes,average_score,popularity,genres,is_adult,
       root_id,root_title,root_year,root_format,root_episodes,root_images,member_ids)
      values ('anilist',${item.mediaId},${item.title},2024,${JSON.stringify(art)}::jsonb,'TV','FINISHED',12,85,10000,'["Drama"]'::jsonb,false,
        ${item.mediaId},${item.title},2024,'TV',12,${JSON.stringify(art)}::jsonb,${JSON.stringify([item.mediaId])}::jsonb)`
    const sourceId = item.id === get('seedOnlyTarget').id ? get('flagged').id : get('safe').id
    await sql`insert into recommendation_edges (franchise_id,source,external_id,title,images,rank,votes)
      values (${sourceId},'anilist',${item.mediaId},${item.title},${JSON.stringify(art)}::jsonb,${targets.indexOf(item)},100)`
  }
  // An old stored related card has no local page, but canonical target facts know it is adult.
  await sql`insert into recommendation_targets (source,external_id,title,images,is_adult,root_id,root_title,root_images)
    values ('anilist',${rawRelatedAdultId},${rawRelatedAdultTitle},${JSON.stringify(images(rawRelatedAdultTitle))}::jsonb,true,
      ${rawRelatedAdultId},${rawRelatedAdultTitle},${JSON.stringify(images(rawRelatedAdultTitle))}::jsonb)`
  const related = [...['adultTarget', 'hentaiTarget', 'normalTarget', 'ecchi'].map(get).map(item => ({
    source: 'anilist', externalId: item.mediaId, franchiseId: null, title: item.title, year: 2024, images: images(item.title), score: 100,
  })), { source: 'anilist', externalId: rawRelatedAdultId, franchiseId: null, title: rawRelatedAdultTitle,
    year: 2024, images: images(rawRelatedAdultTitle), score: 90 }]
  await sql`update franchise set enrichment = jsonb_set(enrichment,'{related}',${JSON.stringify(related)}::jsonb) where id = ${get('safe').id}`
  beforeOwned = await ownedSnapshot()
  beforeExport = (await call(ACCOUNT, 'GET', '/me/export')).body
}

try {
  await seed()
  await run('exact policy retains Ecchi and unknown or nonboolean flags', () => {
    for (const item of allowed) assert.equal(policy.isExcludedContent({ enrichment: { isAdult: item.adult }, genres: item.genres }), false)
    assert.equal(policy.isExcludedContent({ isAdult: true }), true)
    assert.equal(policy.isExcludedContent({ adult: true }), true)
    assert.equal(policy.isExcludedContent({ genres: ['Hentai'] }), true)
    return { allowedTitles: allowed.map(item => item.title), exactBooleanOnly: true }
  })
  await run('real SQL visibility excludes adult flag, franchise Hentai and known member Hentai', async () => {
    const ids = await policy.consumerFranchiseIds(owned.map(item => item.id))
    assert.deepEqual([...ids].sort(), allowed.map(item => item.id).sort())
    return { visible: ids.size, excluded: excluded.length }
  })
  for (const item of excluded) {
    await run(`cached detail and direct resolve block ${item.title}`, async () => {
      const detail = await call(ACCOUNT, 'GET', `/franchises/${item.id}`)
      assert.equal(detail.status, 404)
      const resolve = await call(ACCOUNT, 'POST', '/franchises/resolve', { source: 'anilist', externalId: item.mediaId })
      assert.equal(resolve.status, 422)
      noExcludedExposure(detail.body); noExcludedExposure(resolve.body)
      return { detailStatus: detail.status, resolveStatus: resolve.status }
    })
    await run(`cached search blocks ${item.title}`, async () => {
      const response = await call(ACCOUNT, 'GET', `/search?q=${encodeURIComponent(item.title)}`)
      assert.equal(response.status, 200)
      noExcludedExposure(response.body.franchises)
      assert.ok(!response.body.franchises.some((value: any) => value.id === item.id))
      return { results: response.body.franchises.length }
    })
  }
  await run('normal, Ecchi and unknown cached details and search remain available', async () => {
    for (const item of allowed) {
      assert.equal((await call(ACCOUNT, 'GET', `/franchises/${item.id}`)).status, 200)
      const search = await call(ACCOUNT, 'GET', `/search?q=${encodeURIComponent(item.title)}`)
      assert.equal(search.status, 200)
      assert.ok(search.body.franchises.some((value: any) => value.id === item.id))
    }
    return { allowed: allowed.length }
  })
  await run('library omits excluded rows and related art while preserving allowed shows', async () => {
    const response = await call(ACCOUNT, 'GET', '/me/library?country=US')
    assert.equal(response.status, 200)
    noExcludedExposure(response.body)
    assert.deepEqual(response.body.franchises.map((item: any) => item.id).sort(), allowed.map(item => item.id).sort())
    const safe = response.body.franchises.find((item: any) => item.id === get('safe').id)
    assert.ok(safe.related.some((item: any) => item.externalId === get('normalTarget').mediaId))
    assert.ok(safe.related.some((item: any) => item.externalId === get('ecchi').mediaId))
    return { libraryRows: response.body.franchises.length, relatedTitles: safe.related.map((item: any) => item.title) }
  })
  await run('safe detail drops excluded local and known unmaterialized related cards', async () => {
    const response = await call(ACCOUNT, 'GET', `/franchises/${get('safe').id}`)
    assert.equal(response.status, 200)
    noExcludedExposure(response.body)
    assert.ok(response.body.related.some((item: any) => item.externalId === get('normalTarget').mediaId))
    return { related: response.body.related.map((item: any) => item.title) }
  })
  await run('Following feed and individual post detail exclude adult metadata', async () => {
    const feed = await call(ACCOUNT, 'GET', '/me/feed?tab=following')
    assert.equal(feed.status, 200); noExcludedExposure(feed.body)
    assert.ok(feed.body.posts.length > 0, 'Positive control must compose a populated feed')
    for (const item of excluded) {
      assert.equal((await call(ACCOUNT, 'GET', `/feed/posts/${encodeURIComponent(`news:${announcementIds.get(item.id)}`)}`)).status, 404)
    }
    const normal = await call(ACCOUNT, 'GET', `/feed/posts/${encodeURIComponent(`news:${announcementIds.get(get('safe').id)}`)}`)
    assert.equal(normal.status, 200)
    return { followingPosts: feed.body.posts.length, safeDetailStatus: normal.status }
  })
  await run('saved and reminders retain opaque ownership but omit excluded post art and titles', async () => {
    for (const path of ['/me/saved', '/me/reminders']) {
      const response = await call(ACCOUNT, 'GET', path)
      assert.equal(response.status, 200); noExcludedExposure(response.body)
    }
    return { storedRowsRetained: true }
  })
  await run('notifications page and unread badge exclude adult rows consistently', async () => {
    const response = await call(ACCOUNT, 'GET', '/me/notifications?limit=50')
    assert.equal(response.status, 200); noExcludedExposure(response.body)
    assert.equal(response.body.items.length, allowed.length)
    assert.equal(response.body.unread, allowed.length)
    return { visibleNotifications: response.body.items.length, unread: response.body.unread }
  })
  await run('direct and batch watch provider routes refuse excluded IDs with credentials blank', async () => {
    for (const item of excluded) assert.equal((await call(ACCOUNT, 'GET', `/franchises/${item.id}/watch-providers?country=US`)).status, 404)
    const batch = await call(ACCOUNT, 'POST', '/franchises/watch-providers/batch', { country: 'US', franchiseIds: owned.map(item => item.id) })
    assert.equal(batch.status, 200); noExcludedExposure(batch.body)
    assert.deepEqual(batch.body.availability.map((item: any) => item.franchiseId).sort(), allowed.map(item => item.id).sort())
    return { batchAvailableIds: batch.body.availability.length, tmdbCredentialBlank: true }
  })
  await run('snapshot preview service drops stored adult provider art and watch links', async () => {
    const values = await watchAvailability.getAvailabilityPreviews(owned.map(item => item.id), 'US')
    assert.deepEqual([...values.keys()].sort(), allowed.map(item => item.id).sort())
    noExcludedExposure([...values.values()])
    assert.ok(values.get(get('safe').id)?.link?.includes('QA%20Normal'))
    return { returnedSnapshots: values.size }
  })
  await run('recommendations block stale adult target fallback and hidden seed reason titles', async () => {
    const body = await recommendationService.getRecommendations(userIds.get(ACCOUNT)!, 30, { materialise: false })
    noExcludedExposure(body)
    const loaded = await recommendationService.loadRankInput(userIds.get(ACCOUNT)!)
    assert.ok(body.items.some(item => item.franchiseId === get('normalTarget').id), `Positive control recommendation missing: ${JSON.stringify({body, input:loaded.input})}`)
    assert.ok(!body.items.some(item => item.franchiseId === get('seedOnlyTarget').id), 'Hidden adult seed still contributes a recommendation')
    assert.ok(body.items.every(item => item.reason.seeds.every(seed => allowed.some(value => value.id === seed.franchiseId))))
    return { items: body.items.map(item => ({ title: item.title, reason: item.reason })) }
  })
  await run('For you cached cards are rechecked after classification changes', async () => {
    const normal = get('normalTarget')
    const before = await call(ACCOUNT, 'GET', '/me/feed?tab=foryou')
    assert.equal(before.status, 200)
    assert.ok(before.body.trending.some((item: any) => item.id === normal.id), 'Cache positive control missing')
    await sql`update franchise set enrichment = jsonb_set(enrichment,'{isAdult}','true'::jsonb) where id = ${normal.id}`
    try {
      const after = await call(ACCOUNT, 'GET', '/me/feed?tab=foryou')
      assert.equal(after.status, 200)
      assert.ok(!after.body.trending.some((item: any) => item.id === normal.id))
      assert.ok(!after.body.franchises.some((item: any) => item.id === normal.id))
      assert.ok(!after.body.posts.some((item: any) => item.franchiseId === normal.id))
      return { cardPresentBefore: true, cardPresentAfter: false, withinExistingCacheLifetime: true }
    } finally {
      await sql`update franchise set enrichment = jsonb_set(enrichment,'{isAdult}','false'::jsonb) where id = ${normal.id}`
    }
  })
  await run('new AniList related metadata excludes raw adult and Hentai candidates', () => {
    const safe = byId.get(get('safe').mediaId)!
    const candidates = [byId.get(rawRelatedAdultId)!, byId.get(pendingIds.hentai)!, byId.get(get('normalTarget').mediaId)!]
    const payload = { ...safe, recommendations: { nodes: candidates.map((item, index) => ({ rating: 100 - index,
      mediaRecommendation: { ...item, type: 'ANIME', averageScore: 85, meanScore: 85, countryOfOrigin: 'JP', startDate: { year: 2024, month: 1, day: 1 } },
    })) } }
    const value = enrichmentService.aniListFranchiseEnrichment([payload as any], ['Drama'], new Set([safe.id]))
    noExcludedExposure(value.related)
    assert.ok(value.related.some(item => item.externalId === get('normalTarget').mediaId))
    return { related: value.related.map(item => item.title) }
  })
  await run('known ready import excludes blocked entries and reports policy skips separately', async () => {
    const preview = await call(IMPORTER, 'POST', '/me/import/preview', malRequest(owned))
    assert.equal(preview.status, 200)
    assert.equal(preview.body.listed, owned.length); assert.equal(preview.body.ready, allowed.length)
    assert.equal(preview.body.toFetch, 0); skips(preview.body, excluded.length); noExcludedExposure(preview.body.sample)
    const applied = await call(IMPORTER, 'POST', `/me/import/${preview.body.id}/apply`)
    assert.equal(applied.status, 200)
    const finished = await pollImport(IMPORTER, preview.body.id)
    assert.equal(finished.shows, allowed.length); assert.equal(finished.failed, 0); skips(finished, excluded.length)
    const written = await sql`select franchise_id from subscriptions where user_id = ${userIds.get(IMPORTER)!}`
    assert.deepEqual(written.map(row => row.franchise_id).sort(), allowed.map(item => item.id).sort())
    return { preview: preview.body, finished }
  })
  await run('policy change after preview is checked before writes without altering owned history', async () => {
    const late = get('late')
    const preview = await call(LATE_IMPORTER, 'POST', '/me/import/preview', malRequest([late]))
    assert.equal(preview.status, 200); assert.equal(preview.body.ready, 1)
    await sql`update franchise set enrichment = jsonb_set(enrichment,'{isAdult}','true'::jsonb) where id = ${late.id}`
    const applied = await call(LATE_IMPORTER, 'POST', `/me/import/${preview.body.id}/apply`)
    assert.equal(applied.status, 200)
    const finished = await pollImport(LATE_IMPORTER, preview.body.id)
    assert.equal(finished.shows, 0); assert.equal(finished.failed, 0); skips(finished, 1)
    const [membership] = await sql`select count(*)::int as n from subscriptions where user_id = ${userIds.get(LATE_IMPORTER)!}`
    const [marks] = await sql`select count(*)::int as n from progress where user_id = ${userIds.get(LATE_IMPORTER)!}`
    assert.equal(membership?.n, 0); assert.equal(marks?.n, 0)
    return { finished, membershipRows: membership?.n, progressRows: marks?.n }
  })
  await run('pending raw adult and Hentai import settle as policy skips, not failures', async () => {
    const preview = await call(PENDING_IMPORTER, 'POST', '/me/import/preview', malRequest([{ malId: pendingMal.flagged }, { malId: pendingMal.hentai }]))
    assert.equal(preview.status, 200); assert.equal(preview.body.toFetch, 2)
    assert.equal((await call(PENDING_IMPORTER, 'POST', `/me/import/${preview.body.id}/apply`)).status, 200)
    const finished = await pollImport(PENDING_IMPORTER, preview.body.id)
    assert.equal(finished.shows, 0); assert.equal(finished.remaining, 0); assert.equal(finished.failed, 0); skips(finished, 2)
    const [membership] = await sql`select count(*)::int as n from subscriptions where user_id = ${userIds.get(PENDING_IMPORTER)!}`
    const [marks] = await sql`select count(*)::int as n from progress where user_id = ${userIds.get(PENDING_IMPORTER)!}`
    assert.equal(membership?.n, 0); assert.equal(marks?.n, 0)
    return { finished, membershipRows: membership?.n, progressRows: marks?.n }
  })
  await run('mixed safe and raw adult relation component imports safe part without adult art', async () => {
    const preview = await call(MIXED_IMPORTER, 'POST', '/me/import/preview', malRequest([{ malId: pendingMal.mixedSafe }]))
    assert.equal(preview.status, 200); assert.equal(preview.body.toFetch, 1)
    assert.equal((await call(MIXED_IMPORTER, 'POST', `/me/import/${preview.body.id}/apply`)).status, 200)
    const finished = await pollImport(MIXED_IMPORTER, preview.body.id)
    assert.equal(finished.shows, 1); assert.equal(finished.failed, 0); skips(finished, 0)
    const library = await call(MIXED_IMPORTER, 'GET', '/me/library')
    assert.equal(library.status, 200); noExcludedExposure(library.body)
    assert.equal(library.body.franchises.length, 1)
    const parts = await sql`select m.media_id from franchise_member m inner join subscriptions s on s.franchise_id = m.franchise_id
      where s.user_id = ${userIds.get(MIXED_IMPORTER)!}`
    assert.deepEqual(parts.map(row => row.media_id), [pendingIds.mixedSafe])
    return { finished, memberMediaIds: parts.map(row => row.media_id) }
  })
  await run('MAL upstream classification skips source units before materialisation', async () => {
    sourceFacts.add(pendingIds.flagged); sourceFacts.add(pendingIds.hentai)
    const preview = await call(SOURCE_IMPORTER, 'POST', '/me/import/preview', malRequest([{ malId: pendingMal.flagged }, { malId: pendingMal.hentai }]))
    assert.equal(preview.status, 200); assert.equal(preview.body.listed, 2)
    assert.equal(preview.body.ready, 0); assert.equal(preview.body.toFetch, 0); assert.equal(preview.body.unmatched.count, 0)
    skips(preview.body, 2)
    const applied = await call(SOURCE_IMPORTER, 'POST', `/me/import/${preview.body.id}/apply`)
    assert.equal(applied.status, 200); assert.equal(applied.body.shows, 0); assert.equal(applied.body.failed, 0); skips(applied.body, 2)
    const [ownedRows] = await sql`select count(*)::int as n from subscriptions where user_id = ${userIds.get(SOURCE_IMPORTER)!}`
    assert.equal(ownedRows?.n, 0)
    return { preview: preview.body, applied: applied.body }
  })
  await run('AniList list classification preserves listed counts and imports only allowed entries', async () => {
    const preview = await call(LIST_IMPORTER, 'POST', '/me/import/preview', { source: 'anilist', username: 'qa-explicit-content-list' })
    assert.equal(preview.status, 200); assert.equal(preview.body.listed, 3)
    assert.equal(preview.body.ready, 1); assert.equal(preview.body.toFetch, 0); assert.equal(preview.body.unmatched.count, 0)
    skips(preview.body, 2); noExcludedExposure(preview.body.sample)
    const applied = await call(LIST_IMPORTER, 'POST', `/me/import/${preview.body.id}/apply`)
    assert.equal(applied.status, 200); assert.equal(applied.body.shows, 1); assert.equal(applied.body.failed, 0); skips(applied.body, 2)
    const written = await sql`select franchise_id from subscriptions where user_id = ${userIds.get(LIST_IMPORTER)!}`
    assert.deepEqual(written.map(row => row.franchise_id), [get('safe').id])
    return { preview: preview.body, applied: applied.body }
  })
  await run('owner DB memberships, progress, sessions, inbox, saves and reminders remain exact', async () => {
    assert.deepEqual(await ownedSnapshot(), beforeOwned)
    return { rowsAndTimestampsUnchanged: true, tables: ['subscriptions', 'progress', 'watch_sessions', 'notifications', 'saves', 'reminders'] }
  })
  await run('account API export deliberately retains complete owned excluded-title history', async () => {
    const response = await call(ACCOUNT, 'GET', '/me/export')
    assert.equal(response.status, 200)
    const { exportedAt: _beforeTime, ...before } = beforeExport
    const { exportedAt: _afterTime, ...after } = response.body
    assert.deepEqual(after, before)
    for (const item of excluded) assert.ok(response.body.library.subscriptions.some((value: any) => value.franchiseId === item.id && value.title === item.title))
    assert.equal(response.body.library.progress.length, owned.length)
    return { subscriptionRows: response.body.library.subscriptions.length, progressRows: response.body.library.progress.length,
      excludedTitlesRetained: excluded.map(item => item.title) }
  })
  assert.equal(transport.blockedSockets, 0, 'Runtime attempted outbound socket')
  assert.equal(transport.blockedFetches, 0, 'Runtime attempted unsupported external fetch')
  assert.equal(transport.unsupportedQueries, 0, 'Provider fixture did not cover runtime query')
} catch (error) {
  fatal = error instanceof Error ? error.stack ?? error.message : String(error)
} finally {
  await app.close()
  await sql.end({ timeout: 5 })
  globalThis.fetch = originalFetch
  Socket.prototype.connect = originalConnect
  const passed = !fatal && cases.length >= 18 && cases.every(item => item.status === 'passed')
  await writeFile(process.env.PREVIOUSLY_QA_RESULTS!, JSON.stringify({ passed, fatal, database: target.pathname.slice(1),
    transport, boundary: 'Compiled production routes/services with real scratch PG; no listener, credentials, provider traffic or production DB',
    directProviderCacheLimitation: 'TMDB credentials remain blank; direct/batch eligibility and cached snapshot-preview service are tested separately.',
    cases }, null, 2) + '\n')
  process.exitCode = passed ? 0 : 1
}
