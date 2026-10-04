import { describe, expect, it } from 'vitest'
import type { ArtworkGallery, ArtworkImage, FeedTime, RecommendationReason } from '../types/api.js'
import {
  FOR_YOU_RANK,
  isSharp,
  rankForYou,
  recency,
  tasteMatch,
  tasteProfile,
  type ForYouCandidate,
  type ForYouPick,
  type TasteFranchise,
  type TasteSeed,
} from './forYou.js'

// For you's order for one viewer, rule by rule (docs/api-contract.md, "Today feed"). Every fixture
// is built from `NOW`; nothing reads the clock, the database or the recommender.

const D = 86_400_000
const NOW = Date.UTC(2026, 9, 4, 12)

function post(id: string, franchiseId: string, ageDays = 0, flags: Partial<Pick<ForYouCandidate, 'sharp' | 'evergreen'>> = {}): ForYouCandidate {
  const time: FeedTime = { at: NOW - ageDays * D, dateOnly: false, basis: 'observed' }
  return { id, franchiseId, time, sharp: true, ...flags }
}

function seed(genres: string[], overrides: Partial<TasteSeed> = {}): TasteSeed {
  return { source: 'anilist', status: 'completed', genres, watchedEpisodes: 12, airedEpisodes: 12, ...overrides }
}

const show = (genres: string[], source: TasteFranchise['source'] = 'anilist'): TasteFranchise => ({ source, genres })

const because = (title: string): RecommendationReason => ({
  kind: 'finished',
  seeds: [{ franchiseId: 'seed', title }],
  count: 1,
})
const pick = (franchiseId: string, title = 'Frieren'): ForYouPick => ({ franchiseId, reason: because(title) })

/** A library that is all Action and Fantasy. */
const ACTION_FAN = [seed(['Action', 'Fantasy']), seed(['Action'])]

const ids = (posts: readonly { id: string }[]) => posts.map((p) => p.id)

describe('tasteProfile', () => {
  it('weights each show by its status and engagement, and scales the strongest genre to 1', () => {
    const profile = tasteProfile([
      seed(['Action', 'Fantasy']), // completed, a full cour: 1
      seed(['Action'], { status: 'watching', watchedEpisodes: 6 }), // half a cour: 0.5
      seed(['Sci-Fi'], { watchedEpisodes: 0 }), // completed with nothing marked: the 0.3 floor
      seed(['Drama'], { status: 'paused', watchedEpisodes: 0 }), // 0.5
      seed(['Comedy'], { status: 'planned', watchedEpisodes: 0 }), // 0.4
      seed(['Horror'], { status: 'dropped' }), // nothing
    ])

    expect(profile.get('Action')).toBe(1)
    expect(profile.get('Fantasy')).toBeCloseTo(1 / 1.5)
    expect(profile.get('Drama')).toBeCloseTo(0.5 / 1.5)
    expect(profile.get('Comedy')).toBeCloseTo(0.4 / 1.5)
    expect(profile.get('Sci-Fi')).toBeCloseTo(0.3 / 1.5)
    expect(profile.has('Horror')).toBe(false)
  })

  it('reads TV genres in the shared taxonomy', () => {
    const profile = tasteProfile([seed(['Sci-Fi & Fantasy', 'Animation', 'Drama'], { source: 'tmdb' })])

    expect([...profile.keys()]).toEqual(['Sci-Fi', 'Fantasy', 'Drama'])
  })

  it('is empty when the library says nothing', () => {
    expect(tasteProfile([]).size).toBe(0)
    expect(tasteProfile([seed(['Action'], { status: 'dropped' })]).size).toBe(0)
    expect(tasteProfile([seed([])]).size).toBe(0)
  })
})

