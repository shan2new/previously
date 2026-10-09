import test from 'node:test';
import assert from 'node:assert/strict';
import { createFixtureServer } from './fixture-server.mjs';

const TOKEN = 'fixture-control-test-token';
async function setup(t, log) {
  const fixture = createFixtureServer({ controlToken: TOKEN, log });
  const url = await fixture.listen(0);
  t.after(() => fixture.close());
  const request = async (path, { method = 'GET', body, account = 'fixture-a', control = false, headers = {} } = {}) => {
    const response = await fetch(`${url}${path}`, {
      method,
      headers: { ...(control ? { 'X-Previously-QA-Token': TOKEN } : { Authorization: `Bearer dev:${account}` }), ...(body ? { 'Content-Type': 'application/json' } : {}), ...headers },
      body: body ? JSON.stringify(body) : undefined,
    });
    const data = response.status === 204 ? null : await response.json();
    return { status: response.status, data };
  };
  const state = async (account = 'fixture-a') => (await request(`/__qa/state?account=${account}`, { control: true })).data;
  const fault = (kind, path, options = {}) => request('/__qa/fault', { method: 'POST', control: true, body: { account: 'fixture-a', kind, path, ...options } });
  return { fixture, url, request, state, fault };
}

test('requires a bounded control token and listens on IPv4 loopback', async (t) => {
  assert.throws(() => createFixtureServer(), /CONTROL_TOKEN/);
  assert.throws(() => createFixtureServer({ controlToken: 'short' }), /CONTROL_TOKEN/);
  const { fixture, url } = await setup(t);
  assert.equal(fixture.server.address().address, '127.0.0.1');
  assert.match(url, /^http:\/\/127\.0\.0\.1:\d+$/);
  const second = createFixtureServer({ controlToken: TOKEN });
  await assert.rejects(second.listen(fixture.server.address().port), { code: 'EADDRINUSE' });
  await second.close();
});

for (const kind of ['proxy-forbidden-after-commit', 'empty-success-after-commit']) {
  test(`${kind} cannot be mistaken for an authoritative deletion receipt`, async (t) => {
    const { url, fault, state, request } = await setup(t);
    assert.equal((await fault(kind, '/me')).status, 200);
    const response = await fetch(url + '/me', { method: 'DELETE', headers: { Authorization: 'Bearer dev:fixture-a' } });
    assert.equal(response.status, kind === 'proxy-forbidden-after-commit' ? 403 : 204);
    if (response.status === 403) assert.match(await response.text(), /<html>/);
    else assert.equal(await response.text(), '');
    const erased = await state();
    assert.equal(erased.erased, true);
    assert.equal(erased.deletionRequests, 1);
    assert.equal(erased.progress.length, 0);
    assert.deepEqual((await request('/me/deletion')).data, { deleted: true, status: 'complete', appleRevocation: 'not_applicable' });
  });
}

test('control auth is separate from app auth and rejects unknown identities', async (t) => {
  const { request, state } = await setup(t);
  assert.equal((await request('/__qa/reset', { method: 'POST', body: {} })).status, 401);
  assert.equal((await request('/__qa/state', { control: true, headers: { 'X-Previously-QA-Token': 'wrong-token' } })).status, 401);
  assert.equal((await request('/me/library', { account: 'production-user' })).status, 401);
  assert.equal((await request('/me/progress', { method: 'PUT', account: 'production-user', body: { mediaId: 1001, episodes: 10 } })).status, 401);
  assert.deepEqual((await state()).progress, [{ mediaId: 1001, episodes: 3 }, { mediaId: 2001, episodes: 2 }]);
});

test('mutation metadata is all-or-none, bounded and logged without credentials or payloads', async (t) => {
  const { request, state } = await setup(t);
  const operationID = '11111111-1111-4111-8111-111111111111';
  const writerID = '22222222-2222-4222-8222-222222222222';
  const headers = { 'X-Previously-Operation-Id': operationID, 'X-Previously-Writer-Id': writerID,
                    'X-Previously-Writer-Seq': '7' };
  const write = { method: 'PUT', body: { mediaId: 1001, episodes: 4 } };
  assert.equal((await request('/me/progress', { ...write, headers: { 'X-Previously-Operation-Id': operationID } })).status, 400);
  assert.equal((await request('/me/progress', { ...write, headers: { ...headers, 'X-Previously-Writer-Seq': '9007199254740992' } })).status, 400);
  assert.equal((await state()).progressCommits, 0);
  assert.equal((await request('/me/progress', { ...write, headers })).status, 200);
  // Hundreds of control reads cannot evict the request whose identity we must prove.
  for (let i = 0; i < 210; i++) await state();
  const logs = (await request('/__qa/logs', { control: true })).data.logs;
  assert.equal(logs.length, 3);
  assert.deepEqual(logs.at(-1).mutation, { operationID, writerID, sequence: 7 });
  assert.equal(JSON.stringify(logs).includes('Bearer'), false);
  assert.equal(JSON.stringify(logs).includes('episodes'), false);
});

