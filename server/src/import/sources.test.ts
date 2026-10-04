import { beforeEach, describe, expect, it, vi } from 'vitest'
const m = vi.hoisted(() => ({ gql: vi.fn(), searchMedia: vi.fn(), find: vi.fn(), search: vi.fn() }))
vi.mock('../anilist/client.js', () => ({ gql: m.gql, searchMedia: m.searchMedia }))
vi.mock('../tmdb/client.js', () => ({ findTvByTvdbId: m.find, searchTv: m.search }))
vi.mock('../util/pacer.js', () => ({ createPacer: () => async () => {} }))
import { fetchAniListEntries, mapMalRows, resolveTvShows, findAnimeByTitle } from './sources.js'
const show = { tvdbId: null, title: 'The Office', seasons: [], followed: true, forLater: false, archived: false, lastWatchedAt: null }
beforeEach(() => { vi.resetAllMocks(); m.find.mockResolvedValue(null); m.search.mockResolvedValue([]) })
describe('history source identity and failures', () => {
  it('rejects an ambiguous title instead of choosing the first remake', async () => {
    m.search.mockResolvedValue([{ id: 1, name: 'The Office', first_air_date: '2001-07-09' }, { id: 2, name: 'The Office', first_air_date: '2005-03-24' }])
    expect((await resolveTvShows([show]))[0]?.tmdb).toBeNull()
    expect((await resolveTvShows([{ ...show, title: 'The Office (2005)' }]))[0]?.tmdb?.id).toBe(2)
  })
  it('uses the TVDB identity before title search', async () => {
    m.find.mockResolvedValue({ id: 2, name: 'The Office' })
    expect((await resolveTvShows([{ ...show, tvdbId: 10 }]))[0]?.tmdb?.id).toBe(2)
    expect(m.search).not.toHaveBeenCalled()
  })
  it('reports provider outages instead of listing every title as unmatched', async () => {
    m.find.mockRejectedValue(new Error('503'))
    await expect(resolveTvShows([{ ...show, tvdbId: 10 }])).rejects.toMatchObject({ reason: 'unavailable' })
  })
  it('does not pick arbitrarily between anime with the same name', async () => {
    m.searchMedia.mockResolvedValue([1, 2].map(id => ({ id, format: 'TV', title: { english: 'Show' } })))
    expect(await findAnimeByTitle('Show')).toBeNull()
  })
  it('paginates AniList, ignores custom duplicates and preserves rewatches', async () => {
    const e = { mediaId: 1, status: 'REPEATING', progress: 3, media: { title: { english: 'A' } } }
    m.gql.mockResolvedValueOnce({ MediaListCollection: { hasNextChunk: true, lists: [{ isCustomList: true, entries: [{ ...e, mediaId: 99 }] }, { isCustomList: false, entries: [e] }] } })
      .mockResolvedValueOnce({ MediaListCollection: { hasNextChunk: false, lists: [{ isCustomList: false, entries: [e, { ...e, mediaId: 2, status: 'PLANNING' }] }] } })
    const list = await fetchAniListEntries('name')
    expect(list.map(e => e.mediaId)).toEqual([1, 2])
    expect(list[0]).toMatchObject({ finished: true, status: 'watching', progress: 3 })
    expect(m.gql.mock.calls[1]?.[1]).toEqual({ name: 'name', chunk: 2 })
  })
  it.each([['Private user', 'private'], ['User not found', 'not_found'], ['429', 'unavailable']])('classifies %s', async (message, reason) => {
    m.gql.mockRejectedValue(new Error(message))
    await expect(fetchAniListEntries('name')).rejects.toMatchObject({ reason })
  })
  it('maps MAL by id, deduplicates and reports unsupported rows', async () => {
    m.gql.mockResolvedValue({ Page: { media: [{ id: 100, idMal: 1 }] } })
    const mapped = await mapMalRows([{ malId: 1, status: 'Completed', watched: 26 }, { malId: 1, status: 'Watching', watched: 1 }, { malId: 2, status: 'Completed', watched: 1, title: 'Missing' }])
    expect(mapped.entries).toEqual([{ mediaId: 100, status: 'completed', finished: true, progress: 26, title: null }])
    expect(mapped.unmatched).toEqual(['Missing'])
  })
})
