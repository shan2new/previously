import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import type { ArtworkSet } from '../types/api.js'
import {
  normTitle,
  rankRecommendations,
  seedEngagement,
  type RankEdge,
  type RankedRecommendation,
  type RankInput,
  type RankSeed,
  type RankTarget,
} from './recommendationRank.js'

// "Recommended for you" is ranked by a PURE function, so the whole policy is asserted here against
// the owner's production library (anonymised: fixtures/reco-owner-library.json) with no database.
// The reference list must stay the approved spike's (reco-spike/rank.py, 20 per show); the served
// list is pinned for one user and day. Both change only on purpose.

const EMPTY: ArtworkSet = { portrait: null, landscape: null }
const USER = '00000000-0000-4000-8000-000000000001'
const DAY = 86_400_000

type RawTarget = Partial<RankTarget> & Pick<RankTarget, 'source' | 'externalId' | 'title'>
interface RawFixture {
  now: number
  seeds: (Partial<RankSeed> & Pick<RankSeed, 'franchiseId' | 'title' | 'source' | 'status'>)[]
  edges: [string, 'anilist' | 'tmdb', number, number, number | null][]
  targets: RawTarget[]
}

/** The fixture omits empty values, and a title that is its own series root omits the root_* copy. */
function loadFixture(): RankInput {
  const raw = JSON.parse(readFileSync(new URL('./fixtures/reco-owner-library.json', import.meta.url), 'utf8')) as RawFixture
  return {
    now: raw.now,
    seeds: raw.seeds.map((seed) => ({
      genres: [],
      watchedEpisodes: 0,
      airedEpisodes: 0,
      airing: false,
      lastActivityAt: 0,
      memberIds: [],
      externalId: null,
      ...seed,
    })),
    edges: raw.edges.map(([seedId, source, externalId, rank, votes]) => ({ seedId, source, externalId, rank, votes })),
    targets: raw.targets.map((t) => {
      const self = t.rootId === undefined
      const base = target({ ...t })
      return {
        ...base,
        rootId: t.rootId ?? t.externalId,
        rootTitle: t.rootTitle ?? t.title,
        rootYear: 'rootYear' in t ? t.rootYear! : self ? base.year : null,
        rootFormat: 'rootFormat' in t ? t.rootFormat! : self ? base.format : null,
        rootEpisodes: 'rootEpisodes' in t ? t.rootEpisodes! : self ? base.episodes : null,
      }
    }),
    feedback: [],
  }
}

function target(t: RawTarget): RankTarget {
  return {
    franchiseId: null,
    year: 2020,
    images: EMPTY,
    format: t.source === 'tmdb' ? 'TV' : 'TV',
    status: t.source === 'tmdb' ? null : 'FINISHED',
    episodes: null,
    averageScore: null,
    voteCount: null,
    popularity: null,
    genres: [],
    isAdult: false,
    countryOfOrigin: null,
    airing: false,
    announced: false,
    releaseDate: null,
    rootId: t.externalId,
    rootTitle: t.title,
    rootYear: null,
    rootFormat: null,
    rootEpisodes: null,
    rootImages: EMPTY,
    memberIds: [],
    worldIds: [],
    ...t,
  }
}

function seed(s: Partial<RankSeed> & Pick<RankSeed, 'franchiseId'>): RankSeed {
  return {
    title: s.franchiseId,
    source: 'anilist',
    status: 'completed',
    genres: ['Action'],
    watchedEpisodes: 12,
    airedEpisodes: 12,
    airing: false,
    lastActivityAt: 0,
    memberIds: [],
    externalId: null,
    ...s,
  }
}

const FIXTURE = loadFixture()
const SEEDS = new Map(FIXTURE.seeds.map((s) => [s.franchiseId, s]))
const rank = (input: RankInput, limit = 12, userId = USER) => rankRecommendations(input, { userId, limit })
const keys = (items: RankedRecommendation[]) => items.map((item) => item.key)
const primary = (item: RankedRecommendation) => item.breakdown.contributions[0]!.franchiseId

