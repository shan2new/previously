import { beforeEach, describe, expect, it, vi } from 'vitest'

// services/moderationAlert.ts: what reaches the operator's webhook, when, and that an alert can
// never fail or delay a request. No network (fetch injected), no database (the queue read mocked).

const mocks = vi.hoisted(() => ({ staleOpenReports: vi.fn() }))
vi.mock('../db/index.js', () => ({ db: {}, sql: {} }))
vi.mock('./moderation.js', () => ({ staleOpenReports: mocks.staleOpenReports }))

const { ALERT_TIMEOUT_MS, STALE_REPORT_MS, alertModeration, alertStaleReports, moderationAlertPayload, reportAlert } =
  await import('./moderationAlert.js')

const COMMENT = '55555555-5555-4555-8555-555555555555'
const HOOK = 'https://hooks.example.com/moderation'

function okFetch(status = 200) {
  return vi.fn(async (_url: string | URL | Request, _init?: RequestInit) => new Response(null, { status }))
}

beforeEach(() => {
  mocks.staleOpenReports.mockReset()
})

describe('reportAlert — which filed reports raise an alert', () => {
  const base = { commentId: COMMENT, subject: 'ep:154587:12', reason: 'harassment', inserted: true }

  it("alerts on a comment's first open report", () => {
    expect(reportAlert({ ...base, reportCount: 1, firstOpenReport: true, autoHidden: false })).toEqual({
      event: 'report',
      commentId: COMMENT,
      subject: 'ep:154587:12',
      reason: 'harassment',
      reportCount: 1,
    })
  })

  it('stays quiet for the second and third open reports (the first one already pointed at the entry)', () => {
    expect(reportAlert({ ...base, reportCount: 2, firstOpenReport: false, autoHidden: false })).toBeNull()
  })

  it('alerts on every auto-hide, once (a threshold of 1 is one auto_hidden alert, not two)', () => {
    expect(reportAlert({ ...base, reportCount: 3, firstOpenReport: false, autoHidden: true })?.event).toBe('auto_hidden')
    expect(reportAlert({ ...base, reportCount: 1, firstOpenReport: true, autoHidden: true })?.event).toBe('auto_hidden')
  })

  it('never alerts on a repeat report (nothing was inserted)', () => {
    expect(reportAlert({ ...base, inserted: false, reportCount: null, firstOpenReport: false, autoHidden: false })).toBeNull()
  })
})

describe('moderationAlertPayload', () => {
  it('carries ids, the category and the CLI line — never a comment body, handle or Clerk id', () => {
    const payload = moderationAlertPayload({
      event: 'report',
      commentId: COMMENT,
      subject: 'news:44444444-4444-4444-8444-444444444444',
      reason: 'spam',
      reportCount: 1,
    })
    expect(payload).toMatchObject({
      event: 'report',
      commentId: COMMENT,
      subject: 'news:44444444-4444-4444-8444-444444444444',
      reason: 'spam',
      reportCount: 1,
      cli: `npm run moderation -- show ${COMMENT}`,
    })
    expect(Object.keys(payload).sort()).toEqual(['cli', 'commentId', 'content', 'event', 'reason', 'reportCount', 'subject', 'text'])
    expect(payload.text).toContain(payload.cli)
    expect(payload.content).toBe(payload.text)
  })

  it('a digest points at the queue', () => {
    const payload = moderationAlertPayload({ event: 'digest', openReports: 4, oldestReportAt: 1 })
    expect(payload).toMatchObject({ event: 'digest', commentId: null, subject: null, reason: null, reportCount: 4 })
    expect(payload.cli).toBe('npm run moderation -- list')
  })
})

describe('alertModeration', () => {
  const alert = { event: 'auto_hidden' as const, commentId: COMMENT, subject: 'ep:1:2', reason: 'hate', reportCount: 3 }

  it('does nothing without a webhook (the log only)', async () => {
    const fetch = okFetch()
    expect(await alertModeration(alert, { url: '', fetch })).toBe(false)
    expect(fetch).not.toHaveBeenCalled()
  })

  it('POSTs the payload as JSON with a timeout', async () => {
    const fetch = okFetch()
    expect(await alertModeration(alert, { url: HOOK, fetch })).toBe(true)
    expect(fetch).toHaveBeenCalledOnce()
    const [url, init] = fetch.mock.calls[0]!
    expect(url).toBe(HOOK)
    expect(init?.method).toBe('POST')
    expect(init?.headers).toEqual({ 'content-type': 'application/json' })
    expect(JSON.parse(String(init?.body))).toEqual(moderationAlertPayload(alert))
    expect(init?.signal).toBeInstanceOf(AbortSignal)
    expect(ALERT_TIMEOUT_MS).toBe(5_000)
  })

  it('never throws: a refused or failed delivery is logged and answers false', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    expect(await alertModeration(alert, { url: HOOK, fetch: okFetch(500) })).toBe(false)
    const broken = vi.fn(async () => Promise.reject(new Error('ECONNREFUSED')))
    expect(await alertModeration(alert, { url: HOOK, fetch: broken })).toBe(false)
    expect(warn).toHaveBeenCalledWith({ event: 'moderation.alert_failed', status: 500 })
    expect(warn).toHaveBeenCalledWith({ event: 'moderation.alert_failed', error: 'diagnostic details redacted' })
    warn.mockRestore()
  })
})

describe('alertStaleReports — the hourly nudge', () => {
  const NOW = Date.UTC(2026, 8, 25, 12)

  it('asks for reports older than 12 hours and stays quiet when there are none', async () => {
    mocks.staleOpenReports.mockResolvedValue({ count: 0, oldestAt: null })
    const fetch = okFetch()
    expect(await alertStaleReports(NOW, { url: HOOK, fetch })).toBe(0)
    expect(mocks.staleOpenReports).toHaveBeenCalledWith(new Date(NOW - STALE_REPORT_MS))
    expect(STALE_REPORT_MS).toBe(12 * 3_600_000)
    expect(fetch).not.toHaveBeenCalled()
  })

  it('sends a digest while any report has waited too long', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    mocks.staleOpenReports.mockResolvedValue({ count: 2, oldestAt: NOW - 20 * 3_600_000 })
    const fetch = okFetch()
    expect(await alertStaleReports(NOW, { url: HOOK, fetch })).toBe(2)
    await vi.waitFor(() => expect(fetch).toHaveBeenCalledOnce())
    expect(JSON.parse(String(fetch.mock.calls[0]![1]?.body))).toMatchObject({ event: 'digest', reportCount: 2 })
    expect(warn).toHaveBeenCalledWith(expect.objectContaining({ event: 'moderation.stale_reports', openReports: 2 }))
    warn.mockRestore()
  })
})
