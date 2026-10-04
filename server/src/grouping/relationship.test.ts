import { describe, expect, it } from 'vitest'
import type { AniListMedia, MediaFormat, RelationType } from '../anilist/types.js'
import { planAttach } from './attach.js'
import { planRelationshipBackfill, type StoredMember } from './backfill.js'
import { deterministicGroup } from './deterministic.js'
import type { GroupingInput } from './llm.js'
import {
  inverseRelation,
  isOptionalPart,
  nextSeasonNumber,
  partLabel,
  partRelationship,
  partRoles,
  type RelationEdge,
} from './relationship.js'

const edge = (from: number, type: string, to: number): RelationEdge => ({ from, to, type })

function media(
  id: number,
  opts: { format?: MediaFormat; year?: number; title?: string; rel?: [RelationType, number][] } = {},
): AniListMedia {
  return {
    id,
    title: { romaji: opts.title ?? `Title ${id}`, english: opts.title ?? `Title ${id}` },
    coverImage: { extraLarge: null, large: null },
    bannerImage: null,
    description: null,
    genres: [],
    episodes: 12,
    format: opts.format ?? 'TV',
    status: 'FINISHED',
    season: 'SPRING',
    seasonYear: opts.year ?? 2016,
    popularity: 0,
    trending: 0,
    nextAiringEpisode: null,
    relations: {
      edges: (opts.rel ?? []).map(([relationType, nodeId]) => ({
        relationType,
        node: { id: nodeId, type: 'ANIME', format: 'TV' },
      })),
    },
  } as AniListMedia
}

describe('inverseRelation', () => {
  it('turns a relation round to the other member', () => {
    expect(inverseRelation('SEQUEL')).toBe('PREQUEL')
    expect(inverseRelation('PREQUEL')).toBe('SEQUEL')
    expect(inverseRelation('PARENT')).toBe('SIDE_STORY')
    expect(inverseRelation('SIDE_STORY')).toBe('PARENT')
    expect(inverseRelation('SPIN_OFF')).toBe('PARENT')
    expect(inverseRelation('ALTERNATIVE')).toBe('ALTERNATIVE')
    expect(inverseRelation('SOMETHING_NEW')).toBe('SOMETHING_NEW')
  })
})