/** The honesty rule per reason kind, checked against the seed the reason names. */
function assertHonest(item: RankedRecommendation, seeds: Map<string, RankSeed>): void {
  const { kind, seeds: named, count } = item.reason
  expect(named.length).toBeGreaterThanOrEqual(1)
  expect(named.length).toBeLessThanOrEqual(3)
  expect(count).toBeGreaterThanOrEqual(named.length)
  const positive = new Set(item.breakdown.contributions.filter((c) => c.value > 0).map((c) => c.franchiseId))
  for (const ref of named) {
    const s = seeds.get(ref.franchiseId)
    expect(s, `${item.title} names an unknown show`).toBeDefined()
    // Display titles only: never the "-Subtitle-" wrapper the catalogue carries.
    expect(ref.title).not.toMatch(/ -.*-$/)
    if (kind !== 'world') expect(positive.has(ref.franchiseId), `${item.title} names a show that does not vote for it`).toBe(true)
  }
  const lead = seeds.get(named[0]!.franchiseId)!
  const e = seedEngagement(lead)
  switch (kind) {
    case 'consensus': {
      expect(count).toBe(item.breakdown.nSeeds)
      expect(count).toBeGreaterThanOrEqual(2)
      expect(named).toHaveLength(Math.min(count, 3))
      // Strongest vote first; a Planned show with no progress only leads when nothing else can.
      const quiet = (id: string) => seeds.get(id)!.status === 'planned' && seedEngagement(seeds.get(id)!) < 0.3
      const order = item.breakdown.contributions
        .filter((c) => c.value > 0)
        .map((c) => c.franchiseId)
        .sort((a, b) => Number(quiet(a)) - Number(quiet(b)))
      expect(named.map((ref) => ref.franchiseId)).toEqual(order.slice(0, 3))
      break
    }
    case 'finished':
      expect(lead.status).toBe('completed')
      break
    case 'watching':
      expect(lead.status === 'watching' || (lead.status === 'planned' && e >= 0.3)).toBe(true)
      break
    case 'watched':
      expect(['completed', 'watching', 'dropped']).not.toContain(lead.status)
      expect(e).toBeGreaterThanOrEqual(0.9)
      expect(lead.airing).toBe(false)
      break
    case 'planned':
      expect(['planned', 'paused']).toContain(lead.status)
      break
    case 'world':
      expect(item.breakdown.sameWorld).toBe(lead.franchiseId)
      break
  }
  if (kind !== 'consensus' && kind !== 'world') expect(count).toBe(1)
}

// ---------------------------------------------------------------- the owner's library

// reco-spike/new_top20_d20.json: the approved list (MMR order, no daily rotation) and its scores.
const APPROVED: [string, string, number][] = [
  ['anilist:11061', 'Hunter x Hunter (2011)', 0.7943],
  ['anilist:20', 'Naruto', 0.5652],
  ['anilist:20832', 'Overlord', 0.4675],
  ['tmdb:63210', 'Shadowhunters', 0.2188],
  ['anilist:151801', 'MASHLE: MAGIC AND MUSCLES', 0.3898],
  ['anilist:153288', 'Kaiju No. 8', 0.3096],
  ['anilist:21459', 'My Hero Academia', 0.3657],
  ['anilist:99263', 'The Rising of the Shield Hero', 0.4088],
  ['anilist:101348', 'Vinland Saga', 0.2767],
  ['anilist:21087', 'One-Punch Man', 0.2856],
  ['anilist:116006', 'The God of High School', 0.3322],
  ['anilist:101347', 'Dororo', 0.268],
  ['anilist:130298', 'The Eminence in Shadow', 0.2783],
  ['tmdb:97645', 'Solar Opposites', 0.2089],
  ['anilist:103632', "So I'm a Spider, So What?", 0.2981],
  ['tmdb:202879', 'Star Wars: Skeleton Crew', 0.1961],
  ['anilist:116589', '86 EIGHTY-SIX', 0.2262],
  ['tmdb:62417', 'Emerald City', 0.206],
  ['tmdb:118956', "DOTA: Dragon's Blood", 0.1724],
  ['tmdb:7704', 'Legend of the Seeker', 0.2043],
]

