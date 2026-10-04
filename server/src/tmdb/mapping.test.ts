import { describe, expect, it } from 'vitest'
import {
  MAX_TMDB_SEASON_ID,
  TMDB_ID_OFFSET,
  airDateToMs,
  deriveSeasonStatus,
  includedSeasons,
  isJapaneseAnimation,
  isJapaneseAnimationShow,
  tmdbEpisodes,
  tmdbArtwork,
  tmdbFranchiseEnrichment,
  tmdbGenreNames,
  tmdbNetworks,
  tmdbRecommendationTargets,
  tmdbSeasonMediaId,
  tmdbSeasonToMediaRow,
  tmdbShowUpcoming,
  tmdbShowToGroupingResult,
  tmdbVideos,
} from './mapping.js'
import type { TmdbEpisode, TmdbRecommendation, TmdbSearchResult, TmdbSeason, TmdbShow, TmdbVideo } from './types.js'

// Fixed "now": 2026-07-01T00:00Z.
const NOW = Date.UTC(2026, 6, 1)

function season(n: number, opts: Partial<TmdbSeason> = {}): TmdbSeason {
  return {
    id: 1000 + n,
    season_number: n,
    episode_count: 10,
    air_date: `202${Math.min(n, 5)}-01-15`,
    poster_path: `/s${n}.jpg`,
    name: n === 0 ? 'Specials' : `Season ${n}`,
    overview: '',
    ...opts,
  }
}

function show(opts: Partial<TmdbShow> = {}): TmdbShow {
  return {
    id: 42,
    name: 'Test Show',
    status: 'Returning Series',
    number_of_seasons: 2,
    seasons: [season(1), season(2)],
    next_episode_to_air: null,
    last_episode_to_air: null,
    genres: [{ id: 18, name: 'Drama' }],
    overview: 'A show.',
    backdrop_path: '/back.jpg',
    poster_path: '/poster.jpg',
    popularity: 12.7,
    origin_country: ['US'],
    ...opts,
  }
}

function result(opts: Partial<TmdbSearchResult> = {}): TmdbSearchResult {
  return {
    id: 42,
    name: 'Test Show',
    genre_ids: [18],
    origin_country: ['US'],
    poster_path: null,
    first_air_date: '2020-01-01',
    popularity: 1,
    overview: null,
    ...opts,
  }
}

describe('tmdbArtwork', () => {
  it('retains a lower-resolution clean poster through mapping and primary-poster fallback', () => {
    const posters = Array.from({ length: 8 }, (_, index) => ({
      file_path: `/titled-${index}.jpg`, width: 2000, height: 3000, iso_639_1: 'en', vote_average: 8 - index,
    }))
    const gallery = tmdbArtwork(show({ images: { posters: [...posters, {
      file_path: '/clean.jpg', width: 1000, height: 1500, iso_639_1: null, vote_average: 1,
    }], backdrops: [], logos: [] } }))
    expect(gallery.portraits).toHaveLength(6)
    expect(gallery.portraits[0]?.url).toBe('https://image.tmdb.org/t/p/w780/titled-0.jpg')
    expect(gallery.portraits.at(-1)).toMatchObject({
      url: 'https://image.tmdb.org/t/p/w780/clean.jpg', width: 1000, height: 1500, language: null,
    })
  })

  it('does not label the URL-only primary poster as measured textless art', () => {
    expect(tmdbArtwork(show()).portraits).toEqual([{
      url: 'https://image.tmdb.org/t/p/w780/poster.jpg', source: 'tmdb',
      width: null, height: null, language: null, score: null,
    }])
  })
})

function episode(n: number, opts: Partial<TmdbEpisode> = {}): TmdbEpisode {
  return {
    episode_number: n,
    name: `Episode ${n}`,
    overview: `Overview ${n}`,
    air_date: '2025-05-04',
    still_path: `/e${n}.jpg`,
    runtime: 42,
    ...opts,
  }
}

function video(opts: Partial<TmdbVideo> = {}): TmdbVideo {
  return {
    id: 'tmdb-video-row',
    key: 'youtube-id',
    site: 'YouTube',
    type: 'Trailer',
    name: 'Official Trailer',
    official: true,
    iso_639_1: 'en',
    iso_3166_1: 'US',
    published_at: '2026-01-05T00:00:00.000Z',
    ...opts,
  }
}

