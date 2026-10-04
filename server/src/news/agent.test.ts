import { describe, expect, it } from 'vitest'
import { buildNewsPrompt, parseNewsResult, type NewsResearchInput } from './agent.js'

const base = (catalogueSource: NewsResearchInput['catalogueSource']): NewsResearchInput => ({
  title: catalogueSource === 'tmdb' ? 'Selling Sunset' : 'Bleach',
  catalogueSource,
  knownParts: [],
  current: null,
  knownAnnouncements: [],
})

describe('buildNewsPrompt', () => {
  it('uses television authorities and language for TMDB franchises', () => {
    const prompt = buildNewsPrompt(base('tmdb'))
    expect(prompt).toContain('television series "Selling Sunset"')
    expect(prompt).toContain('Netflix Tudum')
    expect(prompt).toContain('Deadline')
    expect(prompt).toContain('NOT_YET_RELEASED')
    expect(prompt).toContain('report and verify that installment first')
    expect(prompt).toContain('official primary')
    expect(prompt).toContain('evidence')
    expect(prompt).not.toContain('anime franchise "Selling Sunset"')
  })

  it('keeps anime-specific authorities for AniList franchises', () => {
    const prompt = buildNewsPrompt(base('anilist'))
    expect(prompt).toContain('anime franchise "Bleach"')
    expect(prompt).toContain('Anime News Network')
    expect(prompt).toContain('Crunchyroll News')
  })

  it('corrects a prior spin-off belief instead of requiring its name to be reused', () => {
    const prompt = buildNewsPrompt({ ...base('tmdb'), title: 'The Boys', knownAnnouncements: ['Vought Rising (announced)'] })
    expect(prompt).toContain('its announcement does NOT mean the original series is returning')
    expect(prompt).toContain('Correct prior mistakes')
    expect(prompt).toContain('none for concluded/recently_aired')
  })
})

describe('research identity validation', () => {
  const finding = {
    installmentScope: 'separate_series', status: 'announced', next: 'Vought Rising', release: '2027',
    note: 'Prime Video announced a separately titled prequel to The Boys.',
    source: 'https://www.aboutamazon.com/news/entertainment/the-boys-vought-rising-prime-video',
    evidence: [{ url: 'https://www.aboutamazon.com/news/entertainment/the-boys-vought-rising-prime-video', tier: 'official', primary: true, publisher: 'Amazon', publishedAt: null }],
  }

  it('rejects spin-off research before it can change the parent status or fan out news', () => {
    expect(parseNewsResult(finding)).toBeNull()
    // Discovering a spin-off is also insufficient evidence that the parent has concluded.
    expect(parseNewsResult({ ...finding, status: 'concluded', next: '' })).toBeNull()
  })

  it('requires an explicit identity check, including for legacy-shaped output', () => {
    const { installmentScope: _, ...legacy } = finding
    expect(parseNewsResult(legacy)).toBeNull()
    expect(parseNewsResult({ ...finding, installmentScope: 'none' })).toBeNull()
    expect(parseNewsResult({ ...finding, installmentScope: 'same_series', next: ' ' })).toBeNull()
  })

  it('accepts the original series conclusion without publishing the internal field', () => {
    const result = parseNewsResult({ ...finding, installmentScope: 'none', status: 'concluded', next: '', release: 'TBA' })
    expect(result?.status).toBe('concluded')
    expect(result).not.toHaveProperty('installmentScope')
    expect(parseNewsResult({ ...finding, installmentScope: 'same_series', status: 'concluded', next: '' })).toBeNull()
  })

  it.each(['Season 2', 'Infinity Castle - Part 2 (movie)', 'Final Season Part 3'])(
    'preserves a genuine next installment: %s', (next) => {
      expect(parseNewsResult({ ...finding, installmentScope: 'same_series', next })?.next).toBe(next)
    },
  )
})