// The served shelf for USER on the fixture's day (23 Sep 2026 UTC): [key, reason kind, named shows, count].
const GOLDEN: [string, string, string[], number][] = [
  ['anilist:20832', 'consensus', ['seed-that-time-i-got-reincarnated-as-a-slime', 'seed-re-monster', 'seed-the-beginning-after-the-end'], 5],
  ['anilist:20', 'consensus', ['seed-black-clover', 'seed-bleach', 'seed-jujutsu-kaisen'], 5],
  ['anilist:11061', 'consensus', ['seed-tower-of-god', 'seed-jujutsu-kaisen', 'seed-mob-psycho-100'], 6],
  ['tmdb:63210', 'consensus', ['seed-the-witcher', 'seed-house-of-the-dragon'], 2],
  ['anilist:151801', 'consensus', ['seed-wistoria-wand-and-sword', 'seed-mob-psycho-100', 'seed-black-clover'], 4],
  ['anilist:21459', 'consensus', ['seed-black-clover', 'seed-demon-slayer-kimetsu-no-yaiba', 'seed-mob-psycho-100'], 4],
  ['anilist:99263', 'consensus', ['seed-that-time-i-got-reincarnated-as-a-slime', 'seed-mushoku-tensei', 'seed-sentenced-to-be-a-hero'], 5],
  ['anilist:153288', 'consensus', ['seed-solo-leveling', 'seed-chainsaw-man', 'seed-attack-on-titan'], 5],
  ['anilist:101348', 'consensus', ['seed-attack-on-titan', 'seed-hells-paradise'], 2],
  ['tmdb:97645', 'consensus', ['seed-rick-and-morty', 'seed-wednesday'], 2],
  ['tmdb:62417', 'consensus', ['seed-game-of-thrones', 'seed-the-witcher', 'seed-house-of-the-dragon'], 3],
  ['tmdb:202879', 'consensus', ['seed-avatar-the-last-airbender', 'seed-percy-jackson-and-the-olympians'], 2],
]