test('fixture library is wire-shaped and account state is isolated', async (t) => {
  const { request, state } = await setup(t);
  const a = (await request('/me/library')).data;
  const b = (await request('/me/library', { account: 'fixture-b' })).data;
  assert.deepEqual(a.franchises.map((f) => f.title), ['QA Anime', 'QA Television']);
  assert.deepEqual(b.franchises.map((f) => f.id), ['qa-plan']);
  assert.equal(a.franchises[0].parts[0].status, 'FINISHED');
  assert.equal(a.franchises[0].parts[0].airedEpisodes, 12);
  assert.equal(a.franchises[0].parts[0].cover, null);
  assert.equal((await request('/franchises/qa-anime', { account: 'fixture-b' })).data.parts[0].progress, 0);
  await request('/me/progress', { method: 'PUT', body: { mediaId: 1001, episodes: 4 } });
  assert.equal((await state()).progress[0].episodes, 4);
  assert.equal((await state('fixture-b')).progress.some((p) => p.mediaId === 1001), false);
  assert.equal((await state('fixture-b')).commits, 0);
});

test('absolute progress clamps canonically and replay is one logical commit', async (t) => {
  const { request, state } = await setup(t);
  for (let i = 0; i < 3; i++) {
    const reply = await request('/me/progress', { method: 'PUT', body: { mediaId: 1001, episodes: 100 } });
    assert.deepEqual(reply.data, { ok: true, mediaId: 1001, episodes: 12 });
  }
  assert.equal((await state()).commits, 1);
  assert.equal((await state()).progressCommits, 1);
  assert.equal((await state()).mutationAttempts, 3);
  assert.equal((await state()).progress[0].episodes, 12);
  assert.equal((await request('/me/progress', { method: 'PUT', body: { mediaId: 9999, episodes: 4 } })).status, 404);
  assert.equal((await request('/me/progress', { method: 'PUT', body: { mediaId: 1001, episodes: -1 } })).status, 400);
  assert.equal((await state()).commits, 1);
});

test('lost response occurs after exactly one commit and retry succeeds unchanged', async (t) => {
  const { request, state, fault } = await setup(t);
  assert.equal((await fault('drop-after-commit', '/me/progress')).status, 200);
  await assert.rejects(request('/me/progress', { method: 'PUT', body: { mediaId: 1001, episodes: 4 } }));
  assert.equal((await state()).progress[0].episodes, 4);
  assert.equal((await state()).commits, 1);
  assert.equal((await request('/me/progress', { method: 'PUT', body: { mediaId: 1001, episodes: 4 } })).status, 200);
  assert.equal((await state()).commits, 1);
  assert.equal((await state()).mutationAttempts, 2);
  assert.equal((await state()).progressCommits, 1);
});

test('before-commit and offline faults leave state unchanged and expire', async (t) => {
  const { request, state, fault } = await setup(t);
  await fault('before-commit', '/me/progress');
  assert.equal((await request('/me/progress', { method: 'PUT', body: { mediaId: 1001, episodes: 4 } })).status, 503);
  assert.equal((await state()).commits, 0);
  await fault('offline', '/me/progress');
  await assert.rejects(request('/me/progress', { method: 'PUT', body: { mediaId: 1001, episodes: 4 } }));
  assert.equal((await state()).commits, 0);
  await request('/me/progress', { method: 'PUT', body: { mediaId: 1001, episodes: 4 } });
  assert.equal((await state()).commits, 1);
});

