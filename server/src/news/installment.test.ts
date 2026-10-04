import { describe, expect, it } from 'vitest'
import {
  announcedPart,
  announcementForPart,
  dedupeKey,
  installmentKey,
  installmentName,
  matchPart,
  sameInstallment,
  type MatchablePart,
} from './installment.js'

function part(mediaId: number, label: string, title = '', status: string | null = 'FINISHED'): MatchablePart {
  return { mediaId, label, title, status }
}

describe('dedupeKey / sameInstallment (moved from news/service.ts unchanged)', () => {
  it('collapses case and punctuation to one ASCII key', () => {
    expect(dedupeKey('Season 4')).toBe('season 4')
    expect(dedupeKey('season 4!')).toBe('season 4')
    expect(dedupeKey('  SEASON   4  ')).toBe('season 4')
    expect(dedupeKey('Infinity Castle - Part 2 (movie)')).toBe('infinity castle part 2 movie')
  })

  it('treats a reworded installment as the same one when one key contains the other', () => {
    expect(sameInstallment('season 4', 'season 4')).toBe(true)
    expect(sameInstallment('season 4', 'season 4 the culling game')).toBe(true)
    expect(sameInstallment('season 4 the culling game', 'season 4')).toBe(true)
    expect(sameInstallment('season 4', 'season 4 part 2')).toBe(false)
    expect(sameInstallment('season 4', 'season 5')).toBe(false)
    expect(sameInstallment('', 'season 4')).toBe(false)
  })
})

describe('installmentKey', () => {
  it('drops "(movie)", lowercases and keys on letters and numbers in any script', () => {
    expect(installmentKey('Infinity Castle - Part 2 (movie)')).toBe('infinity castle part 2')
    expect(installmentKey('Mugen Train (Movie)')).toBe('mugen train')
    expect(installmentKey('Season 2: Swordsmith Village!')).toBe('season 2 swordsmith village')
    expect(installmentKey('Ōkami — 第2期')).toBe('ōkami 第2期')
    expect(installmentKey('---')).toBe('')
  })
})

describe('installmentName', () => {
  it('names the installment without the movie marker', () => {
    expect(installmentName('Infinity Castle - Part 2 (movie)')).toEqual({ name: 'Infinity Castle - Part 2', isMovie: true })
    expect(installmentName('Mugen Train(movie)')).toEqual({ name: 'Mugen Train', isMovie: true })
    expect(installmentName(' Season 2 ')).toEqual({ name: 'Season 2', isMovie: false })
  })
})

describe('matchPart', () => {
  it('matches an exact label first', () => {
    const parts = [part(1, 'Season 1', 'Show'), part(2, 'Season 2', 'Show Season 2')]
    expect(matchPart('Season 2', parts)?.mediaId).toBe(2)
    expect(matchPart('season 2!', parts)?.mediaId).toBe(2)
  })

  it('falls back to a title that contains the name', () => {
    const parts = [part(1, 'Season 1', 'Demon Slayer'), part(2, 'Movie', 'Demon Slayer: Infinity Castle Part 2')]
    expect(matchPart('Infinity Castle Part 2', parts)?.mediaId).toBe(2)
  })

  it('matches a label inside the name only for a part that has not been released', () => {
    const released = [part(1, 'Season 2', 'Show', 'FINISHED')]
    expect(matchPart('Season 2: Swordsmith Village', released)).toBeNull()
    const announced = [part(1, 'Season 2', 'Show', 'NOT_YET_RELEASED')]
    expect(matchPart('Season 2: Swordsmith Village', announced)?.mediaId).toBe(1)
    // An empty label never matches "inside" anything.
    expect(matchPart('Season 2', [part(3, '', 'Unrelated', 'NOT_YET_RELEASED')])).toBeNull()
  })

  it('returns null for an empty key', () => {
    expect(matchPart('', [part(1, 'Season 1')])).toBeNull()
    expect(matchPart(' (movie) ', [part(1, 'Season 1')])).toBeNull()
  })

  it('takes the first part in watch order when several match', () => {
    const parts = [
      part(10, 'Part 1', 'Final Season Part 2 Special', 'FINISHED'),
      part(11, 'Part 2', 'Final Season Part 2', 'FINISHED'),
    ]
    // Neither label is "Final Season Part 2"; both titles contain it, so the first in order wins.
    expect(matchPart('Final Season Part 2', parts)?.mediaId).toBe(10)
  })

  it('prefers an exact label anywhere over an earlier title match', () => {
    const parts = [part(1, 'Season 1', 'Show Season 2 Preview'), part(2, 'Season 2', 'Show')]
    expect(matchPart('Season 2', parts)?.mediaId).toBe(2)
  })
})

describe('announcedPart / announcementForPart (the one announcement ↔ part rule)', () => {
  const s1 = part(1, 'Season 1')
  const s1p2 = part(2, 'Season 1 Part 2', '', 'NOT_YET_RELEASED')
  const s2 = part(3, 'Season 2')
  const s2p2 = part(4, 'Season 2 Part 2', '', 'NOT_YET_RELEASED')
  const parts = [s1, s1p2, s2, s2p2]
  const ann = (id: string, next: string) => ({ id, next })

  it('names the part matchPart finds for the installment, "(movie)" dropped', () => {
    expect(announcedPart('Season 2 Part 2', parts)?.mediaId).toBe(4)
    expect(announcedPart('Season 2 Part 2 (movie)', parts)?.mediaId).toBe(4)
    expect(announcedPart('Season 9', parts)).toBeNull()
  })

  it('never hands a later part the old season\'s announcement (sameInstallment would)', () => {
    // "season 2" ⊂ "season 2 part 2": the announcement table's subset rule calls them one installment.
    expect(sameInstallment(dedupeKey('Season 2'), dedupeKey(s2p2.label))).toBe(false)
    expect(announcementForPart(s2p2, [ann('a', 'Season 2')], parts)).toBeNull()
    expect(announcementForPart(s2, [ann('a', 'Season 2')], parts)?.id).toBe('a')
  })

  it('agrees with adoption where the old alias disagreed ("Part 2" against "Season 1 Part 2")', () => {
    // The old alias said yes (token subset) while adoption's part matcher found no part, so the feed
    // showed `news:<A>` and the rows stayed on `catalog:<M>`. Now both read one answer: no.
    expect(sameInstallment(dedupeKey('Part 2'), dedupeKey(s1p2.label))).toBe(false)
    expect(announcedPart('Part 2', parts)).toBeNull()
    expect(announcementForPart(s1p2, [ann('a', 'Part 2')], parts)).toBeNull()
    // With the part's title carrying the name, both say yes.
    const titled = [s1, part(2, 'Season 1 Part 2', 'Show Part 2', 'NOT_YET_RELEASED')]
    expect(announcementForPart(titled[1]!, [ann('a', 'Part 2')], titled)?.id).toBe('a')
  })

  it('takes the FIRST announcement in the order given and skips empty installments', () => {
    const list = [ann('blank', '  '), ann('old', 'Season 2 Part 2'), ann('new', 'Season 2 Part 2 (movie)')]
    expect(announcementForPart(s2p2, list, parts)?.id).toBe('old')
    expect(announcementForPart(s1, list, parts)).toBeNull()
  })
})