describe("rankRecommendations — the owner's library", () => {
  it('reproduces the approved spike list exactly (reference order, 20 deep)', () => {
    const { items, stats } = rankRecommendations(FIXTURE, { userId: USER, limit: 20, rotation: false })
    expect(items.map((item) => [item.key, item.title])).toEqual(APPROVED.map(([key, title]) => [key, title]))
    items.forEach((item, index) => expect(item.score).toBeCloseTo(APPROVED[index]![2], 3))
    // The spike's junk census at 20 per show: 110 owned, 3 twins, 12 films/OVAs/shorts, 1 JP-animation twin.
    expect(stats.excludedEdges).toEqual({ owned: 110, twin: 3, format: 12, 'jp-animation': 1 })
    expect(stats.tvShare).toBeCloseTo(0.3226, 4)
  })

  it('golden: the served top 12 for one user on one day', () => {
    const { items } = rank(FIXTURE)
    expect(items.map((item) => [item.key, item.reason.kind, item.reason.seeds.map((s) => s.franchiseId), item.reason.count]))
      .toEqual(GOLDEN)
    expect(items[0]!.reason.seeds[0]!.title).toBe('That Time I Got Reincarnated as a Slime')
  })

  it('names shows by their display title', () => {
    const input = structuredClone(FIXTURE)
    const rezero = input.seeds.find((s) => s.title.startsWith('Re:ZERO'))!
    // Make Re:ZERO the only show behind a title, so the reason must name it.
    input.edges.push({ seedId: rezero.franchiseId, source: 'anilist', externalId: 900_001, rank: 0, votes: 5000 })
    input.targets.push(target({ source: 'anilist', externalId: 900_001, title: 'Only Re:ZERO', popularity: 200_000, averageScore: 85 }))
    const item = rankRecommendations(input, { userId: USER, limit: 30, rotation: false }).items.find((i) => i.key === 'anilist:900001')!
    expect(item.reason).toEqual({ kind: 'watching', seeds: [{ franchiseId: rezero.franchiseId, title: 'Re:ZERO' }], count: 1 })
  })

  describe.each([USER, 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee', 'user-with-another-seed'])('invariants for %s', (userId) => {
    const days = Array.from({ length: 7 }, (_, d) => rankRecommendations({ ...FIXTURE, now: FIXTURE.now + d * DAY }, { userId, limit: 12 }))
    const ownedMembers = new Set(FIXTURE.seeds.flatMap((s) => s.memberIds))
    const ownedTitles = new Set(FIXTURE.seeds.map((s) => normTitle(s.title)))

    it('serves 12 distinct series, none owned, twinned, film/OVA/short, unreleased or adult', () => {
      for (const { items } of days) {
        expect(items).toHaveLength(12)
        expect(new Set(keys(items)).size).toBe(12)
        for (const item of items) {
          expect(SEEDS.has(item.franchiseId ?? '')).toBe(false)
          if (item.source === 'anilist') expect(ownedMembers.has(item.externalId)).toBe(false)
          expect(ownedTitles.has(normTitle(item.title))).toBe(false)
          expect(['TV', 'ONA']).toContain(item.format)
          expect(item.title).not.toMatch(/season \d|part \d|cour \d/i)
        }
      }
    })

    it('keeps the TV quota, with a TV title in the first four', () => {
      for (const { items, stats } of days) {
        expect(stats.tvQuota).toBe(4)
        expect(items.filter((item) => item.source === 'tmdb')).toHaveLength(4)
        expect(items.slice(0, 4).some((item) => item.source === 'tmdb')).toBe(true)
      }
    })

    it('lets no show be the main reason for more than two titles, and at most one same-universe title', () => {
      for (const { items } of days) {
        const perSeed = new Map<string, number>()
        for (const item of items) perSeed.set(primary(item), (perSeed.get(primary(item)) ?? 0) + 1)
        expect(Math.max(...perSeed.values())).toBeLessThanOrEqual(2)
        expect(items.filter((item) => item.breakdown.sameWorld).length).toBeLessThanOrEqual(1)
      }
    })

    it('gives every title an honest reason', () => {
      for (const { items } of days) for (const item of items) assertHonest(item, SEEDS)
    })
  })

  it('is deterministic for a user and day, and rotates the visible four day to day', () => {
    const today = rank(FIXTURE)
    expect(rank(structuredClone(FIXTURE))).toEqual(today)
    expect(rankRecommendations({ ...FIXTURE, now: FIXTURE.now + 3_600_000 }, { userId: USER, limit: 12 }).items.map((i) => i.key))
      .toEqual(keys(today.items)) // same UTC day
    const week = Array.from({ length: 7 }, (_, d) => keys(rank({ ...FIXTURE, now: FIXTURE.now + d * DAY }).items))
    expect(new Set(week.map((list) => list.slice(0, 4).join())).size).toBeGreaterThan(1)
    // Rotation reorders a stable shelf rather than replacing it.
    for (let d = 1; d < 7; d++) expect(week[d]!.filter((key) => week[d - 1]!.includes(key)).length).toBeGreaterThanOrEqual(8)
    // Another user gets a different daily arrangement of the same shelf.
    expect(keys(rank(FIXTURE, 12, 'someone-else').items)).not.toEqual(keys(today.items))
  })

  it('drops dismissed and seen titles — by key, or by any id of the series', () => {
    const top = rankRecommendations(FIXTURE, { userId: USER, limit: 20, rotation: false }).items
    const hxh = top[0]!
    const naruto = top[1]!
    expect(naruto.key).toBe('anilist:20')
    // Another entry of Naruto's series (not itself on anyone's list) — as if the client had keyed
    // the title before it was keyed by its root. It still hides the series.
    const sibling = FIXTURE.targets.find((t) => t.externalId === 20)!.memberIds
      .find((id) => id !== 20 && !FIXTURE.targets.some((t) => t.externalId === id))!
    const feedback = [
      { key: hxh.key, kind: 'dismissed' as const },
      { key: `anilist:${sibling}`, kind: 'seen' as const },
    ]
    const after = rankRecommendations({ ...FIXTURE, feedback }, { userId: USER, limit: 20, rotation: false })
    expect(keys(after.items)).not.toContain(hxh.key)
    expect(keys(after.items)).not.toContain(naruto.key)
    expect(after.stats.excludedCandidates.feedback).toBe(2)
  })

  it('never recommends anything when the library is all dropped', () => {
    const input = { ...FIXTURE, seeds: FIXTURE.seeds.map((s) => ({ ...s, status: 'dropped' as const })) }
    expect(rank(input).items).toEqual([])
  })

  describe('the audience (one catalogue only)', () => {
    const both = rank(FIXTURE)

    it('serves an anime viewer anime only — and a FULL list, not the mixed one with its TV cut out', () => {
      const { items, stats } = rankRecommendations(FIXTURE, { userId: USER, limit: 12, source: 'anilist' })
      expect(items).toHaveLength(12)
      expect(items.every((item) => item.source === 'anilist' && item.key.startsWith('anilist:'))).toBe(true)
      expect(new Set(keys(items)).size).toBe(12)
      // The mixed list holds 8 anime titles: filtering it afterwards would have served 8.
      expect(both.items.filter((item) => item.source === 'anilist')).toHaveLength(8)
      expect(stats.tvQuota).toBe(0)
      expect(stats.excludedCandidates.audience).toBeGreaterThan(0)
    })

    it('serves a TV viewer TV only, as many as the library\'s TV shows point at', () => {
      const { items, stats } = rankRecommendations(FIXTURE, { userId: USER, limit: 12, source: 'tmdb' })
      expect(items.length).toBeGreaterThan(both.items.filter((item) => item.source === 'tmdb').length)
      expect(items.every((item) => item.source === 'tmdb' && item.key.startsWith('tmdb:'))).toBe(true)
      expect(new Set(keys(items)).size).toBe(items.length)
      expect(stats.excludedCandidates.audience).toBeGreaterThan(0)
    })

    it('never leaks across the catalogues on any day of the rotation', () => {
      for (const [source, other] of [['anilist', 'tmdb'], ['tmdb', 'anilist']] as const) {
        for (let d = 0; d < 7; d++) {
          const { items } = rankRecommendations({ ...FIXTURE, now: FIXTURE.now + d * DAY }, { userId: USER, limit: 30, source })
          expect(items.length).toBeGreaterThan(0)
          expect(items.some((item) => item.source === other)).toBe(false)
        }
      }
    })

    it('is exactly today\'s list for both: no source, or null', () => {
      expect(rankRecommendations(FIXTURE, { userId: USER, limit: 12, source: null })).toEqual(both)
      expect(rankRecommendations(FIXTURE, { userId: USER, limit: 12, source: undefined })).toEqual(both)
      expect(both.stats.excludedCandidates.audience).toBe(0)
    })

    it('recommends nothing to a TV viewer whose library is all anime', () => {
      const anime = new Set(FIXTURE.seeds.filter((s) => s.source === 'anilist').map((s) => s.franchiseId))
      const input = { ...FIXTURE, seeds: FIXTURE.seeds.filter((s) => anime.has(s.franchiseId)), edges: FIXTURE.edges.filter((e) => anime.has(e.seedId)) }
      expect(rankRecommendations(input, { userId: USER, limit: 12, source: 'tmdb' }).items).toEqual([])
    })
  })

  it('serves no TV and asks for none when the library has no TV shows', () => {
    const anime = new Set(FIXTURE.seeds.filter((s) => s.source === 'anilist').map((s) => s.franchiseId))
    const input = { ...FIXTURE, seeds: FIXTURE.seeds.filter((s) => anime.has(s.franchiseId)), edges: FIXTURE.edges.filter((e) => anime.has(e.seedId)) }
    const { items, stats } = rank(input)
    expect(stats.tvQuota).toBe(0)
    expect(items).toHaveLength(12)
    expect(items.every((item) => item.source === 'anilist')).toBe(true)
  })
})