describe('tasteMatch', () => {
  const profile = new Map([['Action', 1], ['Fantasy', 0.5], ['Drama', 0.2], ['Comedy', 0.1]])

  it('is the mean of the three best-matching genres', () => {
    // Catalogue order is not match order: the best three are Action, Fantasy, Drama.
    const taste = tasteMatch(profile, show(['Comedy', 'Drama', 'Horror', 'Fantasy', 'Action']))

    expect(taste.match).toBeCloseTo((1 + 0.5 + 0.2) / 3)
    expect(taste.genres).toEqual(['Action', 'Fantasy'])
  })

  it('averages over the genres a show has when it has fewer than three', () => {
    expect(tasteMatch(profile, show(['Action'])).match).toBe(1)
    expect(tasteMatch(profile, show(['Action', 'Horror']))).toEqual({ match: 0.5, genres: ['Action'] })
  })

  it('splits a TV show\'s compound genres before matching', () => {
    expect(tasteMatch(profile, show(['Action & Adventure', 'Animation'], 'tmdb'))).toEqual({ match: 0.5, genres: ['Action'] })
  })

  it('is 0 for a show with no genres, or one the caller does not know', () => {
    expect(tasteMatch(profile, show([]))).toEqual({ match: 0, genres: [] })
    expect(tasteMatch(profile, undefined)).toEqual({ match: 0, genres: [] })
  })
})

describe('recency', () => {
  it('halves every 45 days and never exceeds 1', () => {
    expect(recency(NOW, NOW)).toBe(1)
    expect(recency(NOW - 45 * D, NOW)).toBeCloseTo(0.5)
    expect(recency(NOW - 90 * D, NOW)).toBeCloseTo(0.25)
    // News dated ahead of now is as recent as news can be, not more.
    expect(recency(NOW + 5 * D, NOW)).toBe(1)
  })
})

describe('rankForYou: the order', () => {
  it('puts a recommended show above an unrelated trending one of the same age', () => {
    const ranked = rankForYou({
      posts: [post('news:trend', 'trend', 3), post('news:reco', 'reco', 3)],
      franchises: new Map([['trend', show(['Horror'])], ['reco', show(['Horror'])]]),
      recommended: [pick('reco')],
      seeds: ACTION_FAN,
      nowMs: NOW,
    })

    expect(ids(ranked)).toEqual(['news:reco', 'news:trend'])
  })

  it('puts a trending show that matches the library above one that does not, at the same age', () => {
    const ranked = rankForYou({
      posts: [post('news:horror', 'horror', 3), post('news:action', 'action', 3)],
      franchises: new Map([['horror', show(['Horror'])], ['action', show(['Action'])]]),
      recommended: [],
      seeds: ACTION_FAN,
      nowMs: NOW,
    })

    expect(ids(ranked)).toEqual(['news:action', 'news:horror'])
  })

  it('lets a recent recommendation outrank fresher news the library only matches', () => {
    // 0.5 x 1 + 0.5 x 0.5^(20/45) = 0.867 against 0.5 x 0.6 + 0.5 = 0.800.
    const ranked = rankForYou({
      posts: [post('news:action', 'action', 0), post('news:reco', 'reco', 20)],
      franchises: new Map([['action', show(['Action'])], ['reco', show(['Action'])]]),
      recommended: [pick('reco')],
      seeds: ACTION_FAN,
      nowMs: NOW,
    })

    expect(ids(ranked)).toEqual(['news:reco', 'news:action'])
  })

  it('places a pick among the picks that posted: one with no news takes no place', () => {
    // `silent` has no post. Were it counted, `reco` would be the last of two picks (affinity 0.7,
    // score 0.717) and fall under the fresh matched post (0.800) — the case above, reversed.
    const ranked = rankForYou({
      posts: [post('news:action', 'action', 0), post('news:reco', 'reco', 20)],
      franchises: new Map([['action', show(['Action'])], ['reco', show(['Action'])]]),
      recommended: [pick('silent'), pick('reco')],
      seeds: ACTION_FAN,
      nowMs: NOW,
    })

    expect(ids(ranked)).toEqual(['news:reco', 'news:action'])
  })

  it('puts this week\'s news about a show in the viewer\'s genres above a pick\'s 400-day-old post', () => {
    // The reason for the even weights. The pick: 0.5 x 1 + 0.5 x 0.5^(400/45) = 0.501; the trending
    // show (Action and Fantasy, a 0.75 match): 0.5 x 0.45 + 0.5 x 0.5^(3/45) = 0.702. At 0.65 / 0.35
    // on a 30-day half-life the old post led, 0.650 to 0.619.
    const reason = because('Overlord')
    const ranked = rankForYou({
      posts: [post('news:reco', 'reco', 400), post('news:trend', 'trend', 3)],
      franchises: new Map([['reco', show(['Action', 'Fantasy'])], ['trend', show(['Fantasy', 'Action'])]]),
      recommended: [{ franchiseId: 'reco', reason }],
      seeds: ACTION_FAN,
      nowMs: NOW,
    })

    // The old post is past the age limit too; with two candidates the refill keeps it, in its place.
    expect(ranked.map((p) => [p.id, p.context])).toEqual([
      ['news:trend', { kind: 'taste', genres: ['Action', 'Fantasy'] }],
      ['news:reco', { kind: 'recommended', reason }],
    ])
  })

  it('keeps the recommender\'s order between picks of the same age, and news age within reach of it', () => {
    const franchises = new Map(['a', 'b', 'c'].map((id) => [id, show([])]))
    const sameAge = rankForYou({
      posts: [post('news:c', 'c', 5), post('news:b', 'b', 5), post('news:a', 'a', 5)],
      franchises,
      recommended: [pick('a'), pick('b'), pick('c')],
      seeds: ACTION_FAN,
      nowMs: NOW,
    })
    expect(ids(sameAge)).toEqual(['news:a', 'news:b', 'news:c'])

    // The last pick with today's news (0.35 + 0.5) passes the first with news from 90 days ago
    // (0.5 + 0.125).
    const fresher = rankForYou({
      posts: [post('news:a', 'a', 90), post('news:c', 'c', 0)],
      franchises,
      recommended: [pick('a'), pick('b'), pick('c')],
      seeds: ACTION_FAN,
      nowMs: NOW,
    })
    expect(ids(fresher)).toEqual(['news:c', 'news:a'])
  })

  it('breaks an equal score by id', () => {
    const ranked = rankForYou({
      posts: [post('news:b', 'b', 2), post('news:c', 'c', 2), post('news:a', 'a', 2)],
      franchises: new Map(['a', 'b', 'c'].map((id) => [id, show(['Action'])])),
      recommended: [],
      seeds: ACTION_FAN,
      nowMs: NOW,
    })

    expect(ids(ranked)).toEqual(['news:a', 'news:b', 'news:c'])
  })
})