describe('partRelationship', () => {
  it('reads an edge pointing at the part as written, and the part’s own edge inverted', () => {
    const edges = [edge(1, 'SEQUEL', 2)]
    expect(partRelationship(2, edges)).toBe('SEQUEL')
    expect(partRelationship(1, edges)).toBe('PREQUEL')
  })

  it('a part whose one tie is "my PARENT is the series" is a side story, not a parent (Re:ZERO’s shorts)', () => {
    // The series does not list the shorts; the shorts name the series as their parent.
    const edges = [edge(1, 'SEQUEL', 2), edge(2, 'PREQUEL', 1), edge(90, 'PARENT', 2)]
    expect(partRelationship(90, edges)).toBe('SIDE_STORY')
    expect(isOptionalPart(partRelationship(90, edges), 'ona')).toBe(true)
  })

  it('a season that HAS a side story is still a sequel, not a side story (One-Punch Man Season 2)', () => {
    const edges = [edge(1, 'SEQUEL', 2), edge(2, 'PREQUEL', 1), edge(2, 'SIDE_STORY', 50), edge(50, 'PARENT', 2)]
    expect(partRelationship(2, edges)).toBe('SEQUEL')
    expect(isOptionalPart(partRelationship(2, edges), 'season')).toBe(false)
    expect(partRelationship(50, edges)).toBe('SIDE_STORY')
  })

  it('keeps the parent’s own word for a child over the child’s "my parent is…"', () => {
    const edges = [edge(1, 'SPIN_OFF', 70), edge(70, 'PARENT', 1)]
    expect(partRoles(70, edges)).toEqual(['SPIN_OFF'])
    expect(partRelationship(70, edges)).toBe('SPIN_OFF')
  })

  it('a side story with a sequel of its own stays a side story', () => {
    const edges = [edge(1, 'SIDE_STORY', 50), edge(50, 'SEQUEL', 51), edge(51, 'PREQUEL', 50), edge(51, 'PARENT', 1)]
    expect(partRelationship(50, edges)).toBe('SIDE_STORY')
    expect(partRelationship(51, edges)).toBe('SIDE_STORY')
  })

  it('never answers PARENT: a part that only has children is a root', () => {
    // The child says so itself ("my parent is 1") …
    const edges = [edge(1, 'SIDE_STORY', 50), edge(50, 'PARENT', 1)]
    expect(partRoles(1, edges)).toEqual(['PARENT'])
    expect(partRelationship(1, edges)).toBeNull()
    // … or it does not list back, and the parent's own edge is all there is.
    expect(partRoles(1, [edge(1, 'SIDE_STORY', 50)])).toEqual(['PARENT'])
    expect(partRelationship(1, [edge(1, 'SIDE_STORY', 50)])).toBeNull()
  })

  it('a part that follows another is a SEQUEL whatever order the edges arrive in', () => {
    // The middle season is both a sequel (of the first) and a prequel (of the third).
    const forward = [edge(1, 'SEQUEL', 2), edge(3, 'PREQUEL', 2), edge(2, 'SEQUEL', 3)]
    const backward = [...forward].reverse()
    expect(partRelationship(2, forward)).toBe('SEQUEL')
    expect(partRelationship(2, backward)).toBe('SEQUEL')
    expect(partRelationship(1, forward)).toBe('PREQUEL')
  })

  it('what is optional: a child of the story, a special, a music video — never a season that has one', () => {
    expect(isOptionalPart('SIDE_STORY', 'ova')).toBe(true)
    expect(isOptionalPart('SPIN_OFF', 'season')).toBe(true)
    expect(isOptionalPart(null, 'special')).toBe(true)
    expect(isOptionalPart(null, 'music')).toBe(true)
    expect(isOptionalPart('SEQUEL', 'season')).toBe(false)
    expect(isOptionalPart(null, 'movie')).toBe(false)
  })

  it('falls back to whatever else the catalogue says', () => {
    expect(partRelationship(9, [edge(1, 'ALTERNATIVE', 9)])).toBe('ALTERNATIVE')
    expect(partRelationship(9, [])).toBeNull()
  })
})

describe('labels', () => {
  it('writes initialisms as initialisms', () => {
    expect(partLabel('ona', 4)).toBe('ONA 4')
    expect(partLabel('ova', 2)).toBe('OVA 2')
    expect(partLabel('season', 3)).toBe('Season 3')
    expect(partLabel('movie', 1)).toBe('Movie 1')
  })

  it('numbers the next season after the highest season labelled, not after the sequence', () => {
    const labels = ['Season 1', 'Season 2 Part 1', 'Season 2 Part 2', 'Season 3', 'Season 4', 'Break Time']
    expect(nextSeasonNumber(labels, 8)).toBe(5)
    expect(nextSeasonNumber(['Final Season', null], 3)).toBe(3)
  })
})

describe('deterministicGroup relationships', () => {
  it('stores what each part is: sequel seasons, side-story extras, and never PARENT', () => {
    const input: GroupingInput = {
      candidates: [
        { id: 1, title: 'Show', format: 'TV', status: 'FINISHED', seasonYear: 2016, season: 'SPRING', episodes: 25, synopsis: '' },
        { id: 2, title: 'Show 2', format: 'TV', status: 'FINISHED', seasonYear: 2020, season: 'SUMMER', episodes: 13, synopsis: '' },
        { id: 50, title: 'Show OVA', format: 'OVA', status: 'FINISHED', seasonYear: 2018, season: 'FALL', episodes: 1, synopsis: '' },
        { id: 90, title: 'Show Shorts', format: 'ONA', status: 'FINISHED', seasonYear: 2020, season: 'SUMMER', episodes: 13, synopsis: '' },
      ],
      edges: [
        edge(1, 'SEQUEL', 2), edge(2, 'PREQUEL', 1),
        edge(1, 'SIDE_STORY', 50), edge(50, 'PARENT', 1),
        // The second season has a side story of its own — and the shorts name it as their parent.
        edge(90, 'PARENT', 2),
      ],
    }
    const parts = new Map(deterministicGroup(input).franchises[0]!.parts.map((part) => [part.id, part]))
    expect(parts.get(1)).toMatchObject({ relationship: null, optional: false, label: 'Season 1' })
    expect(parts.get(2)).toMatchObject({ relationship: 'SEQUEL', optional: false, label: 'Season 2' })
    expect(parts.get(50)).toMatchObject({ relationship: 'SIDE_STORY', optional: true, label: 'OVA 1' })
    expect(parts.get(90)).toMatchObject({ relationship: 'SIDE_STORY', optional: true, label: 'ONA 1' })
  })
})