// ---------------------------------------------------------------- the rules, one at a time

function small(seeds: RankSeed[], edges: RankEdge[], targets: RankTarget[], feedback: RankInput['feedback'] = []): RankInput {
  return { now: Date.UTC(2026, 8, 23, 12), seeds, edges, targets, feedback }
}
const edge = (seedId: string, externalId: number, rank = 0, votes: number | null = 100, source: 'anilist' | 'tmdb' = 'anilist'): RankEdge =>
  ({ seedId, source, externalId, rank, votes })
const hit = (input: RankInput, key: string) =>
  rankRecommendations(input, { userId: USER, limit: 30, rotation: false }).items.find((item) => item.key === key)

describe('rankRecommendations — rules', () => {
  it('ranks a title several shows agree on above one only a single show points at', () => {
    const input = small(
      [seed({ franchiseId: 'a' }), seed({ franchiseId: 'b' }), seed({ franchiseId: 'c' })],
      [edge('a', 1), edge('a', 3, 1), edge('b', 1), edge('b', 4, 1), edge('c', 2), edge('c', 5, 1)],
      [1, 2, 3, 4, 5].map((id) => target({ source: 'anilist', externalId: id, title: `Show ${id}`, popularity: 100_000, averageScore: 75 })),
    )
    const { items } = rankRecommendations(input, { userId: USER, limit: 5, rotation: false })
    expect(items[0]!.key).toBe('anilist:1')
    expect(items[0]!.reason).toMatchObject({ kind: 'consensus', count: 2 })
    expect(items[0]!.score).toBeGreaterThan(items.find((i) => i.key === 'anilist:2')!.score * 2)
  })

  it('halves a show that was the main reason for three dismissed titles', () => {
    const input = small(
      [seed({ franchiseId: 'noisy' }), seed({ franchiseId: 'quiet' })],
      [1, 2, 3, 4].map((id, i) => edge('noisy', id, i)).concat([edge('quiet', 4), edge('quiet', 5, 1)]),
      [1, 2, 3, 4, 5].map((id) => target({ source: 'anilist', externalId: id, title: `Show ${id}` })),
    )
    const share = (result: ReturnType<typeof rankRecommendations>) =>
      result.items.find((i) => i.key === 'anilist:4')!.breakdown.contributions.find((c) => c.franchiseId === 'noisy')!.value
    const before = rankRecommendations(input, { userId: USER, limit: 10, rotation: false })
    const twice = rankRecommendations({ ...input, feedback: [1, 2].map((id) => ({ key: `anilist:${id}`, kind: 'dismissed' as const })) }, { userId: USER, limit: 10, rotation: false })
    expect(twice.stats.penalisedSeeds).toEqual([])
    const thrice = rankRecommendations({ ...input, feedback: [1, 2, 3].map((id) => ({ key: `anilist:${id}`, kind: 'dismissed' as const })) }, { userId: USER, limit: 10, rotation: false })
    expect(thrice.stats.penalisedSeeds).toEqual(['noisy'])
    expect(keys(thrice.items)).toEqual(expect.arrayContaining(['anilist:4', 'anilist:5']))
    expect(keys(thrice.items)).not.toContain('anilist:1')
    expect(share(thrice)).toBeCloseTo(share(before) / 2, 9)
  })

  it('drops a title only a dropped show points at, and lets a dropped show pull a shared one down', () => {
    const input = small(
      [seed({ franchiseId: 'liked' }), seed({ franchiseId: 'hated', status: 'dropped' })],
      [edge('liked', 1), edge('liked', 3, 1), edge('hated', 1), edge('hated', 2, 1)],
      [1, 2, 3].map((id) => target({ source: 'anilist', externalId: id, title: `Show ${id}` })),
    )
    const { items, stats } = rankRecommendations(input, { userId: USER, limit: 10, rotation: false })
    expect(keys(items)).not.toContain('anilist:2')
    expect(stats.excludedCandidates.unsupported).toBe(1)
    const shared = items.find((i) => i.key === 'anilist:1')!
    expect(shared.breakdown.nSeeds).toBe(1)
    expect(shared.breakdown.cf).toBeLessThan(shared.breakdown.contributions[0]!.value)
    expect(shared.reason.seeds.map((s) => s.franchiseId)).toEqual(['liked'])
  })

  it('serves series only: never films, OVAs, specials, music, TV shorts, unreleased, adult or hentai', () => {
    const bad: Partial<RankTarget>[] = [
      { format: 'MOVIE' }, { format: 'OVA' }, { format: 'SPECIAL' }, { format: 'MUSIC' }, { format: 'TV_SHORT' },
      { status: 'NOT_YET_RELEASED' }, { status: 'CANCELLED' }, { isAdult: true }, { genres: ['Hentai'] },
    ]
    const input = small(
      [seed({ franchiseId: 'a' })],
      [...bad.map((_, i) => edge('a', 10 + i, i)), edge('a', 99, bad.length)],
      [...bad.map((t, i) => target({ source: 'anilist', externalId: 10 + i, title: `Bad ${i}`, ...t })),
        target({ source: 'anilist', externalId: 99, title: 'Fine', status: 'HIATUS', format: 'ONA' })],
    )
    const { items, stats } = rankRecommendations(input, { userId: USER, limit: 30, rotation: false })
    expect(keys(items)).toEqual(['anilist:99'])
    expect(stats.excludedEdges).toEqual({ format: 5, unreleased: 2, adult: 2 })
  })

  it('merges seasons of one series under its root and never serves a season of an owned show', () => {
    const input = small(
      [seed({ franchiseId: 'a' }), seed({ franchiseId: 'b' }), seed({ franchiseId: 'mine', memberIds: [700, 701] })],
      [edge('a', 501), edge('b', 504), edge('a', 702, 1)],
      [
        target({ source: 'anilist', externalId: 501, title: 'Hero Academy', rootId: 501, rootTitle: 'Hero Academy', memberIds: [501, 502] }),
        target({ source: 'anilist', externalId: 504, title: 'Hero Academy Season 4', rootId: 501, rootTitle: 'Hero Academy', memberIds: [503, 504] }),
        // A later season whose series the user already follows: its walk reached an owned id.
        target({ source: 'anilist', externalId: 702, title: 'Mine Season 3', rootId: 700, rootTitle: 'Mine', memberIds: [701, 702] }),
      ],
    )
    const { items } = rankRecommendations(input, { userId: USER, limit: 10, rotation: false })
    expect(items.map((i) => [i.key, i.title])).toEqual([['anilist:501', 'Hero Academy']])
    expect(items[0]!.reason).toMatchObject({ kind: 'consensus', count: 2 })
  })

  it('drops normalised-title twins across sources (the anime of a live-action show you have)', () => {
    const input = small(
      [seed({ franchiseId: 'live', title: 'ONE PIECE', source: 'tmdb', externalId: 111110 }), seed({ franchiseId: 'a' })],
      [edge('a', 21), edge('a', 22, 1)],
      [target({ source: 'anilist', externalId: 21, title: 'One Piece' }), target({ source: 'anilist', externalId: 22, title: 'Other' })],
    )
    expect(keys(rankRecommendations(input, { userId: USER, limit: 10, rotation: false }).items)).toEqual(['anilist:22'])
  })

  it('reads TV quality from TMDB votes, and drops JP animation, reality/talk/news/soap, unreleased and owned TV', () => {
    const tv = (id: number, t: Partial<RankTarget> = {}) =>
      target({ source: 'tmdb', externalId: id, title: `TV ${id}`, year: 2022, releaseDate: '2022-05-01', genres: ['Drama'], averageScore: 80, voteCount: 2000, popularity: 90, ...t })
    const ids = [1, 2, 3, 4, 5, 1399, 7, 8]
    const input = small(
      [
        seed({ franchiseId: 'got', title: 'Game of Thrones', source: 'tmdb', externalId: 1399, genres: ['Sci-Fi & Fantasy', 'Drama'] }),
        // One show behind each title, so the per-show cap does not decide what is served.
        ...ids.map((id) => seed({ franchiseId: `fan-${id}`, title: `Fan ${id}`, source: 'tmdb', externalId: 5000 + id, genres: ['Drama'] })),
      ],
      ids.map((id) => edge(`fan-${id}`, id, 0, null, 'tmdb')),
      [
        tv(1),
        tv(2, { averageScore: 95, voteCount: 3 }), // few votes: shrunk to the prior
        tv(3, { genres: ['Animation', 'Action & Adventure'], countryOfOrigin: 'JP' }),
        tv(4, { genres: ['Reality'] }),
        tv(5, { releaseDate: '2027-01-10', year: 2027 }),
        tv(1399), // the show itself, by TMDB id
        tv(7, { voteCount: null, averageScore: null, year: 2004, releaseDate: null }),
        tv(8, { title: 'Game of Thrones: A Knight of the Seven Kingdoms' }),
      ],
    )
    const { items, stats } = rankRecommendations(input, { userId: USER, limit: 10, rotation: false })
    expect(stats.excludedEdges).toEqual({ 'jp-animation': 1, 'tv-genre': 1, unreleased: 1, owned: 1 })
    const one = items.find((i) => i.key === 'tmdb:1')!
    const two = items.find((i) => i.key === 'tmdb:2')!
    expect(one.breakdown.quality).toBeCloseTo((((2000 * 80 + 200 * 68) / 2200) - 55) / 30, 3)
    expect(two.breakdown.quality).toBeLessThan(one.breakdown.quality)
    expect(one.breakdown.era).toBe(1)
    // Unmeasured and old: neutral quality, the era prior stands in.
    expect(items.find((i) => i.key === 'tmdb:7')!.breakdown).toMatchObject({ quality: 0.5, era: 0.85 })
    // Same universe as an owned show: labelled, and at most one on the shelf.
    expect(items.find((i) => i.key === 'tmdb:8')!.reason).toMatchObject({ kind: 'world', seeds: [{ franchiseId: 'got' }] })
    expect(items.every((i) => i.format === 'TV')).toBe(true)
  })

  it('never names a Planned show without progress first when another show qualifies', () => {
    const input = small(
      [
        seed({ franchiseId: 'plan', status: 'planned', watchedEpisodes: 0 }),
        seed({ franchiseId: 'done', status: 'completed' }),
      ],
      [edge('plan', 1, 0, 5000), edge('done', 1, 0, 20), edge('done', 2, 1, 10)],
      [target({ source: 'anilist', externalId: 1, title: 'X' }), target({ source: 'anilist', externalId: 2, title: 'Y' })],
    )
    expect(hit(input, 'anilist:1')!.reason.seeds.map((s) => s.franchiseId)).toEqual(['done', 'plan'])
  })

  it('says what the user did with the one show behind a title', () => {
    const cases: [Partial<RankSeed>, string][] = [
      [{ status: 'completed' }, 'finished'],
      [{ status: 'watching', watchedEpisodes: 3 }, 'watching'],
      [{ status: 'planned', watchedEpisodes: 6 }, 'watching'],
      [{ status: 'planned', watchedEpisodes: 12, airing: false }, 'watched'],
      [{ status: 'paused', watchedEpisodes: 12 }, 'watched'],
      [{ status: 'paused', watchedEpisodes: 2 }, 'planned'],
      [{ status: 'planned', watchedEpisodes: 0 }, 'planned'],
    ]
    for (const [facts, kind] of cases) {
      const input = small(
        [seed({ franchiseId: 's', ...facts })],
        [edge('s', 1)],
        [target({ source: 'anilist', externalId: 1, title: 'X' })],
      )
      expect(hit(input, 'anilist:1')!.reason, JSON.stringify(facts)).toMatchObject({ kind, count: 1 })
    }
  })

  it('keeps a spin-off of an owned show to one slot and labels it', () => {
    const input = small(
      [seed({ franchiseId: 'main', memberIds: [300] }), seed({ franchiseId: 'other' })],
      [edge('other', 1), edge('other', 2, 1), edge('other', 3, 2)],
      [
        target({ source: 'anilist', externalId: 1, title: 'Spin-off A', worldIds: [300] }),
        target({ source: 'anilist', externalId: 2, title: 'Spin-off B', worldIds: [300] }),
        target({ source: 'anilist', externalId: 3, title: 'Unrelated' }),
      ],
    )
    const { items } = rankRecommendations(input, { userId: USER, limit: 10, rotation: false })
    expect(items.filter((i) => i.reason.kind === 'world')).toHaveLength(1)
    expect(items.find((i) => i.reason.kind === 'world')!.reason.seeds[0]!.franchiseId).toBe('main')
    expect(items).toHaveLength(2)
  })

  it('keys and titles a materialised title by its franchise, and passes its id through', () => {
    const input = small(
      [seed({ franchiseId: 'a' })],
      [edge('a', 1)],
      [target({ source: 'anilist', externalId: 1, title: 'Show S2', rootId: 9, rootTitle: 'Show', franchiseId: 'fr-show', rootFormat: 'TV' })],
    )
    expect(hit(input, 'anilist:9')).toMatchObject({ key: 'anilist:9', externalId: 9, title: 'Show', franchiseId: 'fr-show', format: 'TV' })
  })
})