describe('rankForYou: the floor', () => {
  const franchises = new Map<string, TasteFranchise>()
  const matched = (n: number) =>
    Array.from({ length: n }, (_, i) => {
      franchises.set(`m${i}`, show(['Action']))
      return post(`news:m${String(i).padStart(2, '0')}`, `m${i}`, 10 + i)
    })
  /** Matched shows whose news is past the age limit: 250 days old, then a day older each. */
  const stale = (n: number) =>
    Array.from({ length: n }, (_, i) => {
      franchises.set(`o${i}`, show(['Action']))
      return post(`news:o${String(i).padStart(2, '0')}`, `o${i}`, 250 + i)
    })
  const unmatched = (n: number) =>
    Array.from({ length: n }, (_, i) => {
      franchises.set(`u${i}`, show(['Horror']))
      // Newer than every matched post: only the floor keeps them out.
      return post(`news:u${String(i).padStart(2, '0')}`, `u${i}`, i / 10)
    })

  it('leaves out shows the library does not touch once 20 posts remain without them', () => {
    const ranked = rankForYou({
      posts: [...unmatched(25), ...matched(22)],
      franchises,
      recommended: [],
      seeds: ACTION_FAN,
      nowMs: NOW,
    })

    expect(ranked).toHaveLength(22)
    expect(ranked.every((p) => p.id.startsWith('news:m'))).toBe(true)
  })

  it('refills to 20 from the left-out posts, best first, when fewer would remain', () => {
    const ranked = rankForYou({
      posts: [...unmatched(30), ...matched(5)],
      franchises,
      recommended: [],
      seeds: ACTION_FAN,
      nowMs: NOW,
    })

    expect(ranked).toHaveLength(FOR_YOU_RANK.minPosts)
    expect(ranked.filter((p) => p.id.startsWith('news:m'))).toHaveLength(5)
    // The 15 refills are the newest of the 30 (their score is recency alone), and carry no context.
    const refills = ranked.filter((p) => p.id.startsWith('news:u'))
    expect(ids(refills).sort()).toEqual(Array.from({ length: 15 }, (_, i) => `news:u${String(i).padStart(2, '0')}`))
    expect(refills.every((p) => p.context === null)).toBe(true)
  })

  it('keeps everything when fewer than 20 candidates exist at all', () => {
    const ranked = rankForYou({
      posts: [...unmatched(4), ...matched(2)],
      franchises,
      recommended: [],
      seeds: ACTION_FAN,
      nowMs: NOW,
    })

    expect(ranked).toHaveLength(6)
  })

  it('never leaves out a recommended show for its genres', () => {
    franchises.set('reco', show(['Horror']))
    const ranked = rankForYou({
      posts: [post('news:reco', 'reco', 100), ...unmatched(10), ...matched(25)],
      franchises,
      recommended: [pick('reco')],
      seeds: ACTION_FAN,
      nowMs: NOW,
    })

    expect(ranked).toHaveLength(26)
    expect(ids(ranked)).toContain('news:reco')
  })

  it('leaves out news older than 240 days, a recommended show\'s included, once 20 fresher posts fit', () => {
    franchises.set('reco', show(['Action']))
    franchises.set('edge', show(['Action']))
    const ranked = rankForYou({
      posts: [
        post('news:reco', 'reco', 300),
        // The limit itself is still in; a day past it is out.
        post('news:edge-in', 'edge', FOR_YOU_RANK.maxAgeDays),
        post('news:edge-out', 'edge', FOR_YOU_RANK.maxAgeDays + 1),
        ...stale(3),
        ...matched(20),
      ],
      franchises,
      recommended: [pick('reco')],
      seeds: ACTION_FAN,
      nowMs: NOW,
    })

    expect(ranked).toHaveLength(21)
    expect(ids(ranked)).toContain('news:edge-in')
    expect(ranked.some((p) => p.id === 'news:reco' || p.id === 'news:edge-out' || p.id.startsWith('news:o'))).toBe(false)
  })

  it('refills to 20 from stale posts, the least old first, when fewer than 20 fit', () => {
    const ranked = rankForYou({
      posts: [...stale(8), ...matched(15)],
      franchises,
      recommended: [],
      seeds: ACTION_FAN,
      nowMs: NOW,
    })

    expect(ranked).toHaveLength(FOR_YOU_RANK.minPosts)
    // The 15 that fit lead; the five refills are the newest of the eight and close the list.
    expect(ranked.slice(0, 15).every((p) => p.id.startsWith('news:m'))).toBe(true)
    expect(ids(ranked.slice(15))).toEqual(['news:o00', 'news:o01', 'news:o02', 'news:o03', 'news:o04'])
  })

  it('refills from everything that does not fit — stale posts and floor misses alike — by score', () => {
    // 18 fit, so two come back: the pick's 300-day-old post (0.5 + 0.005) and today's unmatched
    // post (0.5), ahead of yesterday's unmatched one (0.492) and the stale matched ones (0.31).
    franchises.set('reco', show(['Action']))
    franchises.set('today', show(['Horror']))
    franchises.set('yesterday', show(['Horror']))
    const ranked = rankForYou({
      posts: [
        post('news:reco', 'reco', 300),
        ...stale(4),
        post('news:yesterday', 'yesterday', 1),
        post('news:today', 'today', 0),
        ...matched(18),
      ],
      franchises,
      recommended: [pick('reco')],
      seeds: ACTION_FAN,
      nowMs: NOW,
    })

    expect(ranked).toHaveLength(FOR_YOU_RANK.minPosts)
    // Both score under every post that fits, so they close the list, the pick's first.
    expect(ids(ranked.slice(18))).toEqual(['news:reco', 'news:today'])
  })

  it('skips the taste floor when the library carries no genres to measure against, but not the age limit', () => {
    // A recommendation makes the feed personal, but with no profile every match is 0 for everyone.
    franchises.set('reco', show([]))
    franchises.set('old', show([]))
    const ranked = rankForYou({
      posts: [post('news:reco', 'reco', 100), post('news:old', 'old', 300), ...unmatched(25)],
      franchises,
      recommended: [pick('reco')],
      seeds: [seed([])],
      nowMs: NOW,
    })

    expect(ranked).toHaveLength(26)
    expect(ranked[0]?.id).toBe('news:reco')
    expect(ids(ranked)).not.toContain('news:old')
  })
})

