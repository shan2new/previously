import { describe, expect, it } from 'vitest'
import { normalizeWatchProviders, pickAnimeWatchTarget } from './watchAvailability.js'

describe('pickAnimeWatchTarget', () => {
  it('does not match an explicitly adult provider result even with the same title and year', () => {
    expect(pickAnimeWatchTarget([{
      id: 1, title: 'Show', originalTitle: 'Show', year: 2024, popularity: 500,
      genreIds: [16], originCountries: ['JP'], adult: true,
    }], ['Show'], 2024)).toBeNull()
  })
  it('selects the matching Japanese animation and rejects a same-name live-action result', () => {
    const picked = pickAnimeWatchTarget([
      {
        id: 1,
        title: 'Bleach',
        originalTitle: 'Bleach',
        year: 2022,
        popularity: 500,
        genreIds: [18],
        originCountries: ['US'],
      },
      {
        id: 30984,
        title: 'Bleach',
        originalTitle: 'BLEACH',
        year: 2004,
        popularity: 132,
        genreIds: [16, 10759],
        originCountries: ['JP'],
      },
    ], ['Bleach'], 2004)

    expect(picked?.id).toBe(30984)
  })

  it('refuses a same-title remake from a materially different year', () => {
    const picked = pickAnimeWatchTarget([
      {
        id: 99,
        title: 'Dororo',
        originalTitle: 'Dororo',
        year: 1969,
        popularity: 20,
        genreIds: [16],
        originCountries: ['JP'],
      },
    ], ['Dororo'], 2019)

    expect(picked).toBeNull()
  })

  it('does not treat an undated same-name result as corroborated when the anime year is known', () => {
    const picked = pickAnimeWatchTarget([
      {
        id: 100,
        title: 'Test Title',
        originalTitle: null,
        year: null,
        popularity: 999,
        genreIds: [16],
        originCountries: ['JP'],
      },
    ], ['Test Title'], 2024)

    expect(picked).toBeNull()
  })
})

describe('normalizeWatchProviders', () => {
  it('keeps streaming access only, ordered and deduplicated by provider id', () => {
    expect(normalizeWatchProviders({
      flatrate: [
        { provider_id: 8, provider_name: 'Netflix', logo_path: '/netflix.jpg', display_priority: 0 },
        { provider_id: 283, provider_name: 'Crunchyroll', logo_path: '/cr.jpg', display_priority: 6 },
      ],
      free: [
        { provider_id: 283, provider_name: 'Crunchyroll Free', logo_path: '/cr.jpg', display_priority: 1 },
        { provider_id: 9, provider_name: 'Free Service', logo_path: null, display_priority: 2 },
      ],
      ads: [
        { provider_id: 515, provider_name: 'MX Player', logo_path: '/mx.jpg', display_priority: 1 },
      ],
      rent: [
        { provider_id: 10, provider_name: 'Amazon Video', logo_path: '/amazon.jpg', display_priority: 0 },
      ],
    })).toEqual([
      { id: 8, name: 'Netflix', logo: 'https://image.tmdb.org/t/p/w92/netflix.jpg', access: 'subscription' },
      { id: 283, name: 'Crunchyroll', logo: 'https://image.tmdb.org/t/p/w92/cr.jpg', access: 'subscription' },
      { id: 9, name: 'Free Service', logo: null, access: 'free' },
      { id: 515, name: 'MX Player', logo: 'https://image.tmdb.org/t/p/w92/mx.jpg', access: 'ads' },
    ])
  })
})
