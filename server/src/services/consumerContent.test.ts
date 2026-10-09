import { describe, expect, it } from 'vitest'
import type { AniListMedia } from '../anilist/types.js'
import { ContentExcludedError, consumerAnimeFetcher, isExcludedContent } from './consumerContent.js'

describe('consumer catalogue policy', () => {
  it('excludes explicit provider flags and Hentai without broadening mature content', () => {
    for (const value of [{ isAdult: true }, { adult: true }, { enrichment: { isAdult: true } }, { genres: ['Drama', 'Hentai'] }]) {
      expect(isExcludedContent(value)).toBe(true)
    }
    for (const value of [{}, { isAdult: null }, { isAdult: false }, { isAdult: 'true' }, { genres: 'Hentai' },
      { genres: ['Ecchi'] }, { genres: null }, { enrichment: { isAdult: 'true' } }]) {
      expect(isExcludedContent(value)).toBe(false)
    }
  })

  it('rejects the requested adult seed before a grouping component can be materialised', async () => {
    const seed = { id: 1, isAdult: true, genres: ['Drama'] } as AniListMedia
    const fetcher = consumerAnimeFetcher(1, async () => [seed])
    await expect(fetcher([1])).rejects.toBeInstanceOf(ContentExcludedError)
  })

  it('retains an allowed seed and omits excluded relation nodes in a mixed graph', async () => {
    const safe = { id: 1, isAdult: false, genres: ['Ecchi'] } as AniListMedia
    const adult = { id: 2, isAdult: true, genres: ['Drama'] } as AniListMedia
    const hentai = { id: 3, isAdult: false, genres: ['Hentai'] } as AniListMedia
    const fetcher = consumerAnimeFetcher(1, async () => [safe, adult, hentai])
    expect(await fetcher([1, 2, 3])).toEqual([safe])
  })
})