describe('rankForYou: diversity', () => {
  it('gives each show one post in the first 20, and never runs one show twice in a row', () => {
    // `loud` has the three best-scoring posts; 24 other matched shows have one each.
    const franchises = new Map<string, TasteFranchise>([['loud', show(['Action'])]])
    const posts = Array.from({ length: 3 }, (_, i) => post(`trailer:loud${i}`, 'loud', 0))
    for (let i = 0; i < 24; i++) {
      franchises.set(`s${i}`, show(['Action']))
      posts.push(post(`news:s${String(i).padStart(2, '0')}`, `s${i}`, 1 + i))
    }

    const ranked = rankForYou({ posts, franchises, recommended: [], seeds: ACTION_FAN, nowMs: NOW })

    expect(ranked).toHaveLength(27)
    for (let i = 1; i < ranked.length; i++) expect(ranked[i]!.franchiseId === ranked[i - 1]!.franchiseId).toBe(false)
    // The first 20 — the whole feed the service serves — are 20 different shows.
    expect(new Set(ranked.slice(0, 20).map((p) => p.franchiseId)).size).toBe(20)
    expect(ids(ranked.slice(0, 2))).toEqual(['trailer:loud0', 'news:s00'])
    // The show's other posts are deferred past the head, not dropped, and still not side by side.
    expect(ids(ranked.slice(20, 23))).toEqual(['trailer:loud1', 'news:s19', 'trailer:loud2'])
  })

  it('lets the cap give way before the no-repeat rule when only capped shows remain', () => {
    const franchises = new Map([['a', show(['Action'])], ['b', show(['Action'])]])
    const posts = [0, 1, 2].flatMap((i) => [post(`news:a${i}`, 'a', i), post(`news:b${i}`, 'b', i + 0.5)])

    const ranked = rankForYou({ posts, franchises, recommended: [], seeds: ACTION_FAN, nowMs: NOW })

    expect(ids(ranked)).toEqual(['news:a0', 'news:b0', 'news:a1', 'news:b1', 'news:a2', 'news:b2'])
  })

  it('runs one show\'s posts together when it is the only show left', () => {
    const ranked = rankForYou({
      posts: [post('news:a1', 'a', 1), post('news:a0', 'a', 0), post('news:a2', 'a', 2)],
      franchises: new Map([['a', show(['Action'])]]),
      recommended: [],
      seeds: ACTION_FAN,
      nowMs: NOW,
    })

    expect(ids(ranked)).toEqual(['news:a0', 'news:a1', 'news:a2'])
  })
})