describe('planAttach', () => {
  // Re:ZERO as it stood: four seasons (the second in two parts), then the catalogue lists the
  // shorts that air beside them and, later, a fifth season.
  const existing = [
    { partKind: 'season', sequence: 1, watchOrder: 1, label: 'Season 1' },
    { partKind: 'season', sequence: 2, watchOrder: 2, label: 'Season 2 Part 1' },
    { partKind: 'season', sequence: 3, watchOrder: 3, label: 'Season 2 Part 2' },
    { partKind: 'season', sequence: 4, watchOrder: 4, label: 'Season 3' },
    { partKind: 'season', sequence: 5, watchOrder: 5, label: 'Season 4' },
  ]
  const already = new Set([1, 2, 3, 4, 5])
  const component = new Map<number, AniListMedia>([
    [1, media(1, { year: 2016, rel: [['SEQUEL', 2]] })],
    [5, media(5, { year: 2026, rel: [['PREQUEL', 4], ['SEQUEL', 6]] })],
    [6, media(6, { year: 2027, rel: [['PREQUEL', 5]] })],
    [80, media(80, { format: 'TV_SHORT', year: 2016, title: 'Starting Break Time From Zero', rel: [['PARENT', 1]] })],
    [94, media(94, { format: 'ONA', year: 2026, rel: [['PARENT', 5]] })],
  ])

  it('attaches the shorts as named, optional side stories and the new season as the next number', () => {
    const planned = new Map(planAttach(existing, component, already).map((member) => [member.mediaId, member]))
    expect(planned.get(80)).toMatchObject({
      partKind: 'season', relationship: 'SIDE_STORY', optional: true, label: 'Starting Break Time From Zero',
    })
    expect(planned.get(94)).toMatchObject({ partKind: 'ona', relationship: 'SIDE_STORY', optional: true, label: 'ONA 1' })
    expect(planned.get(6)).toMatchObject({ partKind: 'season', relationship: 'SEQUEL', optional: false, label: 'Season 5' })
  })

  it('orders new members after the existing ones, in catalogue order', () => {
    const planned = planAttach(existing, component, already)
    expect(planned.map((member) => member.mediaId)).toEqual([80, 94, 6])
    expect(planned.map((member) => member.watchOrder)).toEqual([6, 7, 8])
  })

  it('plans nothing when every member is already there', () => {
    expect(planAttach(existing, new Map([[1, media(1)]]), already)).toEqual([])
  })
})