describe('tmdbSeasonMediaId', () => {
  it('offsets into the reserved id range', () => {
    expect(tmdbSeasonMediaId(123)).toBe(TMDB_ID_OFFSET + 123)
  })

  it('rejects ids outside the int4-safe range', () => {
    expect(() => tmdbSeasonMediaId(0)).toThrow()
    expect(() => tmdbSeasonMediaId(-5)).toThrow()
    expect(() => tmdbSeasonMediaId(MAX_TMDB_SEASON_ID + 1)).toThrow()
    expect(() => tmdbSeasonMediaId(1.5)).toThrow()
    expect(tmdbSeasonMediaId(MAX_TMDB_SEASON_ID)).toBe(2_147_483_647)
  })
})

describe('airDateToMs', () => {
  it('lands on the fixed 17:00 UTC synthesis hour', () => {
    expect(airDateToMs('2026-07-19')).toBe(Date.UTC(2026, 6, 19, 17))
  })

  it('is null for missing or malformed dates', () => {
    expect(airDateToMs(null)).toBeNull()
    expect(airDateToMs('')).toBeNull()
    expect(airDateToMs('soon')).toBeNull()
  })
})

describe('isJapaneseAnimation', () => {
  it('suppresses JP animation (AniList owns it)', () => {
    expect(isJapaneseAnimation(result({ genre_ids: [16], origin_country: ['JP'] }))).toBe(true)
  })

  it('keeps western animation and JP live-action', () => {
    expect(isJapaneseAnimation(result({ genre_ids: [16], origin_country: ['US'] }))).toBe(false)
    expect(isJapaneseAnimation(result({ genre_ids: [18], origin_country: ['JP'] }))).toBe(false)
  })
})

describe('isJapaneseAnimationShow', () => {
  // The full-show form is what ensureTvFranchise enforces, so EVERY creator honours the boundary
  // — not just the search/trending callers that happen to remember to filter.
  it('suppresses JP animation on the full show payload', () => {
    expect(isJapaneseAnimationShow(show({ genres: [{ id: 16, name: 'Animation' }], origin_country: ['JP'] }))).toBe(
      true,
    )
  })

  it('keeps western animation, JP live-action, and JP co-productions that are not animated', () => {
    expect(isJapaneseAnimationShow(show({ genres: [{ id: 16, name: 'Animation' }], origin_country: ['US'] }))).toBe(
      false,
    )
    expect(isJapaneseAnimationShow(show({ genres: [{ id: 18, name: 'Drama' }], origin_country: ['JP'] }))).toBe(false)
    // Live-action adaptations of manga (e.g. Netflix's One Piece) are legitimately TMDB's.
    expect(
      isJapaneseAnimationShow(show({ genres: [{ id: 10759, name: 'Action & Adventure' }], origin_country: ['US', 'JP'] })),
    ).toBe(false)
  })

  it('agrees with the search-result form for a multi-genre anime', () => {
    const genres = [{ id: 16, name: 'Animation' }, { id: 10759, name: 'Action & Adventure' }]
    expect(isJapaneseAnimationShow(show({ genres, origin_country: ['JP'] }))).toBe(true)
    expect(isJapaneseAnimation(result({ genre_ids: [16, 10759], origin_country: ['JP'] }))).toBe(true)
  })
})

describe('includedSeasons', () => {
  it('keeps numbered seasons even with zero episodes (announced), drops empty Specials', () => {
    const s = show({
      seasons: [season(0, { episode_count: 0 }), season(1), season(2, { episode_count: 0, air_date: null })],
    })
    expect(includedSeasons(s).map((x) => x.season_number)).toEqual([1, 2])
  })

  it('keeps Specials that actually have episodes', () => {
    const s = show({ seasons: [season(0, { episode_count: 3 }), season(1)] })
    expect(includedSeasons(s).map((x) => x.season_number)).toEqual([0, 1])
  })
})