describe('rankForYou: a recommended show\'s evergreen trailer', () => {
  const franchises = new Map<string, TasteFranchise>([['reco', show(['Action'])], ['trend', show(['Action'])]])
  const fresh = (n: number) =>
    Array.from({ length: n }, (_, i) => {
      franchises.set(`m${i}`, show(['Action']))
      return post(`news:m${String(i).padStart(2, '0')}`, `m${i}`, 10 + i)
    })

  it('is never stale: a three-year-old trailer stays when 20 fresher posts fit', () => {
    const old = post('trailer:reco', 'reco', 1100, { evergreen: true })
    const ranked = rankForYou({ posts: [old, ...fresh(20)], franchises, recommended: [pick('reco')], seeds: ACTION_FAN, nowMs: NOW })

    expect(ranked).toHaveLength(21)
    // 0.5 x 1 + 0.5 x 0.6 = 0.8 against 0.3 + 0.5 x 0.5^(10/45) = 0.729 at best: it leads them.
    expect(ranked[0]?.id).toBe('trailer:reco')
    expect(ranked[0]?.context).toEqual({ kind: 'recommended', reason: because('Frieren') })
    // The same post without the flag is eight months past the age limit and gone.
    const plain = rankForYou({
      posts: [post('trailer:reco', 'reco', 1100), ...fresh(20)],
      franchises,
      recommended: [pick('reco')],
      seeds: ACTION_FAN,
      nowMs: NOW,
    })
    expect(ids(plain)).not.toContain('trailer:reco')
  })

  it('holds its recency at 0.6 whatever its age', () => {
    // The first pick's trailer is ten times older than the second's and still leads it: age plays
    // no part, the recommender's order does. 0.5 x 1 + 0.5 x 0.6 = 0.800 and 0.5 x 0.7 + 0.3 = 0.650,
    // either side of matched news from five days ago (0.3 + 0.5 x 0.5^(5/45) = 0.763) and above
    // matched news from two months ago (0.3 + 0.198).
    const ranked = rankForYou({
      posts: [
        post('news:old', 'old', 60),
        post('trailer:reco2', 'reco2', 300, { evergreen: true }),
        post('news:trend', 'trend', 5),
        post('trailer:reco', 'reco', 3000, { evergreen: true }),
      ],
      franchises: new Map([...franchises, ['reco2', show(['Action'])], ['old', show(['Action'])]]),
      recommended: [pick('reco'), pick('reco2')],
      seeds: ACTION_FAN,
      nowMs: NOW,
    })

    expect(ids(ranked)).toEqual(['trailer:reco', 'news:trend', 'trailer:reco2', 'news:old'])
  })

  it('never scores under what its real age would give it', () => {
    // A discovery trailer published last week (the spent news of an airing season had claimed it):
    // 0.5^(7/45) = 0.898, not 0.6 — so it still leads today's matched news about another show.
    const ranked = rankForYou({
      posts: [post('news:trend', 'trend', 0), post('trailer:reco', 'reco', 7, { evergreen: true })],
      franchises,
      recommended: [pick('reco')],
      seeds: ACTION_FAN,
      nowMs: NOW,
    })

    expect(ids(ranked)).toEqual(['trailer:reco', 'news:trend'])
  })

  it('gives way to fresh news about the same show, and takes the show\'s one slot when the news is old', () => {
    const rank = (newsAge: number) =>
      rankForYou({
        posts: [post('trailer:reco', 'reco', 900, { evergreen: true }), post('news:reco', 'reco', newsAge), ...fresh(22)],
        franchises,
        recommended: [pick('reco')],
        seeds: ACTION_FAN,
        nowMs: NOW,
      })

    // News from the last 33 days is worth more than 0.6: it leads, and the trailer waits past the 20.
    const recent = rank(10)
    expect(recent[0]?.id).toBe('news:reco')
    expect(ids(recent.slice(0, 20))).not.toContain('trailer:reco')
    // Older news: the trailer is the show's post in the 20.
    const older = rank(120)
    expect(older[0]?.id).toBe('trailer:reco')
    expect(ids(older.slice(0, 20))).not.toContain('news:reco')
  })
})