test('compound progress is atomic and no-op replay does not double-count', async (t) => {
  const { request, state } = await setup(t);
  const options = { method: 'PUT', body: { parts: [{ mediaId: 1001, episodes: 5 }], status: 'paused' } };
  const reply = await request('/me/franchises/qa-anime/progress', options);
  assert.deepEqual(reply.data.progress, [{ mediaId: 1001, episodes: 5 }]);
  await request('/me/franchises/qa-anime/progress', options);
  assert.equal((await state()).commits, 1);
  assert.equal((await state()).subscriptions[0].status, 'paused');
  assert.equal((await request('/me/franchises/qa-anime/progress', { method: 'PUT', body: { parts: [{ mediaId: 2001, episodes: 4 }], status: 'completed' } })).status, 400);
  assert.equal((await state()).commits, 1);
  assert.equal((await state()).subscriptions[0].status, 'paused');
});

test('import preview and cancellation do not apply; apply is idempotent and owned', async (t) => {
  const { request, state } = await setup(t);
  const preview = await request('/me/import/preview?async=1', { method: 'POST', body: { source: 'anilist', username: 'synthetic-only' } });
  assert.equal(preview.data.state, 'ready');
  assert.equal(preview.data.preview.sample[0].title, 'QA Planned');
  assert.equal((await state()).importApplications, 0);
  assert.equal((await state()).commits, 0);
  assert.equal((await request(`/me/import/${preview.data.id}/apply`, { method: 'POST', account: 'fixture-b' })).status, 410);
  await request(`/me/import/${preview.data.id}`, { method: 'DELETE' });
  assert.equal((await state()).importApplications, 0);
  const next = await request('/me/import/preview?async=1', { method: 'POST', body: { source: 'anilist', username: 'synthetic-only' } });
  for (let i = 0; i < 2; i++) await request(`/me/import/${next.data.id}/apply`, { method: 'POST' });
  assert.equal((await state()).importApplications, 1);
  assert.equal((await state()).commits, 1);
  assert.equal((await state()).subscriptions.some((s) => s.franchiseId === 'qa-plan'), true);
});

test('erasure tombstone rejects late writes and remains inspectable until explicit reset', async (t) => {
  const { request, state, fault } = await setup(t);
  await fault('drop-after-commit', '/me');
  await assert.rejects(request('/me', { method: 'DELETE' }));
  const erased = await state();
  assert.equal(erased.erased, true);
  assert.deepEqual(erased.progress, []);
  assert.deepEqual(erased.subscriptions, []);
  assert.equal((await request('/me/progress', { method: 'PUT', body: { mediaId: 1001, episodes: 10 } })).status, 410);
  assert.equal((await state()).commits, 1);
  assert.equal((await state('fixture-b')).erased, false);
  await request('/__qa/reset', { method: 'POST', control: true, body: { account: 'fixture-a' } });
  assert.equal((await state()).erased, false);
  assert.equal((await state()).progress[0].episodes, 3);
});

test('deletion cleanup pending and complete reconcile without restoring erased tracking data', async (t) => {
  const { request, state } = await setup(t);
  assert.equal((await request('/__qa/deletion', { method: 'POST', body: { account: 'fixture-a', mode: 'pending' } })).status, 401);
  assert.equal((await request('/__qa/deletion', { method: 'POST', control: true, body: { account: 'fixture-a', mode: 'pending' } })).status, 200);
  const pending = await request('/me', { method: 'DELETE' });
  assert.equal(pending.status, 202);
  assert.deepEqual(pending.data, { deleted: false, status: 'pending', appleRevocation: 'not_applicable' });
  assert.deepEqual((await request('/me/deletion')).data, { deleted: false, status: 'pending', appleRevocation: 'not_applicable' });
  assert.equal((await state()).deletionRequests, 1);
  assert.deepEqual((await state()).progress, []);
  await request('/__qa/deletion', { method: 'POST', control: true, body: { account: 'fixture-a', mode: 'complete' } });
  assert.deepEqual((await request('/me/deletion')).data, { deleted: true, status: 'complete', appleRevocation: 'not_applicable' });
  assert.equal((await state()).deletionStatusReads, 2);
  assert.equal((await state()).commits, 1);
  assert.equal((await state('fixture-b')).deletionStatus, 'active');
});

test('definitive authenticated deletion refusal leaves account active and tracking writable', async (t) => {
  const { request, state } = await setup(t);
  await request('/__qa/deletion', { method: 'POST', control: true, body: { account: 'fixture-a', mode: 'refuse-next' } });
  const refused = await request('/me', { method: 'DELETE' });
  assert.equal(refused.status, 400);
  assert.deepEqual(refused.data, { error: 'unexpected body' });
  assert.equal((await state()).erased, false);
  assert.equal((await state()).commits, 0);
  assert.deepEqual((await request('/me/deletion')).data, { deleted: false, status: 'active', appleRevocation: 'not_applicable' });
  assert.equal((await request('/me/progress', { method: 'PUT', body: { mediaId: 1001, episodes: 4 } })).status, 200);
  assert.equal((await state()).progressCommits, 1);
});