describe('deriveSeasonStatus', () => {
  it('marks undated and future seasons NOT_YET_RELEASED', () => {
    const s = show()
    expect(deriveSeasonStatus(s, season(3, { air_date: null }), NOW)).toBe('NOT_YET_RELEASED')
    expect(deriveSeasonStatus(s, season(3, { air_date: '2026-09-01' }), NOW)).toBe('NOT_YET_RELEASED')
  })

  it('marks only the next-episode season RELEASING', () => {
    const s = show({
      next_episode_to_air: { air_date: '2026-07-10', episode_number: 5, season_number: 2 },
    })
    expect(deriveSeasonStatus(s, season(2), NOW)).toBe('RELEASING')
    expect(deriveSeasonStatus(s, season(1), NOW)).toBe('FINISHED')
  })

  it('marks a cancelled show´s last-aired season CANCELLED, earlier seasons FINISHED', () => {
    const s = show({
      status: 'Canceled',
      last_episode_to_air: { air_date: '2025-03-01', episode_number: 8, season_number: 2 },
    })
    expect(deriveSeasonStatus(s, season(2), NOW)).toBe('CANCELLED')
    expect(deriveSeasonStatus(s, season(1), NOW)).toBe('FINISHED')
  })

  it('marks aired seasons of a returning show FINISHED', () => {
    expect(deriveSeasonStatus(show(), season(1), NOW)).toBe('FINISHED')
  })
})

describe('tmdbSeasonToMediaRow', () => {
  it('maps ids, source, and titles (per-season title only when multi-season)', () => {
    const s = show({
      next_episode_to_air: { air_date: '2026-07-10', episode_number: 5, season_number: 2 },
    })
    const row = tmdbSeasonToMediaRow(s, season(2), NOW)
    expect(row.id).toBe(TMDB_ID_OFFSET + 1002)
    expect(row.source).toBe('tmdb')
    expect(row.externalId).toBe(1002)
    expect(row.titleEnglish).toBe('Test Show: Season 2')
    expect(row.format).toBe('TV')

    const solo = show({ seasons: [season(1)] })
    expect(tmdbSeasonToMediaRow(solo, season(1), NOW).titleEnglish).toBe('Test Show')
  })

  it('snapshots nextAiringEpisode in SECONDS on the releasing season only', () => {
    const s = show({
      next_episode_to_air: { air_date: '2026-07-10', episode_number: 5, season_number: 2 },
    })
    const releasing = tmdbSeasonToMediaRow(s, season(2), NOW)
    expect(releasing.nextAiringEpisode).toEqual({
      episode: 5,
      airingAt: Math.floor(Date.UTC(2026, 6, 10, 17) / 1000),
    })
    expect(tmdbSeasonToMediaRow(s, season(1), NOW).nextAiringEpisode).toBeNull()
  })

  it('gives a dated upcoming season its premiere as episode 1', () => {
    // next_episode_to_air only ever points at the releasing season, so an announced season would
    // otherwise ship no airing instant at all and read as "release date TBA" on the client.
    const upcoming = season(3, { air_date: '2026-09-01' })
    const s = show({
      seasons: [season(1), season(2), upcoming],
      next_episode_to_air: { air_date: '2026-07-10', episode_number: 5, season_number: 2 },
    })
    const row = tmdbSeasonToMediaRow(s, upcoming, NOW)
    expect(row.status).toBe('NOT_YET_RELEASED')
    expect(row.nextAiringEpisode).toEqual({
      episode: 1,
      airingAt: Math.floor(Date.UTC(2026, 8, 1, 17) / 1000),
    })
    // The releasing season keeps its own real slot.
    expect(tmdbSeasonToMediaRow(s, season(2), NOW).nextAiringEpisode).toEqual({
      episode: 5,
      airingAt: Math.floor(Date.UTC(2026, 6, 10, 17) / 1000),
    })
  })

  it('leaves an undated announced season without a next slot', () => {
    const undated = season(3, { air_date: null })
    const s = show({ seasons: [season(1), undated] })
    const row = tmdbSeasonToMediaRow(s, undated, NOW)
    expect(row.status).toBe('NOT_YET_RELEASED')
    expect(row.nextAiringEpisode).toBeNull()
    expect(row.lastAiredAt).toBeNull()
  })

  it('uses an actual last episode date, never the season premiere as its finale', () => {
    const s = show({
      next_episode_to_air: { air_date: '2026-07-10', episode_number: 5, season_number: 2 },
      last_episode_to_air: { air_date: '2026-07-03', episode_number: 4, season_number: 2 },
    })
    expect(tmdbSeasonToMediaRow(s, season(2), NOW).lastAiredAt).toBe(Date.UTC(2026, 6, 3, 17))
    expect(tmdbSeasonToMediaRow(s, season(1), NOW).lastAiredAt).toBeNull()
  })

  it('falls back to the show poster when a season has none', () => {
    const row = tmdbSeasonToMediaRow(show(), season(1, { poster_path: null }), NOW)
    expect(row.cover).toBe('https://image.tmdb.org/t/p/w780/poster.jpg')
    expect(row.banner).toBe('https://image.tmdb.org/t/p/w1280/back.jpg')
  })

  it('carries the passed episode list and the show networks as studios', () => {
    const s = show({ networks: [{ id: 1, name: 'HBO' }] })
    const eps = tmdbEpisodes([episode(1)])
    const row = tmdbSeasonToMediaRow(s, season(1), NOW, eps)
    expect(row.studios).toEqual(['HBO'])
    expect(row.episodesList).toEqual(eps)
  })

  it('carries season-specific videos separately from episode metadata', () => {
    const videos = tmdbVideos([video()])
    const row = tmdbSeasonToMediaRow(show(), season(1), NOW, [], videos)
    expect(row.videos).toEqual(videos)
  })

  it('defaults to no episodes and no studios when omitted', () => {
    const row = tmdbSeasonToMediaRow(show(), season(1), NOW)
    expect(row.episodesList).toEqual([])
    expect(row.studios).toEqual([])
  })
})

