import { describe, expect, it, vi } from 'vitest'

vi.mock('../db/index.js', () => ({ db: {} }))

const { FranchiseProgressError, progressWritesForCommand } = await import('./library.js')

// Fixed "now": 2026-09-25T12:00Z, passed explicitly — the aired count reads no clock here.
const NOW = Date.UTC(2026, 8, 25, 12)
const sec = (ms: number) => Math.floor(ms / 1000)

const rows = [
  {
    mediaId: 1,
    source: 'anilist',
    status: 'FINISHED',
    episodes: 12,
    next: null,
    episodesList: [],
  },
  {
    // Releasing, 24 planned, episode 8 is next and still in the future: 7 aired.
    mediaId: 2,
    source: 'anilist',
    status: 'RELEASING',
    episodes: 24,
    next: { episode: 8, airingAt: sec(NOW + 3 * 86_400_000) },
    episodesList: [],
  },
  {
    mediaId: 3,
    source: 'anilist',
    status: 'NOT_YET_RELEASED',
    episodes: 10,
    next: { episode: 1, airingAt: sec(NOW + 30 * 86_400_000) },
    episodesList: [],
  },
  {
    // Releasing, and the hourly sync has not caught up: "episode 5 next" struck 20 minutes ago.
    mediaId: 4,
    source: 'anilist',
    status: 'RELEASING',
    episodes: 12,
    next: { episode: 5, airingAt: sec(NOW - 20 * 60_000) },
    episodesList: [],
  },
]

describe('progressWritesForCommand', () => {
  it('marks released episodes caught up without claiming an announced season was watched', () => {
    expect(progressWritesForCommand(rows, { mode: 'caught_up' }, NOW)).toEqual([
      { mediaId: 1, episodes: 12 },
      { mediaId: 2, episodes: 7 },
      { mediaId: 3, episodes: 0 },
      // The stale-but-passed slot counts: caught up means through episode 5, not 4.
      { mediaId: 4, episodes: 5 },
    ])
  })

  it('resets every part to 0', () => {
    expect(progressWritesForCommand(rows, { mode: 'reset' }, NOW).map((w) => w.episodes)).toEqual([0, 0, 0, 0])
  })

  it('clamps explicit updates to each part ceiling — a releasing part to what has aired, not its size', () => {
    expect(progressWritesForCommand(rows, { parts: [
      { mediaId: 1, episodes: 99 },
      { mediaId: 2, episodes: 9 },
      { mediaId: 4, episodes: 12 },
    ] }, NOW)).toEqual([
      { mediaId: 1, episodes: 12 },
      { mediaId: 2, episodes: 7 },
      { mediaId: 4, episodes: 5 },
    ])
  })

  it('never lets a season that has not premiered hold progress', () => {
    expect(progressWritesForCommand(rows, { parts: [{ mediaId: 3, episodes: 5 }] }, NOW)).toEqual([
      { mediaId: 3, episodes: 0 },
    ])
  })

  it('never pulls a stored mark down: caught up keeps a legacy over-mark, an explicit write can step below it', () => {
    // Part 2 has 7 aired; a mark of 12 was written before the aired ceiling existed.
    const held = rows.map((row) => (row.mediaId === 2 ? { ...row, watched: 12 } : row))
    expect(progressWritesForCommand(held, { mode: 'caught_up' }, NOW).find((w) => w.mediaId === 2)).toEqual({
      mediaId: 2,
      episodes: 12,
    })
    // Unmarking 12 → 11 writes 11, not 7; climbing past what it holds is still refused.
    expect(progressWritesForCommand(held, { parts: [{ mediaId: 2, episodes: 11 }] }, NOW)).toEqual([
      { mediaId: 2, episodes: 11 },
    ])
    expect(progressWritesForCommand(held, { parts: [{ mediaId: 2, episodes: 20 }] }, NOW)).toEqual([
      { mediaId: 2, episodes: 12 },
    ])
    // Only a reset walks it back.
    expect(progressWritesForCommand(held, { mode: 'reset' }, NOW).find((w) => w.mediaId === 2)?.episodes).toBe(0)
  })

  it('caught up on a releasing part in a schedule gap (no slot, no dates) marks its size, not 0', () => {
    const gap = [{ mediaId: 5, source: 'anilist', status: 'RELEASING', episodes: 12, next: null, episodesList: [] }]
    expect(progressWritesForCommand(gap, { mode: 'caught_up' }, NOW)).toEqual([{ mediaId: 5, episodes: 12 }])
  })

  it('rejects foreign and duplicate media ids before the transaction can partially write', () => {
    expect(() => progressWritesForCommand(rows, { parts: [{ mediaId: 99, episodes: 1 }] }, NOW))
      .toThrow(FranchiseProgressError)
    expect(() => progressWritesForCommand(rows, { parts: [
      { mediaId: 1, episodes: 1 }, { mediaId: 1, episodes: 2 },
    ] }, NOW)).toThrow(FranchiseProgressError)
  })
})

// The status a progress write leaves a show in (9 Oct 2026: a Planned show finished in one write
// stayed Planned for good — see `derivedStatusAfterProgress`).
const { derivedStatusAfterProgress, statusAfterWrites, storyWatchedThrough } = await import('./library.js')

type Member = import('./library.js').StatusMemberRow
function member(mediaId: number, over: Partial<Member> = {}): Member {
  return {
    mediaId, source: 'anilist', status: 'FINISHED', episodes: 12, next: null, episodesList: [],
    watched: 0, partKind: 'season', relationship: 'SEQUEL', optional: false, ...over,
  }
}