test('lost deletion response commits once and status-only reconciliation cannot recreate the account', async (t) => {
  const { request, state, fault } = await setup(t);
  await request('/__qa/deletion', { method: 'POST', control: true, body: { account: 'fixture-a', mode: 'pending' } });
  await fault('drop-after-commit', '/me');
  await assert.rejects(request('/me', { method: 'DELETE' }));
  const committed = await state();
  assert.equal(committed.erased, true);
  assert.equal(committed.deletionRequests, 1);
  assert.equal(committed.deletionStatus, 'pending');
  await request('/me/deletion');
  assert.equal((await state()).mutationAttempts, committed.mutationAttempts);
  assert.equal((await state()).ordinaryRequestsAfterErasure, 0);
  assert.equal((await state()).commits, committed.commits);
});

test('deleted watch session cannot resurrect on a delayed retry', async (t) => {
  const { request, state } = await setup(t);
  const id = '00000000-0000-4000-8000-000000000001';
  const body = { franchiseId: 'qa-anime', ordinal: 1, episodes: 4 };
  assert.equal((await request(`/me/watch-sessions/${id}`, { method: 'PUT', body })).status, 204);
  assert.equal((await request(`/me/watch-sessions/${id}`, { method: 'DELETE' })).status, 204);
  assert.equal((await request(`/me/watch-sessions/${id}`, { method: 'PUT', body })).status, 410);
  assert.deepEqual((await state()).sessions, []);
  assert.equal((await state()).commits, 2);
  assert.equal((await state()).progressCommits, 0);
});

test('logical replay ignores JSON object key ordering', async (t) => {
  const { request, state } = await setup(t);
  const id = '00000000-0000-4000-8000-000000000002';
  await request(`/me/watch-sessions/${id}`, { method: 'PUT', body: { franchiseId: 'qa-anime', ordinal: 1, episodes: 4 } });
  await request(`/me/watch-sessions/${id}`, { method: 'PUT', body: { episodes: 4, ordinal: 1, franchiseId: 'qa-anime' } });
  assert.equal((await state()).commits, 1);
});

test('fault state synchronizes a delayed request and erasure blocks its late mutation', async (t) => {
  const { request, state, fault } = await setup(t);
  await fault('delay', '/me/progress', { delayMs: 150 });
  const delayed = request('/me/progress', { method: 'PUT', body: { mediaId: 1001, episodes: 5 } });
  const deadline = performance.now() + 1000;
  let observed;
  while (performance.now() < deadline) {
    observed = (await state()).faults[0];
    if (observed.inFlight === 1) break;
  }
  assert.deepEqual(observed, { kind: 'delay', path: '/me/progress', remaining: 0, inFlight: 1 });
  assert.equal((await state('fixture-b')).faults.length, 0);
  await request('/me', { method: 'DELETE' });
  assert.equal((await delayed).status, 410);
  assert.deepEqual((await state()).progress, []);
  assert.equal((await state()).faults[0].inFlight, 0);
  assert.equal((await state()).commits, 1);
});

test('reset replaces account state so a previously in-flight write cannot contaminate the next run', async (t) => {
  const { request, state, fault } = await setup(t);
  await fault('delay', '/me/progress', { delayMs: 150 });
  const delayed = request('/me/progress', { method: 'PUT', body: { mediaId: 1001, episodes: 7 } });
  const deadline = performance.now() + 1000;
  let observed = false;
  while (performance.now() < deadline) {
    if ((await state()).faults[0]?.inFlight === 1) { observed = true; break; }
  }
  assert.equal(observed, true, 'Old request must be inside the controlled delay before reset.');
  await request('/__qa/reset', { method: 'POST', control: true, body: { account: 'fixture-a' } });
  assert.equal((await delayed).status, 200); // Reply belongs to the old account object.
  const after = await state();
  assert.deepEqual(after.progress, [{ mediaId: 1001, episodes: 3 }, { mediaId: 2001, episodes: 2 }]);
  assert.equal(after.commits, 0);
  assert.equal(after.progressCommits, 0);
  assert.equal(after.mutationAttempts, 0);
  assert.deepEqual(after.faults, []);
});