describe('tmdbEpisodes', () => {
  it('maps to EpisodeMeta with 17:00 UTC dates, still urls, and runtime', () => {
    const eps = tmdbEpisodes([episode(1), episode(2, { name: '', still_path: null, runtime: null })])
    expect(eps).toEqual([
      {
        number: 1,
        title: 'Episode 1',
        airDate: Date.UTC(2025, 4, 4, 17),
        overview: 'Overview 1',
        still: 'https://image.tmdb.org/t/p/w780/e1.jpg',
        runtime: 42,
      },
      {
        number: 2,
        title: null, // empty name → null
        airDate: Date.UTC(2025, 4, 4, 17),
        overview: 'Overview 2',
        still: null,
        runtime: null,
      },
    ])
  })

  it('is empty for null/undefined episode lists', () => {
    expect(tmdbEpisodes(null)).toEqual([])
    expect(tmdbEpisodes(undefined)).toEqual([])
  })
})

describe('tmdbNetworks', () => {
  it('takes up to three network names', () => {
    const s = show({
      networks: [
        { id: 1, name: 'HBO' },
        { id: 2, name: 'Max' },
        { id: 3, name: 'Sky' },
        { id: 4, name: 'Crave' },
      ],
    })
    expect(tmdbNetworks(s)).toEqual(['HBO', 'Max', 'Sky'])
  })

  it('is empty when the show has no networks', () => {
    expect(tmdbNetworks(show())).toEqual([])
  })
})

describe('tmdbVideos', () => {
  it('maps playable links and recognizes renewal featurettes as announcements', () => {
    expect(tmdbVideos([
      video({ key: 'renewal', type: 'Featurette', name: 'The series is returning for Season 6!' }),
    ])).toEqual([{
      id: 'renewal',
      site: 'youtube',
      kind: 'announcement',
      title: 'The series is returning for Season 6!',
      url: 'https://www.youtube.com/watch?v=renewal',
      thumbnail: 'https://i.ytimg.com/vi/renewal/hqdefault.jpg',
      official: true,
      language: 'en',
      country: 'US',
      publishedAt: '2026-01-05T00:00:00.000Z',
    }])
  })

  it('drops non-promotional miscellany and deduplicates provider ids', () => {
    expect(tmdbVideos([
      video({ type: 'Bloopers', key: 'out' }),
      video({ key: 'same', official: false }),
      video({ key: 'same', official: true }),
    ])).toHaveLength(1)
  })
})