describe('derivedStatusAfterProgress', () => {
  it('files a Planned or Watching show under Watched once the story is through', () => {
    expect(derivedStatusAfterProgress('planned', { forward: true, watchedThrough: true })).toBe('completed')
    expect(derivedStatusAfterProgress('watching', { forward: true, watchedThrough: true })).toBe('completed')
    // A backward write that still leaves the story through (an over-mark trimmed) counts too.
    expect(derivedStatusAfterProgress('watching', { forward: false, watchedThrough: true })).toBe('completed')
  })

  it('moves a Planned show to Watching on a forward mark that does not finish it', () => {
    expect(derivedStatusAfterProgress('planned', { forward: true, watchedThrough: false })).toBe('watching')
    expect(derivedStatusAfterProgress('planned', { forward: false, watchedThrough: false })).toBeNull()
  })

  it('leaves Watched, Paused and Dropped alone, and a show not in the library', () => {
    for (const status of ['completed', 'paused', 'dropped'] as const) {
      expect(derivedStatusAfterProgress(status, { forward: true, watchedThrough: true })).toBeNull()
      expect(derivedStatusAfterProgress(status, { forward: true, watchedThrough: false })).toBeNull()
    }
    expect(derivedStatusAfterProgress(null, { forward: true, watchedThrough: true })).toBeNull()
    expect(derivedStatusAfterProgress(undefined, { forward: true, watchedThrough: true })).toBeNull()
  })
})

describe('statusAfterWrites', () => {
  it('Seven Dials: one finished season, Planned, marked 3 of 3 in one write → Watched', () => {
    const rows = [member(1, { source: 'tmdb', episodes: 3, relationship: null })]
    expect(statusAfterWrites('planned', rows, [{ mediaId: 1, episodes: 3 }], NOW)).toBe('completed')
  })

  it('a Planned show marked part-way is being watched', () => {
    const rows = [member(1), member(2)]
    expect(statusAfterWrites('planned', rows, [{ mediaId: 1, episodes: 4 }], NOW)).toBe('watching')
    // Finishing one season of two is still part-way.
    expect(statusAfterWrites('planned', rows, [{ mediaId: 1, episodes: 12 }], NOW)).toBe('watching')
  })

  it('a Watching show whose last season is finished by the write is Watched', () => {
    const rows = [member(1, { watched: 12 }), member(2, { watched: 11 })]
    expect(statusAfterWrites('watching', rows, [{ mediaId: 2, episodes: 12 }], NOW)).toBe('completed')
  })

  it('a show with a season still releasing or announced is never filed Watched by the server', () => {
    const releasing = [member(1, { watched: 12 }), member(2, { status: 'RELEASING', episodes: 12,
      next: { episode: 8, airingAt: sec(NOW + 3 * 86_400_000) } })]
    expect(statusAfterWrites('watching', releasing, [{ mediaId: 2, episodes: 7 }], NOW)).toBeNull()
    const announced = [member(1, { watched: 11 }), member(2, { status: 'NOT_YET_RELEASED', episodes: null })]
    expect(statusAfterWrites('watching', announced, [{ mediaId: 1, episodes: 12 }], NOW)).toBeNull()
    // Planned, though, is still being watched after a forward mark.
    expect(statusAfterWrites('planned', releasing, [{ mediaId: 2, episodes: 7 }], NOW)).toBe('watching')
  })

  it('a reset or an unmark moves nothing', () => {
    const rows = [member(1, { watched: 12 })]
    expect(statusAfterWrites('planned', rows, [{ mediaId: 1, episodes: 0 }], NOW)).toBeNull()
    expect(statusAfterWrites('watching', rows, [{ mediaId: 1, episodes: 11 }], NOW)).toBeNull()
  })

  it('a non-optional OVA or film in the story holds the show open; a side story or spin-off does not', () => {
    const ova = [member(1, { watched: 12 }), member(2, { partKind: 'ova', episodes: 2, relationship: 'SEQUEL' })]
    // Conservative: the server stays silent and lets the device's finer rule decide.
    expect(statusAfterWrites('watching', ova, [{ mediaId: 1, episodes: 12 }], NOW)).toBeNull()
    const side = [member(1, { watched: 11 }), member(2, { partKind: 'ova', episodes: 2, relationship: 'SIDE_STORY', optional: true })]
    expect(statusAfterWrites('watching', side, [{ mediaId: 1, episodes: 12 }], NOW)).toBe('completed')
    const spinOff = [member(1, { watched: 11 }), member(2, { relationship: 'SPIN_OFF' })]
    expect(statusAfterWrites('watching', spinOff, [{ mediaId: 1, episodes: 12 }], NOW)).toBe('completed')
  })

  it('a franchise of films is through when its films are watched', () => {
    const films = [member(1, { partKind: 'movie', episodes: 1, relationship: null }), member(2, { partKind: 'movie', episodes: 1 })]
    expect(statusAfterWrites('planned', films, [{ mediaId: 1, episodes: 1 }, { mediaId: 2, episodes: 1 }], NOW)).toBe('completed')
    expect(statusAfterWrites('planned', films, [{ mediaId: 1, episodes: 1 }], NOW)).toBe('watching')
  })

  it('an unsized part is not through (nothing to measure against)', () => {
    const rows = [member(1, { episodes: null, watched: 0 })]
    expect(storyWatchedThrough(rows, new Map([[1, 5]]), NOW)).toBe(false)
  })
})