describe('rankForYou: something to look at', () => {
  const franchises = new Map<string, TasteFranchise>()
  const sharp = (n: number) =>
    Array.from({ length: n }, (_, i) => {
      franchises.set(`m${i}`, show(['Action']))
      return post(`news:m${String(i).padStart(2, '0')}`, `m${i}`, 10 + i)
    })
  /** Newer than every sharp post and a full match: only the picture keeps them out. */
  const blurred = (n: number) =>
    Array.from({ length: n }, (_, i) => {
      franchises.set(`b${i}`, show(['Action']))
      return post(`news:b${String(i).padStart(2, '0')}`, `b${i}`, i / 10, { sharp: false })
    })

  it('leaves a post with nothing to look at out once 20 sharper ones fit, a recommended show\'s included', () => {
    franchises.set('reco', show(['Action']))
    const ranked = rankForYou({
      posts: [post('news:reco', 'reco', 0, { sharp: false }), ...blurred(5), ...sharp(20)],
      franchises,
      recommended: [pick('reco')],
      seeds: ACTION_FAN,
      nowMs: NOW,
    })

    expect(ranked).toHaveLength(20)
    expect(ranked.every((p) => p.id.startsWith('news:m'))).toBe(true)
  })

  it('refills to 20 from them, best first, when fewer fit', () => {
    const ranked = rankForYou({
      posts: [...blurred(8), ...sharp(15)],
      franchises,
      recommended: [],
      seeds: ACTION_FAN,
      nowMs: NOW,
    })

    expect(ranked).toHaveLength(FOR_YOU_RANK.minPosts)
    // The five newest come back; being the best-scoring posts of all, they lead.
    expect(ids(ranked.slice(0, 5))).toEqual(['news:b00', 'news:b01', 'news:b02', 'news:b03', 'news:b04'])
    expect(ranked.filter((p) => p.id.startsWith('news:m'))).toHaveLength(15)
  })

  it('does not ask for a picture where nothing is personal', () => {
    const ranked = rankForYou({ posts: [...blurred(3), ...sharp(25)], franchises, recommended: [], seeds: [], nowMs: NOW })

    expect(ranked).toHaveLength(28)
    expect(ids(ranked.slice(0, 3))).toEqual(['news:b00', 'news:b01', 'news:b02'])
  })
})

