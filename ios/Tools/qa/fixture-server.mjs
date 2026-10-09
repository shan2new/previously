#!/usr/bin/env node
/**
 * Isolated, synthetic HTTP oracle for native QA. No dependencies, .env, DB or upstream calls.
 * Run: PREVIOUSLY_QA_CONTROL_TOKEN=<random token> node ios/Tools/qa/fixture-server.mjs
 * This is deliberately a fixture, not evidence that the production backend is correct.
 */
import http from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { isDeepStrictEqual } from 'node:util';

export const FIXTURE_VERSION = '1';
export const DEFAULT_PORT = 18787;
const EPOCH = 1_791_288_000_000; // Fixed 6 October 2026 UTC fixture clock.
const ACCOUNTS = ['fixture-a', 'fixture-b'];
const STATUSES = new Set(['watching', 'completed', 'planned', 'paused', 'dropped']);
const CATALOGUE = Object.freeze([
  { id: 'qa-anime', mediaId: 1001, title: 'QA Anime', source: 'anilist', total: 12 },
  { id: 'qa-tv', mediaId: 2001, title: 'QA Television', source: 'tmdb', total: 8 },
  { id: 'qa-plan', mediaId: 3001, title: 'QA Planned', source: 'anilist', total: 10 },
]);
const catalogueById = new Map(CATALOGUE.map((f) => [f.id, f]));
const catalogueByMedia = new Map(CATALOGUE.map((f) => [f.mediaId, f]));
const LIVE_TEST_VIDEO = Object.freeze({ id: 'M7lc1UVf-VE', site: 'youtube', kind: 'trailer',
  title: 'YouTube IFrame API demonstration', url: 'https://www.youtube.com/watch?v=M7lc1UVf-VE',
  thumbnail: null, official: true, language: 'en', country: null, publishedAt: null,
  scope: { type: 'franchise' } });
const MAX_BODY = 256 * 1024;
const MAX_LOGS = 2_000;
const UUID = /^[a-f\d]{8}-[a-f\d]{4}-[a-f\d]{4}-[a-f\d]{4}-[a-f\d]{12}$/i;

function mutationMetadata(req) {
  const operationID = req.headers['x-previously-operation-id'];
  const writerID = req.headers['x-previously-writer-id'];
  const rawSequence = req.headers['x-previously-writer-seq'];
  if ([operationID, writerID, rawSequence].every((value) => value === undefined)) return { mutation: null };
  if (typeof operationID !== 'string' || !UUID.test(operationID)
      || typeof writerID !== 'string' || !UUID.test(writerID)
      || typeof rawSequence !== 'string' || !/^[1-9]\d{0,15}$/.test(rawSequence)
      || !Number.isSafeInteger(Number(rawSequence))) return { mutation: null, error: 'invalid mutation metadata' };
  return { mutation: { operationID, writerID, sequence: Number(rawSequence) } };
}

function initialAccount(account) {
  const ids = account === 'fixture-a' ? ['qa-anime', 'qa-tv'] : ['qa-plan'];
  return {
    account, liveTrailer: false, erased: false, commits: 0, progressCommits: 0, importApplications: 0, mutationAttempts: 0,
    deletionStatus: 'active', deletionCompletion: 'complete', appleRevocation: 'not_applicable', refuseNextDeletion: false,
    deletionRequests: 0, deletionStatusReads: 0, ordinaryRequestsAfterErasure: 0,
    subscriptions: new Map(ids.map((id) => [id, id === 'qa-plan' ? 'planned' : 'watching'])),
    progress: new Map(ids.map((id) => {
      const f = catalogueById.get(id);
      return [f.mediaId, id === 'qa-anime' ? 3 : id === 'qa-tv' ? 2 : 0];
    })),
    sessions: new Map(), deletedSessions: new Set(),
    preferences: { country: 'US', language: 'en', providerIds: [], audience: 'both' },
    prevOpenedAt: EPOCH - 86_400_000, openedAt: EPOCH,
    imports: new Map(), nextImport: 1, toggles: new Map(),
  };
}

