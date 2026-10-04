import { describe, expect, it } from 'vitest'
import { currentUpcoming, releaseWindowEnd, resolveUpcomingWithCatalog } from './catalogUpcoming.js'
import { parseReleaseWindow } from './releaseWindow.js'
import { aniListEpisodes } from './mediaStore.js'
import { airDateToMs, deriveSeasonStatus, tmdbSeasonToMediaRow } from '../tmdb/mapping.js'
import { matchPart, sameInstallment } from '../news/installment.js'
import { parseNewsResult } from '../news/agent.js'
import type { FranchiseUpcoming } from '../types/api.js'

const NOW = Date.UTC(2026, 9, 4)
const source = 'https://www.aboutamazon.com/news/entertainment/show'
const news = (over: Partial<FranchiseUpcoming> = {}): FranchiseUpcoming => ({
  status: 'announced', next: 'Season 2', release: '2027', note: null, source,
  checked: new Date(NOW).toISOString(),
  evidence: [{ url: source, tier: 'official', primary: true, publisher: 'Amazon', publishedAt: null }], ...over,
})
const part = (status: string, label = 'Season 2') => ({ mediaId: 2, label, title: `Show ${label}`, status })

describe('claim lifecycle', () => {
  it('expires elapsed day, month, quarter and year windows without claiming the show ended', () => {
    for (const release of ['2026-10-01', 'September 2026', 'Summer 2026', '2025']) {
      expect(currentUpcoming(news({ release }), [], NOW), release).toBeNull()
    }
    for (const release of ['2026-10-04', 'October 2026', 'Fall 2026', 'Late 2026', '2027']) {
      expect(currentUpcoming(news({ release }), [], NOW), release).not.toBeNull()
    }
    expect(releaseWindowEnd('Q4 2026')).toBe(Date.UTC(2027, 0, 1))
  })
  it('retires TBA news about an installment the catalogue says is already out', () => {
    for (const status of ['FINISHED', 'CANCELLED', 'RELEASING']) {
      expect(currentUpcoming(news({ status: 'announced_no_date', release: 'TBA' }), [part(status)], NOW)).toBeNull()
    }
    expect(currentUpcoming(news(), [part('FINISHED', 'Season 1')], NOW)).not.toBeNull()
  })
  it('lets a genuine later season replace expired research', () => {
    const catalog = news({ next: 'Season 3' })
    expect(resolveUpcomingWithCatalog(news(), catalog, { parts: [part('FINISHED')], nowMs: NOW })).toBe(catalog)
  })
  it('recomputes provider-derived facts even when the provider now has no future season', () => {
    const saved = news({ source: 'https://www.themoviedb.org/tv/1' })
    expect(resolveUpcomingWithCatalog(saved, null, { nowMs: NOW })).toBeNull()
    const current = news({ release: '2028' })
    expect(resolveUpcomingWithCatalog(saved, current, { nowMs: NOW })).toBe(current)
  })
  it('expires unmatched airing claims, but retains a verified releasing part', () => {
    const old = news({ status: 'airing', checked: '2026-09-01', release: '2026-07-01' })
    expect(currentUpcoming(old, [], NOW)).toBeNull()
    expect(currentUpcoming(old, [part('RELEASING')], NOW)).toBe(old)
    expect(currentUpcoming(old, [part('FINISHED')], NOW)).toBeNull()
  })
})

