import { describe, expect, it } from 'vitest'
import {
  formatSubject,
  feedPostIdSchema,
  isPostSubject,
  parseSubject,
  postIdSchema,
  subjectSchema,
  threadSubjectSchema,
  type ParsedSubject,
} from './subjects.js'

const ANN = '0b6c1a2e-3f4d-4a5b-8c6d-7e8f9a0b1c2d'
const FRAN = '11111111-1111-4111-8111-111111111111'

describe('parseSubject / formatSubject — the one id grammar', () => {
  const cases: [string, ParsedSubject][] = [
    [`news:${ANN}`, { kind: 'news', announcementId: ANN }],
    ['catalog:171018', { kind: 'catalog', mediaId: 171018 }],
    ['catalog:2147483647', { kind: 'catalog', mediaId: 2147483647 }],
    [`trailer:${FRAN}:youtube:dQw4w9WgXcQ`, { kind: 'trailer', franchiseId: FRAN, site: 'youtube', videoId: 'dQw4w9WgXcQ' }],
    [`trailer:${FRAN}:vimeo:a_b-C9`, { kind: 'trailer', franchiseId: FRAN, site: 'vimeo', videoId: 'a_b-C9' }],
    ['ep:171018:12', { kind: 'episode', mediaId: 171018, episode: 12 }],
    ['ep:1:99999', { kind: 'episode', mediaId: 1, episode: 99999 }],
  ]

  it.each(cases)('round-trips %s', (raw, parsed) => {
    expect(parseSubject(raw)).toEqual(parsed)
    expect(formatSubject(parsed)).toBe(raw)
  })

  it('formats uuids and the trailer site lowercase, the canonical spelling', () => {
    expect(formatSubject({ kind: 'news', announcementId: ANN.toUpperCase() })).toBe(`news:${ANN}`)
    expect(formatSubject({ kind: 'trailer', franchiseId: FRAN, site: 'YouTube', videoId: 'AbC' })).toBe(
      `trailer:${FRAN}:youtube:AbC`,
    )
  })

  it.each([
    [`news:${ANN.toUpperCase()}`, 'an uppercase uuid'],
    ['news:not-a-uuid', 'a malformed uuid'],
    ['catalog:0', 'media id 0'],
    ['catalog:012', 'a leading zero'],
    ['catalog:2147483648', 'a media id past int4'],
    ['catalog:9999999999', 'a ten-digit id past int4'],
    ['ep:1:0', 'episode 0'],
    ['ep:1:100000', 'a six-digit episode'],
    ['ep:2147483648:1', 'an episode room past int4'],
    [`trailer:${FRAN}:youtube:a/b`, 'a slash in the video id'],
    [`trailer:${FRAN}:YouTube:abc`, 'an uppercase site'],
    [`trailer:${FRAN}:youtube:${'a'.repeat(65)}`, 'an over-long video id'],
    [`news:${ANN} `, 'trailing whitespace'],
    [`news:${ANN}x`, 'trailing garbage'],
    ['ep:1:2:3', 'an extra segment'],
    [' catalog:1', 'leading whitespace'],
    ['', 'the empty string'],
    ['thread:1', 'an unknown kind'],
  ])('rejects %s (%s)', (raw) => {
    expect(parseSubject(raw)).toBeNull()
  })

  it('never throws on non-strings smuggled through a JSON body', () => {
    expect(parseSubject(42 as unknown as string)).toBeNull()
    expect(parseSubject(undefined as unknown as string)).toBeNull()
  })
})

describe('isPostSubject', () => {
  it('is true for news, catalog and trailer; false for an episode room and for junk', () => {
    expect(isPostSubject(`news:${ANN}`)).toBe(true)
    expect(isPostSubject('catalog:5')).toBe(true)
    expect(isPostSubject(`trailer:${FRAN}:youtube:x`)).toBe(true)
    expect(isPostSubject('ep:5:1')).toBe(false)
    expect(isPostSubject('nope')).toBe(false)
    expect(isPostSubject({ kind: 'episode', mediaId: 5, episode: 1 })).toBe(false)
    expect(isPostSubject({ kind: 'catalog', mediaId: 5 })).toBe(true)
  })
})

describe('zod schemas', () => {
  it('threadSubjectSchema / subjectSchema accept all four kinds and keep the string', () => {
    for (const s of [`news:${ANN}`, 'catalog:5', `trailer:${FRAN}:youtube:x`, 'ep:5:1']) {
      expect(threadSubjectSchema.parse(s)).toBe(s)
      expect(subjectSchema.safeParse(s).success).toBe(true)
    }
    expect(threadSubjectSchema.safeParse('ep:5:0').success).toBe(false)
    expect(threadSubjectSchema.safeParse('x'.repeat(161)).success).toBe(false)
    expect(threadSubjectSchema.safeParse(5).success).toBe(false)
  })

  it('postIdSchema refuses an episode room', () => {
    expect(postIdSchema.safeParse(`news:${ANN}`).success).toBe(true)
    expect(postIdSchema.safeParse('ep:5:1').success).toBe(false)
  })

  it('feedPostIdSchema takes every post the feed carries, the episode post under its ep: subject included', () => {
    for (const id of [`news:${ANN}`, 'catalog:5', `trailer:${FRAN}:youtube:x`, 'ep:5:1']) {
      expect(feedPostIdSchema.safeParse(id).success, id).toBe(true)
    }
    for (const id of ['ep:5:0', 'ep:5', 'nope', `news:${ANN.toUpperCase()}`]) {
      expect(feedPostIdSchema.safeParse(id).success, id).toBe(false)
    }
  })
})
