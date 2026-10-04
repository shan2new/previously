import { describe, expect, it } from 'vitest'
import type { CatalogUpcomingPart } from './catalogUpcoming.js'
import { deriveCatalogUpcoming, resolveUpcomingWithCatalog } from './catalogUpcoming.js'

const NOW = Date.UTC(2026, 8, 2)

function part(overrides: Partial<CatalogUpcomingPart> = {}): CatalogUpcomingPart {
  return {
    mediaId: 1_000_493_251,
    kind: 'season',
    sequence: 6,
    label: 'Season 6',
    status: 'NOT_YET_RELEASED',
    nextAiringAt: Date.UTC(2026, 11, 24, 17),
    fetchedAt: new Date('2026-09-02T14:36:40.961Z'),
    ...overrides,
  }
}

describe('deriveCatalogUpcoming', () => {
  it('promotes a known future TMDB season into a confirmed dated result', () => {
    expect(
      deriveCatalogUpcoming({
        source: 'tmdb',
        franchiseExternalId: 82_596,
        parts: [part()],
        nowMs: NOW,
      }),
    ).toEqual({
      status: 'upcoming_dated',
      next: 'Season 6',
      release: '2026-12-24',
      note: null,
      source: 'https://www.themoviedb.org/tv/82596',
      checked: '2026-09-02T14:36:40.961Z',
      evidence: [{
        url: 'https://www.themoviedb.org/tv/82596', publisher: 'TMDB', publishedAt: null,
        tier: 'catalogue', primary: false,
      }],
    })
  })

  it('represents an official undated catalogue part without inventing a date', () => {
    expect(
      deriveCatalogUpcoming({
        source: 'anilist',
        franchiseExternalId: null,
        parts: [part({ mediaId: 123, label: 'Season 2', nextAiringAt: null })],
        nowMs: NOW,
      }),
    ).toMatchObject({
      status: 'announced_no_date',
      next: 'Season 2',
      release: 'TBA',
      source: 'https://anilist.co/anime/123',
    })
  })

  it('ignores releasing, finished, and stale future-status rows', () => {
    const stale = part({ nextAiringAt: NOW - 1 })
    const releasing = part({ status: 'RELEASING' })
    const finished = part({ status: 'FINISHED' })
    expect(
      deriveCatalogUpcoming({
        source: 'tmdb',
        franchiseExternalId: 82_596,
        parts: [stale, releasing, finished],
        nowMs: NOW,
      }),
    ).toBeNull()
  })

  it('chooses the earliest dated future part deterministically', () => {
    const later = part({ mediaId: 3, sequence: 3, label: 'Season 3', nextAiringAt: NOW + 60_000 })
    const earlier = part({ mediaId: 2, sequence: 2, label: 'Season 2', nextAiringAt: NOW + 30_000 })
    expect(
      deriveCatalogUpcoming({
        source: 'anilist',
        franchiseExternalId: null,
        parts: [later, earlier],
        nowMs: NOW,
      })?.next,
    ).toBe('Season 2')
  })
})

describe('resolveUpcomingWithCatalog', () => {
  const catalog = part()
  const derived = deriveCatalogUpcoming({
    source: 'tmdb',
    franchiseExternalId: 82_596,
    parts: [catalog],
    nowMs: NOW,
  })!

  it('lets a confirmed future part disprove a rumor or conclusion', () => {
    for (const status of ['rumored', 'recently_aired', 'concluded']) {
      expect(
        resolveUpcomingWithCatalog(
          { status, next: '', release: 'TBA', note: null, source: null, checked: null },
          derived,
        ),
      ).toBe(derived)
    }
  })

  it('retains richer official web research', () => {
    const researched = {
      status: 'announced',
      next: 'Season 6',
      release: 'Winter 2027',
      note: 'Officially announced by Netflix.',
      source: 'https://www.netflix.com/tudum/',
      checked: '2026-09-02T12:00:00.000Z',
    }
    expect(resolveUpcomingWithCatalog(researched, derived)).toBe(researched)
  })
})