describe('tmdbFranchiseEnrichment', () => {
  it('maps ratings, people, conservative themes, related artwork, and show videos', () => {
    const value = tmdbFranchiseEnrichment(show({
      adult: false,
      created_by: [{ id: 1, name: 'Creator', profile_path: '/creator.jpg' }],
      videos: { results: [video()] },
      content_ratings: { results: [
        { iso_3166_1: 'US', rating: 'TV-MA' },
        { iso_3166_1: 'AU', rating: 'M' },
      ] },
      keywords: { results: [
        { id: 1, name: 'friendship' },
        { id: 2, name: 'secret identity revealed' },
      ] },
      aggregate_credits: {
        cast: [{
          id: 2,
          name: 'Lead',
          profile_path: '/lead.jpg',
          order: 0,
          total_episode_count: 20,
          roles: [{ character: 'Hero', episode_count: 20 }],
        }],
        crew: [{
          id: 3,
          name: 'Director',
          profile_path: '/director.jpg',
          jobs: [{ job: 'Director', episode_count: 8 }],
        }],
      },
      recommendations: { results: [{
        id: 99,
        name: 'Related Show',
        poster_path: '/related-poster.jpg',
        backdrop_path: '/related-back.jpg',
        first_air_date: '2024-02-01',
        media_type: 'tv',
        adult: false,
      }] },
    }), NOW)

    expect(value.level).toBe('full')
    expect(value.themes).toEqual(['Drama', 'Friendship'])
    expect(value.contentRatings).toEqual([
      { country: 'AU', rating: 'M' },
      { country: 'US', rating: 'TV-MA' },
    ])
    expect(value.people.creators[0]).toMatchObject({ name: 'Creator', role: 'Creator' })
    expect(value.people.directors[0]).toMatchObject({ name: 'Director', role: 'Director' })
    expect(value.people.cast[0]).toMatchObject({ name: 'Lead', role: 'Hero' })
    expect(value.related[0]).toEqual({
      source: 'tmdb',
      externalId: 99,
      franchiseId: null,
      title: 'Related Show',
      year: 2024,
      images: {
        portrait: 'https://image.tmdb.org/t/p/w780/related-poster.jpg',
        landscape: 'https://image.tmdb.org/t/p/w1280/related-back.jpg',
      },
      score: 10,
    })
    expect(value.videos[0]?.id).toBe('youtube-id')
  })
})

describe('tmdbShowUpcoming', () => {
  it('ships a dated future season immediately with the search materialization', () => {
    const s = show({
      id: 82_596,
      seasons: [season(1), season(6, { air_date: '2026-12-24' })],
      last_episode_to_air: { air_date: '2025-12-18', episode_number: 10, season_number: 5 },
    })
    expect(tmdbShowUpcoming(s, NOW)).toEqual({
      status: 'upcoming_dated',
      next: 'Season 6',
      release: '2026-12-24',
      note: null,
      source: 'https://www.themoviedb.org/tv/82596',
      checked: new Date(NOW).toISOString(),
      evidence: [{
        url: 'https://www.themoviedb.org/tv/82596', publisher: 'TMDB', publishedAt: null,
        tier: 'catalogue', primary: false,
      }],
    })
  })

  it('does not invent a numbered season from the generic returning status', () => {
    const s = show({
      id: 87_826,
      status: 'Returning Series',
      seasons: [season(8), season(9)],
      last_episode_to_air: { air_date: '2025-10-29', episode_number: 11, season_number: 9 },
    })
    expect(tmdbShowUpcoming(s, NOW)).toBeNull()
  })

  it('does not invent another season for an ended or currently releasing show', () => {
    expect(tmdbShowUpcoming(show({ status: 'Ended' }), NOW)).toBeNull()
    expect(
      tmdbShowUpcoming(
        show({
          next_episode_to_air: { air_date: '2026-07-10', episode_number: 5, season_number: 2 },
        }),
        NOW,
      ),
    ).toBeNull()
  })

  it('does not mistake an old undated season for a new announcement', () => {
    const s = show({
      seasons: [season(1, { air_date: null }), season(2, { air_date: '2025-01-15' })],
      last_episode_to_air: null,
      status: 'Ended',
    })
    expect(tmdbShowUpcoming(s, NOW)).toBeNull()
  })
})

describe('tmdbShowToGroupingResult', () => {
  it('builds one deterministic franchise with season_number sequences', () => {
    const s = show({ seasons: [season(0, { episode_count: 3 }), season(1), season(2)] })
    const r = tmdbShowToGroupingResult(s)
    expect(r.model).toBeNull()
    expect(r.confidence).toBe(1)
    expect(r.franchises).toHaveLength(1)
    expect(r.franchises[0]!.canonicalName).toBe('Test Show')
    expect(r.franchises[0]!.parts).toEqual([
      {
        id: TMDB_ID_OFFSET + 1000, partKind: 'special', sequence: 0, watchOrder: 10_000,
        relationship: 'SPECIAL', optional: true, label: 'Specials',
      },
      {
        id: TMDB_ID_OFFSET + 1001, partKind: 'season', sequence: 1, watchOrder: 1,
        relationship: null, optional: false, label: 'Season 1',
      },
      {
        id: TMDB_ID_OFFSET + 1002, partKind: 'season', sequence: 2, watchOrder: 2,
        relationship: 'SEQUEL', optional: false, label: 'Season 2',
      },
    ])
  })
})