describe('isSharp', () => {
  const image = (overrides: Partial<ArtworkImage>): ArtworkImage => ({
    url: 'https://img.example/a.jpg',
    source: 'tmdb',
    width: 2000,
    height: 3000,
    language: null,
    score: null,
    ...overrides,
  })
  const gallery = (portraits: ArtworkImage[] = [], landscapes: ArtworkImage[] = [], logos: ArtworkImage[] = []): ArtworkGallery => ({
    portraits,
    landscapes,
    logos,
  })
  // What a show with only AniList's art carries: an unmeasured cover and banner.
  const anilistOnly = gallery([image({ source: 'anilist', width: null, height: null })], [image({ source: 'anilist', width: null, height: null })])
  const bare = { video: null, part: null }

  it('takes a video as the picture, whatever the art', () => {
    expect(isSharp({ video: { id: 'x' }, part: null }, { artwork: anilistOnly })).toBe(true)
    expect(isSharp({ video: { id: 'x' }, part: null }, undefined)).toBe(true)
  })

  it('needs a picture measured at 1000 px or more, portrait or landscape, of the part or of the show', () => {
    expect(isSharp(bare, { artwork: gallery([image({ width: 1000 })]) })).toBe(true)
    expect(isSharp(bare, { artwork: gallery([], [image({ width: 1920 })]) })).toBe(true)
    expect(isSharp(bare, { artwork: gallery([image({ width: 999 })], [image({ width: 780 })]) })).toBe(false)
    // The part's own gallery counts as much as the show's.
    expect(isSharp({ video: null, part: { artwork: gallery([image({})]) } }, { artwork: anilistOnly })).toBe(true)
    // A logo is not a picture.
    expect(isSharp(bare, { artwork: gallery([], [], [image({})]) })).toBe(false)
  })

  it('is not sharp on AniList\'s cover and banner alone, or with no picture at all', () => {
    expect(isSharp(bare, { artwork: anilistOnly })).toBe(false)
    expect(isSharp({ video: null, part: { artwork: anilistOnly } }, { artwork: anilistOnly })).toBe(false)
    expect(isSharp(bare, { artwork: gallery() })).toBe(false)
    expect(isSharp(bare, undefined)).toBe(false)
    // A measured width decides even for an AniList-sourced entry.
    expect(isSharp(bare, { artwork: gallery([image({ source: 'anilist', width: 460 })]) })).toBe(false)
  })

  it('takes an unmeasured TMDB picture on its source', () => {
    // A TV show's stored poster before enrichment measures its gallery: TMDB-grade, width unknown.
    expect(isSharp(bare, { artwork: gallery([image({ width: null, height: null })]) })).toBe(true)
  })
})