function snapshot(state) {
  return {
    fixtureVersion: FIXTURE_VERSION, account: state.account,
    subscriptions: [...state.subscriptions].sort(([a], [b]) => a.localeCompare(b))
      .map(([franchiseId, status]) => ({ franchiseId, status })),
    progress: [...state.progress].sort(([a], [b]) => a - b).map(([mediaId, episodes]) => ({ mediaId, episodes })),
    commits: state.commits, progressCommits: state.progressCommits, importApplications: state.importApplications, erased: state.erased,
    mutationAttempts: state.mutationAttempts,
    deletionStatus: state.deletionStatus, deletionRequests: state.deletionRequests,
    deletionStatusReads: state.deletionStatusReads, ordinaryRequestsAfterErasure: state.ordinaryRequestsAfterErasure,
    sessions: [...state.sessions.values()].map((s) => structuredClone(s)),
  };
}

function franchise(f, state, detail = true) {
  const status = state?.subscriptions.get(f.id) ?? null;
  const progress = state?.progress.get(f.mediaId) ?? 0;
  const result = {
    id: f.id, source: f.source, title: f.title, cover: null, banner: null,
    synopsis: 'Synthetic native QA fixture. All episodes are complete and available.',
    genres: ['QA'], isReleasing: false, partCount: 1, partCounts: { season: 1, movie: 0, ova: 0, ona: 0, special: 0, music: 0 },
    nextAiringAt: null, year: 2026, studios: [], images: null, artwork: null, themes: [],
    featuredVideo: state?.liveTrailer && f.id === 'qa-anime' ? LIVE_TEST_VIDEO : null, videos: [], audience: null, people: null, related: [],
    upcoming: { status: 'concluded', next: null, release: null, note: null, source: null, checked: '2026-10-06' },
    subscription: status ? { status, addedAt: EPOCH - 7 * 86_400_000 } : null,
    status, behind: 0, newParts: 0,
    parts: [{
      mediaId: f.mediaId, kind: 'season', sequence: 1, label: 'Season 1', title: f.title,
      cover: null, banner: null, format: 'TV', relationship: null, status: 'FINISHED',
      isReleasing: false, totalEpisodes: f.total, airedEpisodes: f.total, progress,
      nextEpisodeNumber: null, nextAiringAt: null, lastAiredAt: EPOCH - 30 * 86_400_000,
      synopsis: null, genres: ['QA'], year: 2026, studios: [], nextAiringCount: 0,
      release: { precision: 'unknown', at: null, date: null }, airings: [], images: null, artwork: null, videos: [],
      episodes: detail ? Array.from({ length: f.total }, (_, i) => ({ number: i + 1, title: `QA Episode ${i + 1}`, airDate: null, overview: null, still: null, runtime: 24 })) : [],
    }],
  };
  return result;
}

function json(res, status, body, headers = {}) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', ...headers });
  res.end(status === 204 ? undefined : JSON.stringify(body));
}

function fail(status, error) { return { status, body: { error } }; }
function ok(body = { ok: true }, status = 200) { return { status, body }; }
function number(value, max = 2_147_483_647) { return Number.isInteger(value) && value >= 0 && value <= max; }
function equal(a, b) { return isDeepStrictEqual(a, b); }
function tokenMatches(given, expected) {
  if (typeof given !== 'string') return false;
  const a = Buffer.from(given); const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

async function readBody(req) {
  let size = 0;
  const chunks = [];
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY) throw Object.assign(new Error('body too large'), { status: 413 });
    chunks.push(chunk);
  }
  if (!size) return {};
  try {
    const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    if (!body || Array.isArray(body) || typeof body !== 'object') throw new Error('object required');
    return body;
  } catch { throw Object.assign(new Error('invalid request'), { status: 400 }); }
}