describe('TMDB recommendations', () => {
  function rec(id: number, opts: Partial<TmdbRecommendation> = {}): TmdbRecommendation {
    return {
      id,
      name: `Rec ${id}`,
      poster_path: `/p${id}.jpg`,
      backdrop_path: `/b${id}.jpg`,
      first_air_date: '2019-06-01',
      media_type: 'tv',
      adult: false,
      vote_average: 7.85,
      vote_count: 1200,
      popularity: 64.2,
      genre_ids: [10765, 18],
      origin_country: ['US'],
      ...opts,
    }
  }
  const page = [
    rec(1),
    rec(2, { media_type: 'movie' }),
    rec(3, { adult: true }),
    rec(4, { genre_ids: [16, 10759], origin_country: ['JP'] }), // an anime's TMDB twin
    rec(42), // the show itself
    rec(5, { name: '' }),
    rec(1), // a duplicate
    ...Array.from({ length: 30 }, (_, i) => rec(100 + i)),
  ]

  it('keeps twenty TV titles for the ranker, in TMDB order, with the facts already in the payload', () => {
    const { edges, targets } = tmdbRecommendationTargets(show({ recommendations: { results: page } }))
    expect(edges).toHaveLength(20)
    expect(edges.slice(0, 3)).toEqual([
      { source: 'tmdb', externalId: 1, rank: 0, votes: null },
      { source: 'tmdb', externalId: 100, rank: 1, votes: null },
      { source: 'tmdb', externalId: 101, rank: 2, votes: null },
    ])
    expect(targets.map((t) => t.externalId)).toEqual(edges.map((e) => e.externalId))
    expect(targets[0]).toEqual({
      source: 'tmdb',
      externalId: 1,
      title: 'Rec 1',
      year: 2019,
      images: { portrait: 'https://image.tmdb.org/t/p/w780/p1.jpg', landscape: 'https://image.tmdb.org/t/p/w1280/b1.jpg' },
      format: 'TV',
      status: null,
      episodes: null,
      averageScore: 78.5,
      voteCount: 1200,
      popularity: 64.2,
      genres: ['Sci-Fi & Fantasy', 'Drama'],
      isAdult: false,
      countryOfOrigin: 'US',
      airing: false,
      announced: false,
      releaseDate: '2019-06-01',
      rootId: 1,
      rootTitle: 'Rec 1',
      rootYear: 2019,
      rootFormat: 'TV',
      rootEpisodes: null,
      rootImages: { portrait: 'https://image.tmdb.org/t/p/w780/p1.jpg', landscape: 'https://image.tmdb.org/t/p/w1280/b1.jpg' },
      memberIds: [],
      worldIds: [],
    })
  })

  it('keeps the show page at ten and never offers Japanese animation, films, adult titles or the show itself', () => {
    const related = tmdbFranchiseEnrichment(show({ recommendations: { results: page } }), NOW).related
    expect(related).toHaveLength(10)
    expect(related.map((r) => r.externalId)).toEqual([1, 100, 101, 102, 103, 104, 105, 106, 107, 108])
    expect(related[0]!.score).toBe(10)
  })

  it('reads missing vote data as unmeasured, not as zero', () => {
    const { targets } = tmdbRecommendationTargets(show({ recommendations: { results: [rec(7, {
      vote_average: undefined, vote_count: undefined, popularity: undefined, genre_ids: undefined, origin_country: undefined, first_air_date: null,
    })] } }))
    expect(targets[0]).toMatchObject({ averageScore: null, voteCount: null, popularity: null, genres: [], countryOfOrigin: null, releaseDate: null, year: null })
  })

  it('names TV genres from their ids, once each, ignoring unknown ids', () => {
    expect(tmdbGenreNames([10759, 16, 10759, 99999, 10764])).toEqual(['Action & Adventure', 'Animation', 'Reality'])
    expect(tmdbGenreNames(undefined)).toEqual([])
  })
})