describe('rankForYou: a library that says nothing', () => {
  const posts = [
    post('news:b', 'f1', 3),
    post('news:c', 'f1', 1),
    post('news:e', 'f2', 300),
    post('news:a', 'f2', 3),
    post('news:d', 'f1', 0),
  ]
  const franchises = new Map([['f1', show(['Action'])], ['f2', show(['Horror'])]])
  // Newest first, then id; one show back to back, nothing left out — not even news past the age
  // limit — and no context: the feed as it was.
  const timeOrder = ['news:d', 'news:c', 'news:a', 'news:b', 'news:e']

  it('is time order with no context for an empty library', () => {
    const ranked = rankForYou({ posts, franchises, recommended: [], seeds: [], nowMs: NOW })

    expect(ids(ranked)).toEqual(timeOrder)
    expect(ranked.every((p) => p.context === null)).toBe(true)
  })

  it('is the same for a library of dropped shows only', () => {
    const ranked = rankForYou({
      posts,
      franchises,
      recommended: [],
      seeds: [seed(['Action'], { status: 'dropped' })],
      nowMs: NOW,
    })

    expect(ids(ranked)).toEqual(timeOrder)
    expect(ranked.every((p) => p.context === null)).toBe(true)
  })

  it('is the same when the recommender\'s picks have no post among the candidates', () => {
    const ranked = rankForYou({ posts, franchises, recommended: [pick('elsewhere')], seeds: [], nowMs: NOW })

    expect(ids(ranked)).toEqual(timeOrder)
  })
})

describe('rankForYou: context', () => {
  it('says why each post is there: the recommender\'s reason, the matched genres, or nothing', () => {
    const reason = because('Vinland Saga')
    const ranked = rankForYou({
      posts: [
        post('news:reco', 'reco'),
        post('news:strong', 'strong'),
        post('news:edge', 'edge'),
        post('news:weak', 'weak'),
        post('news:none', 'none'),
      ],
      franchises: new Map([
        ['reco', show(['Action', 'Fantasy'])],
        // (0.5 + 1) / 2 = 0.75. Fantasy comes first in the catalogue; Action is the viewer's
        // stronger genre.
        ['strong', show(['Fantasy', 'Action'])],
        // (1 + 0.5 + 0) / 3 = 0.5: well over the floor, under the 0.6 a context needs.
        ['edge', show(['Comedy', 'Fantasy', 'Action'])],
        ['weak', show(['Horror'])],
        ['none', show([])],
      ]),
      recommended: [{ franchiseId: 'reco', reason }],
      seeds: ACTION_FAN,
      nowMs: NOW,
    })

    expect(Object.fromEntries(ranked.map((p) => [p.id, p.context]))).toEqual({
      'news:reco': { kind: 'recommended', reason },
      'news:strong': { kind: 'taste', genres: ['Action', 'Fantasy'] },
      'news:edge': null,
      'news:weak': null,
      'news:none': null,
    })
  })

  it('names one genre for a show that has one, and none for a show only half in the viewer\'s genres', () => {
    const ranked = rankForYou({
      posts: [post('news:a', 'a'), post('news:b', 'b')],
      // One matching genre of two is a 0.5 match: no show reaches 0.6 on a single genre among several.
      franchises: new Map([['a', show(['Action'])], ['b', show(['Action', 'Horror'])]]),
      recommended: [],
      seeds: ACTION_FAN,
      nowMs: NOW,
    })

    expect(ranked.map((p) => [p.id, p.context])).toEqual([
      ['news:a', { kind: 'taste', genres: ['Action'] }],
      ['news:b', null],
    ])
  })

  it('returns the candidates themselves, each once, with nothing invented', () => {
    const posts = Array.from({ length: 40 }, (_, i) => ({ ...post(`news:${i}`, `f${i % 7}`, i % 11), extra: i }))
    const franchises = new Map(Array.from({ length: 7 }, (_, i) => [`f${i}`, show(i % 2 ? ['Action'] : ['Horror'])] as const))

    const ranked = rankForYou({ posts, franchises, recommended: [pick('f0')], seeds: ACTION_FAN, nowMs: NOW })

    expect(new Set(ids(ranked)).size).toBe(ranked.length)
    for (const p of ranked) expect(posts[p.extra]).toMatchObject({ id: p.id, franchiseId: p.franchiseId, time: p.time })
  })
})