/** Factory does not listen until its caller explicitly calls listen(). */
export function createFixtureServer({ controlToken, log = () => {} } = {}) {
  if (typeof controlToken !== 'string' || controlToken.length < 8 || controlToken.length > 256) {
    throw new Error('PREVIOUSLY_QA_CONTROL_TOKEN must contain 8–256 characters');
  }
  const accounts = new Map(ACCOUNTS.map((a) => [a, initialAccount(a)]));
  let faults = [];
  const logs = [];
  const sockets = new Set();
  let nextRequestID = 1;
  const record = (req, path, account, outcome) => {
    // No token, body, query, user search or import username enters a log.
    const route = path.replace(/\/watch-sessions\/[^/]+/, '/watch-sessions/:id')
      .replace(/\/import\/[^/]+/, '/import/:id').slice(0, 100);
    req.qaRequestID ??= nextRequestID++;
    const item = { requestID: req.qaRequestID, method: req.method.slice(0, 8), path: route, account: ACCOUNTS.includes(account) ? account : null, outcome: String(outcome).slice(0, 40) };
    const { mutation } = mutationMetadata(req);
    if (mutation) item.mutation = mutation;
    // Oracle polling must never evict the authenticated writes a case is trying to inspect.
    if (!path.startsWith('/__qa/') && !path.startsWith('/qa/')) {
      logs.push(item); if (logs.length > MAX_LOGS) logs.shift();
    }
    log(item);
  };
  const stateFor = (req) => {
    const match = /^Bearer dev:(fixture-[ab])$/.exec(req.headers.authorization ?? '');
    return match ? accounts.get(match[1]) : null;
  };
  const changed = (state, mutate) => {
    const domain = () => ({ s: state.subscriptions, p: state.progress, sessions: state.sessions, deletedSessions: state.deletedSessions, erased: state.erased, importApplications: state.importApplications, toggles: state.toggles });
    const before = structuredClone(domain());
    mutate();
    if (!equal(before, domain())) state.commits += 1;
    if (!equal(before.p, state.progress)) state.progressCommits += 1;
  };

  function control(req, url, body) {
    if (!tokenMatches(req.headers['x-previously-qa-token'], controlToken)) return fail(401, 'control unauthorized');
    const path = url.pathname.replace(/^\/qa(?=\/)/, '/__qa');
    if (req.method === 'GET' && path === '/__qa/state') {
      const account = url.searchParams.get('account') ?? 'fixture-a';
      return accounts.has(account) ? ok({ ...snapshot(accounts.get(account)), faults: faults.filter((f) => f.account === account).map(({ kind, path, remaining, inFlight }) => ({ kind, path, remaining, inFlight })) }) : fail(400, 'unknown fixture account');
    }
    if (req.method === 'GET' && path === '/__qa/logs') return ok({ fixtureVersion: FIXTURE_VERSION, logs });
    if (req.method === 'POST' && path === '/__qa/reset') {
      if (body.account !== undefined && !ACCOUNTS.includes(body.account)) return fail(400, 'unknown fixture account');
      const selected = body.account ? [body.account] : ACCOUNTS;
      selected.forEach((a) => accounts.set(a, initialAccount(a)));
      faults.filter((f) => selected.includes(f.account)).forEach((f) => f.release?.('abort'));
      faults = faults.filter((f) => !selected.includes(f.account));
      if (!body.account) logs.length = 0;
      return ok({ ok: true, fixtureVersion: FIXTURE_VERSION, accounts: selected });
    }
    if (req.method === 'POST' && path === '/__qa/fault') {
      const kinds = ['drop-after-commit', 'before-commit', 'offline', 'delay', 'proxy-forbidden-after-commit', 'empty-success-after-commit', 'hold-before-commit', 'hold-after-commit'];
      const remaining = body.remaining ?? 1;
      const delayMs = body.delayMs ?? 1000;
      if (!ACCOUNTS.includes(body.account) || !kinds.includes(body.kind)
        || typeof body.path !== 'string' || !body.path.startsWith('/') || body.path.length > 200
        || !number(remaining, 100) || remaining < 1 || !number(delayMs, 30_000)) return fail(400, 'invalid fault');
      if (body.path.startsWith('/__qa') || body.path.startsWith('/qa/')) return fail(400, 'control faults forbidden');
      faults.push({ account: body.account, kind: body.kind, path: body.path, remaining, delayMs, inFlight: 0 });
      return ok({ ok: true, fixtureVersion: FIXTURE_VERSION });
    }
    if (req.method === 'POST' && path === '/__qa/trailer') {
      if (!ACCOUNTS.includes(body.account) || typeof body.enabled !== 'boolean') return fail(400, 'invalid trailer mode');
      accounts.get(body.account).liveTrailer = body.enabled;
      return ok({ ok: true });
    }
    if (req.method === 'POST' && path === '/__qa/release') {
      if (!ACCOUNTS.includes(body.account) || typeof body.path !== 'string'
          || !['abort', 'continue'].includes(body.disposition)) return fail(400, 'invalid release');
      const held = faults.filter((f) => f.account === body.account && f.path === body.path && f.inFlight > 0 && f.release);
      if (!held.length) return fail(409, 'no held request');
      held.forEach((f) => f.release(body.disposition));
      return ok({ ok: true, released: held.length });
    }
    if (req.method === 'POST' && path === '/__qa/deletion') {
      if (!ACCOUNTS.includes(body.account) || !['pending', 'complete', 'refuse-next'].includes(body.mode)) {
        return fail(400, 'invalid deletion mode');
      }
      const state = accounts.get(body.account);
      if (body.appleRevocation !== undefined) {
        if (!['revoked', 'manual_required', 'not_applicable'].includes(body.appleRevocation)) return fail(400, 'invalid Apple revocation state');
        state.appleRevocation = body.appleRevocation;
      }
      if (body.mode === 'refuse-next') state.refuseNextDeletion = true;
      else {
        state.deletionCompletion = body.mode;
        if (state.erased) state.deletionStatus = body.mode;
      }
      return ok({ ok: true, fixtureVersion: FIXTURE_VERSION });
    }
    return fail(404, 'fixture control route not found');
  }

  function app(req, url, body, state) {
    const path = url.pathname; const method = req.method;
    if (path === '/health' && method === 'GET') return ok({ ok: true, fixtureVersion: FIXTURE_VERSION });
    if (!state) return fail(401, 'fixture identity required');
    // Deletion reconciliation never upserts data and remains available on the erased identity.
    if (method === 'GET' && path === '/me/deletion') {
      state.deletionStatusReads += 1;
      return ok({ deleted: state.deletionStatus === 'complete', status: state.deletionStatus, appleRevocation: state.appleRevocation }, state.deletionStatus === 'pending' ? 202 : 200);
    }
    if (method === 'DELETE' && path === '/me') {
      state.deletionRequests += 1;
      if (state.refuseNextDeletion) {
        state.refuseNextDeletion = false;
        return fail(400, 'unexpected body');
      }
      changed(state, () => {
        state.erased = true; state.subscriptions.clear(); state.progress.clear(); state.sessions.clear();
        state.deletedSessions.clear(); state.imports.clear(); state.toggles.clear();
      });
      state.deletionStatus = state.deletionCompletion;
      return ok({ deleted: state.deletionStatus === 'complete', status: state.deletionStatus, appleRevocation: state.appleRevocation }, state.deletionStatus === 'pending' ? 202 : 200);
    }
    if (state.erased) {
      state.ordinaryRequestsAfterErasure += 1;
      return fail(410, 'account deleted');
    }
    if (method === 'GET' && path === '/me/library') {
      return ok({ franchises: [...state.subscriptions.keys()].map((id) => franchise(catalogueById.get(id), state, false)), prevOpenedAt: state.prevOpenedAt });
    }
    if (path === '/me/preferences') {
      if (method === 'GET') return ok(structuredClone(state.preferences));
      if (method === 'PUT') {
        if (body.audience !== undefined && !['anime', 'tv', 'both'].includes(body.audience)) return fail(400, 'invalid audience');
        if (body.country !== undefined && body.country !== null && !/^[a-z]{2}$/i.test(body.country)) return fail(400, 'invalid country');
        if (body.providerIds !== undefined && (!Array.isArray(body.providerIds) || body.providerIds.some((v) => !number(v)))) return fail(400, 'invalid providers');
        for (const key of ['audience', 'country', 'providerIds', 'language']) {
          if (body[key] !== undefined) state.preferences[key] = structuredClone(body[key]);
        }
        return ok(structuredClone(state.preferences));
      }
    }
    if (path === '/me/opened' && method === 'POST') {
      state.prevOpenedAt = state.openedAt; state.openedAt += 1000;
      return ok({ prevOpenedAt: state.prevOpenedAt });
    }
    if (path === '/me/progress' && method === 'PUT') {
      const f = catalogueByMedia.get(body.mediaId);
      if (!f) return fail(404, 'media not found');
      if (!number(body.episodes)) return fail(400, 'invalid episodes');
      const episodes = Math.min(body.episodes, f.total);
      changed(state, () => state.progress.set(f.mediaId, episodes));
      return ok({ ok: true, mediaId: f.mediaId, episodes });
    }
    let match = /^\/me\/franchises\/([^/]+)\/progress$/.exec(path);
    if (match && method === 'PUT') {
      const f = catalogueById.get(match[1]);
      if (!f) return fail(404, 'franchise not found');
      if (body.status !== undefined && !STATUSES.has(body.status)) return fail(400, 'invalid status');
      let parts = body.parts;
      if (['caught_up', 'completed', 'reset'].includes(body.mode)) parts = [{ mediaId: f.mediaId, episodes: body.mode === 'reset' ? 0 : f.total }];
      if (!Array.isArray(parts) || parts.some((p) => p.mediaId !== f.mediaId || !number(p.episodes))) return fail(400, 'invalid parts');
      const values = parts.map((p) => ({ mediaId: p.mediaId, episodes: Math.min(p.episodes, f.total) }));
      changed(state, () => {
        values.forEach((p) => state.progress.set(p.mediaId, p.episodes));
        if (body.status !== undefined) state.subscriptions.set(f.id, body.status);
      });
      return ok({ ok: true, franchiseId: f.id, status: state.subscriptions.get(f.id) ?? null, progress: values });
    }
    if (path === '/me/subscriptions' && method === 'POST') {
      const f = catalogueById.get(body.franchiseId);
      if (!f) return fail(404, 'franchise not found');
      if (body.status !== undefined && !STATUSES.has(body.status)) return fail(400, 'invalid status');
      changed(state, () => state.subscriptions.set(f.id, body.status ?? state.subscriptions.get(f.id) ?? 'watching'));
      return ok();
    }
    match = /^\/me\/subscriptions\/([^/]+)$/.exec(path);
    if (match && ['PATCH', 'DELETE'].includes(method)) {
      if (!catalogueById.has(match[1])) return fail(404, 'franchise not found');
      if (method === 'PATCH' && !STATUSES.has(body.status)) return fail(400, 'invalid status');
      changed(state, () => method === 'DELETE' ? state.subscriptions.delete(match[1]) : state.subscriptions.set(match[1], body.status));
      return ok();
    }
    if (method === 'GET' && path === '/me/watch-sessions') return ok({ sessions: [...state.sessions.values()] });
    match = /^\/me\/watch-sessions\/([^/]+)$/.exec(path);
    if (match && ['PUT', 'DELETE'].includes(method)) {
      const id = match[1].toLowerCase();
      if (!UUID.test(id)) return fail(400, 'invalid session id');
      if (method === 'DELETE') {
        changed(state, () => { state.sessions.delete(id); state.deletedSessions.add(id); });
        return ok(undefined, 204);
      }
      if (state.deletedSessions.has(id)) return fail(410, 'session deleted');
      if (!catalogueById.has(body.franchiseId) || !number(body.ordinal, 999) || body.ordinal < 1 || !number(body.episodes)) return fail(400, 'invalid session');
      const session = { id, ...body };
      changed(state, () => { if (!equal(state.sessions.get(id), session)) state.sessions.set(id, session); });
      return ok(undefined, 204);
    }
    if (method === 'GET' && path === '/me/export') return ok(snapshot(state));
    if (method === 'GET' && path === '/me/profile') return ok({ userId: state.account, handle: null, displayName: null, termsAcceptedAt: null, termsVersion: null, currentTermsVersion: 'fixture-1', canComment: false });
    if (path.startsWith('/social/comments') || path === '/me/terms' || path === '/me/profile/handle' || (path === '/me/profile' && method !== 'GET')) return fail(404, 'comments disabled');
    if (method === 'GET' && path === '/me/feed') return ok({ tab: url.searchParams.get('tab') ?? 'following', generatedAt: EPOCH, prevOpenedAt: state.prevOpenedAt, capabilities: { comments: false }, franchises: [], posts: [], trending: [] });
    if (method === 'GET' && ['/me/saved', '/me/reminders'].includes(path)) return ok({ items: [], franchises: [] });
    if (method === 'GET' && path === '/me/hides') return ok({ items: [] });
    if (method === 'GET' && path === '/me/blocks') return ok({ users: [] });
    if (method === 'GET' && ['/me/notifications', '/me/activity'].includes(path)) return ok({ items: [], unread: 0, nextCursor: null });
    if (method === 'POST' && path === '/me/notifications/read') return ok();
    if (method === 'GET' && path === '/me/recommendations') return ok({ items: [], generatedAt: EPOCH });
    if (['PUT', 'DELETE', 'POST'].includes(method) && ['/me/likes', '/me/saves', '/me/reminders', '/me/hides', '/me/ratings', '/me/blocks', '/me/recommendations/feedback'].includes(path)) {
      const key = `${path}:${body.subject ?? body.postId ?? body.target ?? body.key ?? body.userId ?? `${body.mediaId}:${body.episode}`}`;
      changed(state, () => method === 'DELETE' ? state.toggles.delete(key) : state.toggles.set(key, structuredClone(body)));
      return ok(undefined, 204);
    }
    if (method === 'GET' && ['/franchises/trending', '/franchises/starter'].includes(path)) {
      const list = url.searchParams.get('status') === 'RELEASING' ? [] : CATALOGUE;
      return ok({ franchises: list.map((f) => franchise(f, state, false)) });
    }
    if (method === 'GET' && path === '/search') {
      const query = (url.searchParams.get('q') ?? '').trim().toLowerCase();
      return ok({ franchises: query ? CATALOGUE.filter((f) => f.title.toLowerCase().includes(query)).map((f) => franchise(f, state, false)) : [], correctedQuery: null, originalQuery: null, sources: { anilist: 'ok', tmdb: 'ok' } });
    }
    if (method === 'POST' && path === '/franchises/resolve') {
      const f = CATALOGUE.find((f) => f.source === body.source && f.mediaId === body.externalId);
      return f ? ok(franchise(f, state, false)) : fail(404, 'fixture title not found');
    }
    match = /^\/franchises\/([^/]+)(\/watch-providers)?$/.exec(path);
    if (method === 'GET' && match) {
      const f = catalogueById.get(match[1]);
      if (!f) return fail(404, 'franchise not found');
      if (match[2]) return ok({ country: url.searchParams.get('country') ?? 'US', status: 'disabled', providers: [], link: null, attribution: 'JustWatch' });
      return ok(franchise(f, state));
    }
    if (method === 'GET' && path === '/discover/genres') return ok({ source: url.searchParams.get('source'), genres: [{ key: 'qa', name: 'QA', count: CATALOGUE.length, posters: [] }], generatedAt: EPOCH });
    if (method === 'GET' && path === '/discover/genres/qa') return ok({ genre: { key: 'qa', name: 'QA', count: CATALOGUE.length, posters: [] }, franchises: CATALOGUE.map((f) => franchise(f, state, false)), nextCursor: null });
    if (method === 'GET' && path.startsWith('/discover/genres/')) return ok({ genre: { key: 'unknown', name: 'Unknown', count: 0, posters: [] }, franchises: [], nextCursor: null });
    if (method === 'POST' && path === '/me/import/preview') {
      if (!['anilist', 'mal', 'tvtime'].includes(body.source)) return fail(400, 'invalid import source');
      const id = `fixture-import-${state.account}-${state.nextImport++}`;
      const f = catalogueById.get('qa-plan');
      const preview = { id, source: body.source, listed: 1, ready: 1, toFetch: 0, episodes: 0, byStatus: { planned: 1 }, unmatched: { count: 0, titles: [] }, sample: [franchise(f, state, false)] };
      state.imports.set(id, { preview, applied: false });
      return url.searchParams.get('async') === '1' ? ok({ id, state: 'ready', preview, error: null }) : ok(preview);
    }
    match = /^\/me\/import\/([^/]+)(\/(preview|apply))?$/.exec(path);
    if (match) {
      const job = state.imports.get(match[1]);
      if (!job) return fail(410, 'import forgotten');
      if (method === 'GET' && match[3] === 'preview') return ok({ id: match[1], state: 'ready', preview: job.preview, error: null });
      if (method === 'DELETE') { state.imports.delete(match[1]); return ok(undefined, 204); }
      if (method === 'POST' && match[3] === 'apply') {
        if (!job.applied) changed(state, () => {
          job.applied = true; state.importApplications += 1;
          if (!state.subscriptions.has('qa-plan')) state.subscriptions.set('qa-plan', 'planned');
          if (!state.progress.has(3001)) state.progress.set(3001, 0);
        });
        return ok({ id: match[1], state: 'done', shows: 1, remaining: 0, failed: 0 });
      }
      if (method === 'GET' && !match[3]) return ok({ id: match[1], state: job.applied ? 'done' : 'ready', shows: job.applied ? 1 : 0, remaining: 0, failed: 0 });
    }
    return fail(404, 'fixture route not found');
  }

  const hold = async (fault) => new Promise((resolve) => {
    const timer = setTimeout(() => finish('abort'), 30_000);
    const finish = (disposition) => {
      clearTimeout(timer); fault.release = null; resolve(disposition);
    };
    fault.release = finish;
  });

  const server = http.createServer(async (req, res) => {
    let path = '/invalid'; let state = null; let fault = null;
    try {
      const url = new URL(req.url, 'http://127.0.0.1'); path = decodeURI(url.pathname); url.pathname = path;
      // Control endpoints never share application auth and cannot be faulted.
      const isControl = path.startsWith('/__qa/') || path.startsWith('/qa/');
      if (isControl && !tokenMatches(req.headers['x-previously-qa-token'], controlToken)) {
        json(res, 401, { error: 'control unauthorized' }); record(req, path, null, 401); return;
      }
      state = stateFor(req);
      const body = await readBody(req);
      if (isControl) {
        const answer = control(req, url, body); json(res, answer.status, answer.body); record(req, path, body.account, answer.status); return;
      }
      if (state && !['GET', 'HEAD'].includes(req.method)) state.mutationAttempts += 1;
      const metadata = mutationMetadata(req);
      if (metadata.error) {
        json(res, 400, { error: metadata.error }); record(req, path, state?.account, 400); return;
      }
      fault = state && faults.find((f) => f.account === state.account && f.remaining > 0 && (f.path === path || f.path === '/*'));
      if (fault) {
        fault.remaining -= 1;
        fault.inFlight += 1;
        if (fault.kind === 'hold-before-commit') {
          record(req, path, state.account, 'held-before-commit');
          if (await hold(fault) === 'abort') {
            record(req, path, state.account, 'held-aborted'); req.socket.destroy(); return;
          }
        }
        if (fault.kind === 'delay') await new Promise((resolve) => setTimeout(resolve, fault.delayMs));
        if (fault.kind === 'offline') { record(req, path, state.account, 'offline'); req.socket.destroy(); return; }
        if (fault.kind === 'before-commit') { record(req, path, state.account, 'before-commit'); json(res, 503, { error: 'fixture before commit' }); return; }
      }
      const answer = app(req, url, body, state);
      if (fault?.kind === 'hold-after-commit' && answer.status >= 200 && answer.status < 300) {
        record(req, path, state.account, 'held-after-commit');
        if (await hold(fault) === 'abort') {
          record(req, path, state.account, 'held-aborted'); req.socket.destroy(); return;
        }
      }
      if (req.method === 'DELETE' && path === '/me' && answer.status >= 200 && answer.status < 300) {
        if (fault?.kind === 'proxy-forbidden-after-commit') {
          record(req, path, state.account, fault.kind);
          res.writeHead(403, { 'content-type': 'text/html', 'cache-control': 'no-store' });
          res.end('<html><body>Gateway sign-in required</body></html>'); return;
        }
        if (fault?.kind === 'empty-success-after-commit') {
          record(req, path, state.account, fault.kind); json(res, 204); return;
        }
      }
      if (fault?.kind === 'drop-after-commit' && answer.status >= 200 && answer.status < 300 && !['GET', 'HEAD'].includes(req.method)) {
        record(req, path, state.account, 'drop-after-commit'); req.socket.destroy(); return;
      }
      json(res, answer.status, answer.body, answer.headers); record(req, path, state?.account, answer.status);
    } catch (err) {
      if (!res.destroyed && !res.headersSent) json(res, err.status ?? 500, { error: err.status ? err.message : 'fixture internal error' });
      record(req, path, state?.account, err.status ?? 500);
    } finally {
      if (fault) fault.inFlight -= 1;
    }
  });
  server.on('connection', (socket) => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
  server.requestTimeout = 35_000;
  server.headersTimeout = 10_000;
  return {
    server,
    async listen(port = DEFAULT_PORT) {
      if (!number(port, 65_535)) throw new Error('invalid fixture port');
      await new Promise((resolve, reject) => {
        server.once('error', reject);
        // Explicit IPv4 loopback only. Never fall back to another host or port.
        server.listen(port, '127.0.0.1', () => { server.off('error', reject); resolve(); });
      });
      return `http://127.0.0.1:${server.address().port}`;
    },
    async close() {
      faults.forEach((f) => f.release?.('abort'));
      sockets.forEach((socket) => socket.destroy());
      if (server.listening) await new Promise((resolve, reject) => server.close((err) => err ? reject(err) : resolve()));
    },
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const fixture = createFixtureServer({ controlToken: process.env.PREVIOUSLY_QA_CONTROL_TOKEN, log: (item) => process.stdout.write(`${JSON.stringify(item)}\n`) });
    const port = process.env.PREVIOUSLY_QA_PORT === undefined ? DEFAULT_PORT : Number(process.env.PREVIOUSLY_QA_PORT);
    const url = await fixture.listen(port);
    process.stdout.write(`${JSON.stringify({ event: 'ready', url, fixtureVersion: FIXTURE_VERSION })}\n`);
    for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => { fixture.close().then(() => process.exit(0)); });
  } catch (err) {
    process.stderr.write(`Previously QA fixture failed: ${err.code ?? err.message}\n`);
    process.exitCode = 1;
  }
}