test('redacted application logs stay bounded and exclude sensitive request values', async (t) => {
  const records = [];
  const { request, fault } = await setup(t, (record) => records.push(record));
  await fault('delay', '/search', { delayMs: 50 });
  const started = performance.now();
  const result = await request('/search?q=anime');
  assert.ok(performance.now() - started >= 40);
  assert.deepEqual(result.data.franchises.map((f) => f.id), ['qa-anime']);
  assert.deepEqual((await request('/search?q=%20%20')).data.franchises, []);
  await request('/me/import/preview?async=1', { method: 'POST', body: { source: 'anilist', username: 'do-not-log-this' } });
  for (let i = 0; i < 2_005; i++) await request('/health');
  const logs = (await request('/__qa/logs', { control: true })).data.logs;
  assert.equal(logs.length, 2_000);
  assert.equal(JSON.stringify(records).includes(TOKEN), false);
  assert.equal(JSON.stringify(records).includes('do-not-log-this'), false);
  assert.equal(JSON.stringify(records).includes('q=anime'), false);
});

for (const kind of ['hold-before-commit', 'hold-after-commit']) {
  test(`${kind} can be synchronized and aborted without a delayed second effect`, async (t) => {
    const { request, state, fault } = await setup(t);
    await fault(kind, '/me/progress');
    const pending = request('/me/progress', { method: 'PUT', body: { mediaId: 1001, episodes: 4 } }).catch(() => null);
    let held;
    const deadline = Date.now() + 3000;
    while (Date.now() < deadline) {
      held = await state();
      if (held.faults.at(-1)?.inFlight === 1) break;
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    assert.equal(held.faults.at(-1).inFlight, 1);
    assert.equal(held.progress.find((p) => p.mediaId === 1001).episodes, kind === 'hold-before-commit' ? 3 : 4);
    assert.equal(held.progressCommits, kind === 'hold-before-commit' ? 0 : 1);
    const logs = (await request('/__qa/logs', { control: true })).data.logs;
    assert.equal(logs.at(-1).outcome, kind === 'hold-before-commit' ? 'held-before-commit' : 'held-after-commit');
    assert.equal((await request('/__qa/release', { method: 'POST', control: true,
      body: { account: 'fixture-a', path: '/me/progress', disposition: 'abort' } })).status, 200);
    assert.equal(await pending, null);
    const settled = await state();
    assert.equal(settled.faults.at(-1).inFlight, 0);
    assert.equal(settled.progressCommits, held.progressCommits);
    assert.equal((await request('/__qa/release', { method: 'POST', control: true,
      body: { account: 'fixture-a', path: '/me/progress', disposition: 'abort' } })).status, 409);
  });
}

test('live trailer contract requires explicit isolated opt-in and resets to no external media', async (t) => {
  const { request } = await setup(t);
  assert.equal((await request('/franchises/qa-anime')).data.featuredVideo, null);
  assert.equal((await request('/__qa/trailer', { method: 'POST', control: true,
    body: { account: 'fixture-a', enabled: true } })).status, 200);
  const detail = (await request('/franchises/qa-anime')).data;
  assert.equal(detail.featuredVideo.id, 'M7lc1UVf-VE');
  assert.equal(detail.featuredVideo.site, 'youtube');
  assert.equal((await request('/franchises/qa-tv')).data.featuredVideo, null);
  await request('/__qa/reset', { method: 'POST', control: true, body: { account: 'fixture-a' } });
  assert.equal((await request('/franchises/qa-anime')).data.featuredVideo, null);
});

test('manual Apple revocation metadata survives deletion and canonical status without proof logging', async (t) => {
  const { request } = await setup(t);
  assert.equal((await request('/__qa/deletion', { method: 'POST', control: true,
    body: { account: 'fixture-a', mode: 'complete', appleRevocation: 'manual_required' } })).status, 200);
  const deleted = await request('/me', { method: 'DELETE', body: { apple: {
    identityToken: 'synthetic-sensitive-identity', authorizationCode: 'synthetic-sensitive-code',
  } } });
  assert.equal(deleted.data.appleRevocation, 'manual_required');
  assert.equal((await request('/me/deletion')).data.appleRevocation, 'manual_required');
  const logs = JSON.stringify((await request('/__qa/logs', { control: true })).data);
  assert.equal(logs.includes('synthetic-sensitive'), false);
});
