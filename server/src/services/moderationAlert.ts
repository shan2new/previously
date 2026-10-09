import { env } from '../env.js'
import { staleOpenReports } from './moderation.js'

// Telling the operator (App Review 1.2 asks for action on objectionable-content reports within
// 24 h, and there is one operator): a report used to reach only the Fastify log and
// `npm run moderation -- list` on the Mac mini. `alertModeration` POSTs a small JSON document to
// `MODERATION_ALERT_WEBHOOK_URL` (unset = the log only) on a comment's FIRST open report, on every
// auto-hide (services/comments.ts `fileReport`), and hourly while reports older than 12 hours are
// still open (sync/cron.ts → `alertStaleReports`).
//
// The payload is ids and a category only: never the comment's text, never a handle or a name, so
// no user content leaves for the third-party channel. The operator reads the comment with the CLI
// line it carries. Fire-and-forget with a 5-second timeout: an alert never delays or fails a request.

export type ModerationAlert =
  | { event: 'report' | 'auto_hidden'; commentId: string; subject: string; reason: string; reportCount: number }
  | { event: 'digest'; openReports: number; oldestReportAt: number | null }

export interface ModerationAlertPayload {
  event: 'report' | 'auto_hidden' | 'digest'
  commentId: string | null
  subject: string | null
  reason: string | null
  /** report / auto_hidden: the comment's counted reports; digest: the stale open reports. */
  reportCount: number
  cli: string
  /** The same facts as one line, for chat webhooks (Slack reads `text`, Discord `content`). */
  text: string
  content: string
}

export const ALERT_TIMEOUT_MS = 5_000
/** Open reports older than this trigger the hourly digest. */
export const STALE_REPORT_MS = 12 * 3_600_000

/**
 * Pure: the alert one filed report raises, if any (services/comments.ts `fileReport`, after its
 * transaction commits). An auto-hide always alerts; otherwise only the comment's FIRST open report
 * does — the second and third are in the same queue entry the first one pointed at. A repeat
 * report (nothing inserted) never alerts.
 */
export function reportAlert(filed: {
  commentId: string
  subject: string
  reason: string
  inserted: boolean
  reportCount: number | null
  firstOpenReport: boolean
  autoHidden: boolean
}): ModerationAlert | null {
  if (!filed.inserted) return null
  if (!filed.autoHidden && !filed.firstOpenReport) return null
  return {
    event: filed.autoHidden ? 'auto_hidden' : 'report',
    commentId: filed.commentId,
    subject: filed.subject,
    reason: filed.reason,
    reportCount: filed.reportCount ?? 0,
  }
}

/** Pure: the document the webhook receives. */
export function moderationAlertPayload(alert: ModerationAlert): ModerationAlertPayload {
  if (alert.event === 'digest') {
    const cli = 'npm run moderation -- list'
    const text = `Previously moderation: ${alert.openReports} report(s) open for more than 12 h. ${cli}`
    return {
      event: 'digest',
      commentId: null,
      subject: null,
      reason: null,
      reportCount: alert.openReports,
      cli,
      text,
      content: text,
    }
  }
  const cli = `npm run moderation -- show ${alert.commentId}`
  const what = alert.event === 'auto_hidden' ? 'auto-hidden after reports' : 'reported'
  const text = `Previously moderation: comment ${alert.commentId} ${what} (${alert.reason}, ${alert.reportCount} counted) on ${alert.subject}. ${cli}`
  return {
    event: alert.event,
    commentId: alert.commentId,
    subject: alert.subject,
    reason: alert.reason,
    reportCount: alert.reportCount,
    cli,
    text,
    content: text,
  }
}

export interface AlertDeps {
  url?: string
  fetch?: typeof fetch
}

/**
 * Send one alert. Never throws and never rejects: the promise says whether the webhook accepted it
 * (false when none is configured). Callers do not await it.
 */
export async function alertModeration(alert: ModerationAlert, deps: AlertDeps = {}): Promise<boolean> {
  const url = deps.url === undefined ? env.MODERATION_ALERT_WEBHOOK_URL : deps.url
  if (!url) return false
  const send = deps.fetch ?? fetch
  try {
    const res = await send(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(moderationAlertPayload(alert)),
      signal: AbortSignal.timeout(ALERT_TIMEOUT_MS),
    })
    if (!res.ok) console.warn({ event: 'moderation.alert_failed', status: res.status })
    return res.ok
  } catch (error) {
    console.warn({ event: 'moderation.alert_failed', error: 'diagnostic details redacted' })
    return false
  }
}

/**
 * The hourly nudge (sync/cron.ts): while any report has waited more than 12 hours, log it and send
 * a `digest` alert. Returns how many are waiting.
 */
export async function alertStaleReports(nowMs: number = Date.now(), deps: AlertDeps = {}): Promise<number> {
  const stale = await staleOpenReports(new Date(nowMs - STALE_REPORT_MS))
  if (stale.count === 0) return 0
  console.warn({ event: 'moderation.stale_reports', openReports: stale.count, oldestReportAt: stale.oldestAt })
  void alertModeration({ event: 'digest', openReports: stale.count, oldestReportAt: stale.oldestAt }, deps)
  return stale.count
}