describe('planRelationshipBackfill', () => {
  const member = (mediaId: number, over: Partial<StoredMember>): StoredMember => ({
    mediaId, partKind: 'season', watchOrder: mediaId, relationship: null, optional: false,
    label: null, format: 'TV', title: null, ...over,
  })

  it('repairs what the old inversion stored and leaves the rest alone', () => {
    const members = [
      member(1, { label: 'Season 1' }),
      // A season with a side story of its own was stored as a side story, and optional.
      member(2, { label: 'Season 2', relationship: 'SIDE_STORY', optional: true }),
      member(3, { label: 'Season 3', relationship: 'SEQUEL' }),
      member(50, { partKind: 'ova', label: 'OVA', relationship: 'SIDE_STORY', optional: true, format: 'OVA' }),
      // The shorts: attached later, stored as PARENT, labelled mechanically.
      member(80, { label: 'Season 6', relationship: 'PARENT', format: 'TV_SHORT', title: 'Break Time' }),
      member(94, { partKind: 'ona', label: 'Ona 4', relationship: 'PARENT', format: 'ONA' }),
    ]
    const edges = [
      edge(1, 'SEQUEL', 2), edge(2, 'PREQUEL', 1), edge(2, 'SEQUEL', 3), edge(3, 'PREQUEL', 2),
      edge(2, 'SIDE_STORY', 50), edge(50, 'PARENT', 2),
      edge(80, 'PARENT', 1), edge(94, 'PARENT', 3),
    ]
    expect(planRelationshipBackfill(members, edges)).toEqual([
      { mediaId: 2, relationship: { from: 'SIDE_STORY', to: 'SEQUEL' }, optional: { from: true, to: false } },
      {
        mediaId: 80,
        relationship: { from: 'PARENT', to: 'SIDE_STORY' },
        optional: { from: false, to: true },
        label: { from: 'Season 6', to: 'Break Time' },
      },
      {
        mediaId: 94,
        relationship: { from: 'PARENT', to: 'SIDE_STORY' },
        optional: { from: false, to: true },
        label: { from: 'Ona 4', to: 'ONA 4' },
      },
    ])
  })

  it('keeps what is merely spelled another way: the root\u2019s chain word, a special nobody relates', () => {
    const members = [
      // The first migration stored PREQUEL for a first season; the grouper stores nothing.
      member(1, { label: 'Season 1', relationship: 'PREQUEL' }),
      member(2, { label: 'Season 2', relationship: 'SEQUEL' }),
      member(7, { partKind: 'special', label: 'Special 1', relationship: 'SPECIAL', optional: true, format: 'SPECIAL' }),
    ]
    const edges = [edge(1, 'SEQUEL', 2), edge(2, 'PREQUEL', 1)]
    expect(planRelationshipBackfill(members, edges)).toEqual([])
    // A grouper-written root (nothing stored) is not given the chain word either.
    expect(planRelationshipBackfill([member(1, {}), member(2, { relationship: 'SEQUEL' })], edges)).toEqual([])
  })

  it('clears a first season stored as PARENT, and leaves an earliest member that is a side story alone', () => {
    // Toradora!: the season's side stories point at it, so the migration stored PARENT.
    const parent = [member(1, { label: 'Season 1', relationship: 'PARENT' }),
                    member(50, { partKind: 'ova', label: 'OVA', relationship: 'SIDE_STORY', optional: true, format: 'OVA' })]
    expect(planRelationshipBackfill(parent, [edge(1, 'SIDE_STORY', 50), edge(50, 'PARENT', 1)]))
      .toEqual([{ mediaId: 1, relationship: { from: 'PARENT', to: null } }])
    // One Piece: the 1998 special is the earliest member and a side story of the series.
    const early = [member(1, { partKind: 'ova', label: 'Defeat the Pirate Ganzack!', relationship: 'SIDE_STORY', optional: true, format: 'OVA' }),
                   member(2, { label: 'TV Series', relationship: 'PARENT' })]
    expect(planRelationshipBackfill(early, [edge(2, 'SIDE_STORY', 1), edge(1, 'PARENT', 2)]))
      .toEqual([{ mediaId: 2, relationship: { from: 'PARENT', to: null } }])
  })

  it('is idempotent: a repaired franchise plans nothing', () => {
    const members = [
      member(1, { label: 'Season 1' }),
      member(2, { label: 'Season 2', relationship: 'SEQUEL' }),
      member(94, { partKind: 'ona', label: 'ONA 1', relationship: 'SIDE_STORY', optional: true, format: 'ONA' }),
    ]
    const edges = [edge(1, 'SEQUEL', 2), edge(2, 'PREQUEL', 1), edge(94, 'PARENT', 2)]
    expect(planRelationshipBackfill(members, edges)).toEqual([])
  })

  it('never rewrites a label a model or a person wrote', () => {
    const members = [
      member(1, { label: 'Season 1' }),
      // A TV season the catalogue files as a side story keeps its name; only a SHORT-FORM child
      // wearing a bare "Season N" is renamed.
      member(2, { label: 'Season 2', relationship: 'SIDE_STORY', optional: true }),
      member(3, { label: 'The Diaries (Spin-off)', relationship: 'SPIN_OFF', optional: true, format: 'TV_SHORT', title: 'Diaries' }),
    ]
    const edges = [edge(1, 'SIDE_STORY', 2), edge(1, 'SPIN_OFF', 3)]
    expect(planRelationshipBackfill(members, edges)).toEqual([])
  })
})
