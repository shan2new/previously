import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
const mocks = vi.hoisted(() => ({ query: vi.fn(), codex: vi.fn() }))
vi.mock('@anthropic-ai/claude-agent-sdk', () => ({ query: mocks.query }))
vi.mock('./codex.js', () => ({ researchWithCodex: mocks.codex }))

const input = { title: 'Show', catalogueSource: 'tmdb' as const, current: null, knownParts: [], knownAnnouncements: [] }
const fact = {
  installmentScope: 'none', status: 'concluded', next: '', release: 'TBA', note: null,
  source: 'https://www.aboutamazon.com/news/entertainment/the-boys',
  evidence: [{ url: 'https://www.aboutamazon.com/news/entertainment/the-boys', publisher: 'Amazon', publishedAt: null, tier: 'official', primary: true }],
}
function stream(message: object) {
  return { async *[Symbol.asyncIterator]() { yield message }, interrupt: vi.fn().mockResolvedValue(undefined), close: vi.fn() }
}
beforeEach(() => {
  vi.resetModules()
  mocks.query.mockReset()
  mocks.codex.mockReset().mockResolvedValue(fact)
  vi.stubEnv('NEWS_AGENT_DISABLED', '0')
  vi.stubEnv('NEWS_CODEX_FALLBACK_ENABLED', '1')
  vi.spyOn(console, 'warn').mockImplementation(() => {})
  vi.spyOn(console, 'log').mockImplementation(() => {})
})
afterEach(() => { vi.restoreAllMocks(); vi.unstubAllEnvs(); vi.useRealTimers() })

describe('research provider fallback', () => {
  it('recognizes quota errors with success subtype and uses Codex during the Claude cooldown', async () => {
    mocks.query.mockReturnValue(stream({ type: 'result', subtype: 'success', is_error: true, api_error_status: 429, result: 'Weekly limit reached' }))
    const { researchFranchiseNews } = await import('./agent.js')
    expect(await researchFranchiseNews(input)).toMatchObject({ status: 'concluded' })
    expect(await researchFranchiseNews({ ...input, title: 'Another Show' })).toMatchObject({ status: 'concluded' })
    expect(mocks.query).toHaveBeenCalledTimes(1)
    expect(mocks.codex).toHaveBeenCalledTimes(2)
    expect(mocks.codex.mock.calls[0]![0]).toContain('Vought Rising is')
  })
  it('uses the same identity checks for a Codex response', async () => {
    mocks.query.mockImplementation(() => { throw new Error('startup failure') })
    mocks.codex.mockResolvedValue({ ...fact, installmentScope: 'separate_series', status: 'announced_no_date', next: 'Vought Rising' })
    const { researchFranchiseNews } = await import('./agent.js')
    expect(await researchFranchiseNews(input)).toBeNull()
  })
  it.each([fact, { ...fact, installmentScope: 'separate_series' }, { ...fact, status: 'unknown' }, {}])(
    'does not ask another provider to replace completed research: %j', async raw => {
      mocks.query.mockReturnValue(stream({ type: 'result', subtype: 'success', is_error: false, structured_output: raw }))
      const { researchFranchiseNews } = await import('./agent.js')
      await researchFranchiseNews(input)
      expect(mocks.codex).not.toHaveBeenCalled()
    },
  )
  it('falls back on startup failure and returns no new information if both fail', async () => {
    mocks.query.mockImplementation(() => { throw new Error('startup failure') })
    mocks.codex.mockResolvedValue(null)
    const { researchFranchiseNews } = await import('./agent.js')
    expect(await researchFranchiseNews(input)).toBeNull()
    expect(mocks.codex).toHaveBeenCalledOnce()
  })
  it('interrupts and closes a stalled primary before returning fallback research', async () => {
    vi.useFakeTimers()
    vi.stubEnv('NEWS_AGENT_TIMEOUT_MS', '10')
    const stalled = {
      async *[Symbol.asyncIterator]() { await new Promise(() => {}); yield {} },
      interrupt: vi.fn().mockResolvedValue(undefined), close: vi.fn(),
    }
    mocks.query.mockReturnValue(stalled)
    const { researchFranchiseNews } = await import('./agent.js')
    const result = researchFranchiseNews(input)
    await vi.advanceTimersByTimeAsync(11)
    expect(await result).toMatchObject({ status: 'concluded' })
    expect(stalled.interrupt).toHaveBeenCalledOnce()
    expect(stalled.close).toHaveBeenCalledOnce()
  })
  it('honors disabling the fallback', async () => {
    vi.stubEnv('NEWS_CODEX_FALLBACK_ENABLED', '0')
    mocks.query.mockImplementation(() => { throw new Error('offline') })
    const { researchFranchiseNews } = await import('./agent.js')
    expect(await researchFranchiseNews(input)).toBeNull()
    expect(mocks.codex).not.toHaveBeenCalled()
  })
  it('honors disabling all news research', async () => {
    vi.stubEnv('NEWS_AGENT_DISABLED', '1')
    const { researchFranchiseNews } = await import('./agent.js')
    expect(await researchFranchiseNews(input)).toBeNull()
    expect(mocks.query).not.toHaveBeenCalled()
    expect(mocks.codex).not.toHaveBeenCalled()
  })
})