describe('dates and installment identity', () => {
  it.each(['2026-02-29', '2026-02-30', '2026-04-31', '2026-13-01', '2026-00-15', '2026-01-00'])(
    'rejects impossible dates without rolling over or degrading precision: %s', date => {
      expect(airDateToMs(date)).toBeNull()
      expect(parseReleaseWindow(date).precision).toBe('unknown')
    },
  )
  it('accepts leap days only in leap years, throughout the supported range', () => {
    for (let year = 2000; year <= 2099; year++) {
      expect(airDateToMs(`${year}-02-29`) != null).toBe(year % 4 === 0)
      expect(parseReleaseWindow(`February 29, ${year}`).precision === 'day').toBe(year % 4 === 0)
    }
  })
  it('does not match Season 1 to Season 10 or merge different cours', () => {
    expect(matchPart('Season 1', [{ ...part('FINISHED'), label: 'Other', title: 'Show Season 10' }])).toBeNull()
    expect(matchPart('Season 2 Part 2', [part('NOT_YET_RELEASED')])).toBeNull()
    expect(sameInstallment('season 2', 'season 2 part 2')).toBe(false)
    expect(sameInstallment('season 2 part 1', 'season 1 part 2')).toBe(false)
  })
  it('uses actual episode numbers for reversed, sparse streaming entries', () => {
    const result = aniListEpisodes({ streamingEpisodes: [
      { title: 'Episode 12 - Finale', thumbnail: 'last' },
      { title: 'Episode 1 - Beginning', thumbnail: 'first' },
      { title: 'Unnumbered bonus', thumbnail: 'unknown' },
    ] } as never)
    expect(result[0]?.title).toBe('Beginning')
    expect(result[1]?.title).toBeNull()
    expect(result[11]?.title).toBe('Finale')
    expect(aniListEpisodes({ streamingEpisodes: [{ title: 'Unnumbered', thumbnail: 'x' }] } as never)).toEqual([])
  })
  it('does not turn an undated old season into an unaired season', () => {
    const show = { status: 'Ended', last_episode_to_air: { season_number: 8 }, seasons: [] }
    expect(deriveSeasonStatus(show as never, { season_number: 3, air_date: null } as never, NOW)).toBe('FINISHED')
    expect(deriveSeasonStatus(show as never, { season_number: 9, air_date: null } as never, NOW)).toBe('NOT_YET_RELEASED')
  })
  it('finds the actual finale in episode metadata, never the season premiere', () => {
    const show = { status: 'Ended', id: 1, name: 'Show', seasons: [], last_episode_to_air: { season_number: 2, air_date: '2026-03-01' } }
    const season = { id: 10, season_number: 1, air_date: '2025-01-01', episode_count: 2 }
    const result = tmdbSeasonToMediaRow(show as never, season as never, NOW, [
      { number: 1, airDate: airDateToMs('2025-01-01') }, { number: 2, airDate: airDateToMs('2025-01-08') },
    ] as never)
    expect(result.lastAiredAt).toBe(airDateToMs('2025-01-08'))
  })
  it('does not declare an incomplete active season finished during a schedule gap', () => {
    const show = { status: 'Returning Series', next_episode_to_air: null, last_episode_to_air: { season_number: 2, episode_number: 4, air_date: '2026-09-28' } }
    const season = { season_number: 2, air_date: '2026-09-01', episode_count: 12 }
    expect(deriveSeasonStatus(show as never, season as never, NOW)).toBe('RELEASING')
    expect(deriveSeasonStatus({ ...show, status: 'Ended' } as never, season as never, NOW)).toBe('FINISHED')
  })
})

describe('research publishing gate', () => {
  const result = (over = {}) => ({ ...news(), installmentScope: 'same_series', ...over })
  it('rejects absent, unsafe or unsupported evidence', () => {
    for (const over of [{ evidence: [] }, { source: 'http://untrusted.example' }, { source: 'https://different.example' }]) {
      expect(parseNewsResult(result(over), NOW)).toBeNull()
    }
    expect(parseNewsResult(result(), NOW)).not.toBeNull()
  })
  it('does not publish no-information as a conclusion', () => {
    expect(parseNewsResult(result({ installmentScope: 'none', status: 'unknown', next: '' }), NOW)).toBeNull()
  })
  it('does not launder an unknown main source through another link or call a fan wiki a catalogue', () => {
    expect(parseNewsResult(result({ evidence: [
      { url: source, tier: 'unknown', primary: false, publisher: null, publishedAt: null },
      { url: 'https://www.netflix.com/news/other', tier: 'official', primary: true, publisher: 'Netflix', publishedAt: null },
    ] }), NOW)).toBeNull()
    const wiki = 'https://www.detectiveconanworld.com/wiki/Movie_30'
    expect(parseNewsResult(result({ source: wiki, evidence: [
      { url: wiki, tier: 'catalogue', primary: false, publisher: null, publishedAt: null },
    ] }), NOW)).toBeNull()
  })
  it('rejects contradictory date precision and elapsed promises', () => {
    for (const over of [
      { status: 'upcoming_dated', release: '2027' }, { status: 'announced', release: 'TBA' },
      { status: 'announced_no_date', release: '2027' }, { status: 'upcoming_dated', release: '2026-02-30' },
      { status: 'announced', release: 'Summer 2026' },
    ]) expect(parseNewsResult(result(over), NOW)).toBeNull()
  })
})
