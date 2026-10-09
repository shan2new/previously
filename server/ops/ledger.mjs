import { link, lstat, mkdir, open, readFile, readdir, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { atomicJSON, nonce, opsRoot, privateDirectory, sha256 } from './common.mjs';

const VERSION = 1;
const appleOutcomes = new Set(['revoked', 'manual_required', 'not_applicable']);
const hashPattern = /^[a-f0-9]{64}$/;
const iso = (value, fallback) => {
  const date = new Date(value ?? fallback);
  if (!Number.isFinite(date.getTime())) throw new Error('invalid deletion date');
  return date.toISOString();
};
function normalize(row) {
  if (!hashPattern.test(row.identityHash)) throw new Error('invalid deletion hash');
  const completedAt = row.completedAt == null ? null : iso(row.completedAt);
  const clerkId = completedAt ? null : row.clerkId ?? null;
  if (clerkId !== null && (typeof clerkId !== 'string' || clerkId.length > 512 || sha256(clerkId) !== row.identityHash)) {
    throw new Error('invalid deletion identity');
  }
  const requestedAt = iso(row.requestedAt, 0);
  const appleRevocation = row.appleRevocation ?? 'manual_required';
  if (!appleOutcomes.has(appleRevocation)) throw new Error('invalid Apple revocation outcome');
  return { identityHash: row.identityHash, clerkId, requestedAt, completedAt,
    attempts: Number.isSafeInteger(row.attempts) && row.attempts >= 0 ? row.attempts : 0,
    nextAttemptAt: iso(row.nextAttemptAt, requestedAt), appleRevocation };
}
async function lock(directory, action) {
  await privateDirectory(directory);
  const path = join(directory, 'ledger.lock');
  const deadline = Date.now() + 10_000;
  while (true) {
    try {
      await mkdir(path, { mode: 0o700 });
      await atomicJSON(join(path, 'owner.json'), { pid: process.pid, nonce: nonce() });
      break;
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      try {
        const info = await lstat(path);
        if (!info.isDirectory() || info.isSymbolicLink()) throw new Error('unsafe ledger lock');
        const owner = JSON.parse(await readFile(join(path, 'owner.json'), 'utf8'));
        if (!Number.isSafeInteger(owner.pid) || owner.pid <= 0) throw new Error('invalid ledger lock');
        try { process.kill(owner.pid, 0); }
        catch (failure) { if (failure.code === 'ESRCH') { await rm(path, { recursive: true }); continue; } throw failure; }
      } catch (failure) {
        if (failure.code !== 'ENOENT') throw failure;
        // A killed owner can leave an empty lock directory before owner.json.
        // Allow that short initialization window, then reclaim only the owned lock.
        const info = await lstat(path).catch(() => null);
        if (info && Date.now() - info.mtimeMs > 30_000) { await rm(path, { recursive: true }); continue; }
      }
      if (Date.now() >= deadline) throw new Error('ledger lock timeout');
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
  }
  try { return await action(); }
  finally { await rm(path, { recursive: true }); }
}
async function snapshot(directory, required) {
  try {
    const path = join(directory, 'current.json');
    const info = await lstat(path);
    if (!info.isFile() || info.isSymbolicLink()) throw new Error('unsafe current ledger');
    const value = JSON.parse(await readFile(path, 'utf8'));
    if (value.version !== VERSION || value.sha256 !== sha256(JSON.stringify(value.payload))
      || !Array.isArray(value.payload?.records) || value.payload.records.length > 100_000) throw new Error('invalid current ledger');
    return { ...value, payload: { ...value.payload, records: value.payload.records.map(normalize) } };
  } catch (error) {
    if (error.code === 'ENOENT' && !required) return { version: VERSION, payload: { generatedAt: null, records: [] }, sha256: null };
    throw error;
  }
}
function merge(a, b) {
  if (!a) return b;
  const complete = a.completedAt || b.completedAt;
  return normalize({ ...b, clerkId: complete ? null : b.clerkId || a.clerkId,
    // A completed revocation is never downgraded by a concurrent fallback or old hash marker.
    appleRevocation: a.appleRevocation === 'revoked' || b.appleRevocation === 'revoked' ? 'revoked'
      : a.appleRevocation === 'not_applicable' || b.appleRevocation === 'not_applicable' ? 'not_applicable' : 'manual_required',
    requestedAt: a.requestedAt < b.requestedAt ? a.requestedAt : b.requestedAt,
    completedAt: a.completedAt || b.completedAt, attempts: Math.max(a.attempts, b.attempts),
    nextAttemptAt: a.nextAttemptAt > b.nextAttemptAt ? a.nextAttemptAt : b.nextAttemptAt });
}
async function markerRows(directory) {
  const markers = join(directory, 'markers'); await privateDirectory(markers);
  const rows = [];
  for (const name of await readdir(markers)) {
    if (/^\.pending-[a-f0-9]{12}$/.test(name)) continue;
    if (!/^[a-f0-9]{64}\.(requested|completed|apple-revoked|apple-not-applicable)\.json$/.test(name)) throw new Error('unexpected deletion marker');
    const path = join(markers, name); const info = await lstat(path);
    if (!info.isFile() || info.isSymbolicLink()) throw new Error('unsafe deletion marker');
    const row = JSON.parse(await readFile(path, 'utf8'));
    if (row.identityHash !== name.slice(0,64) || Object.hasOwn(row, 'clerkId')) throw new Error('invalid deletion marker');
    rows.push(normalize(row));
  }
  return rows;
}
async function immutableMarker(path, row) {
  const directoryPath = join(path, '..');
  const pending = join(directoryPath, '.pending-' + nonce());
  const file = await open(pending, 'wx', 0o600);
  try { await file.writeFile(JSON.stringify(row) + '\n'); await file.sync(); }
  finally { await file.close(); }
  try {
    // Hard-link creates the immutable final name atomically without overwriting it.
    try { await link(pending, path); }
    catch (error) { if (error.code !== 'EEXIST') throw error; }
    const directory = await open(directoryPath, 'r');
    try { await directory.sync(); } finally { await directory.close(); }
  } finally { await rm(pending, { force: true }); }
}
async function update(records, directory) {
  return lock(directory, async () => {
    const current = await snapshot(directory, false);
    const combined = new Map();
    for (const row of [...current.payload.records, ...records.map(normalize), ...await markerRows(directory)]) {
      combined.set(row.identityHash, merge(combined.get(row.identityHash), row));
    }
    const sorted = [...combined.values()].sort((a,b)=>a.identityHash.localeCompare(b.identityHash));
    const payload = { generatedAt: new Date().toISOString(), records: sorted };
    const next = { version: VERSION, payload, sha256: sha256(JSON.stringify(payload)) };
    // Current pending raw IDs become durable BEFORE the hash-only immutable marker.
    await atomicJSON(join(directory, 'current.json'), next);
    for (const row of sorted) {
      const base = { identityHash: row.identityHash, requestedAt: row.requestedAt, appleRevocation: row.appleRevocation };
      await immutableMarker(join(directory, 'markers', row.identityHash + '.requested.json'), base);
      if (row.completedAt) await immutableMarker(join(directory, 'markers', row.identityHash + '.completed.json'),
        { ...base, completedAt: row.completedAt });
      // A provider receipt can arrive after an earlier completed marker was written. Preserve
      // that proven outcome independently of current.json and of the first completion marker.
      if (row.appleRevocation !== 'manual_required') await immutableMarker(
        join(directory, 'markers', row.identityHash + '.apple-' + row.appleRevocation.replace('_', '-') + '.json'), base);
    }
    return next;
  });
}
export async function persistDeletionRecords(records, options = {}) {
  return update(records, options.directory || join(opsRoot(), 'deletions'));
}
export async function recordDeletionRequested(clerkId, requestedAt = new Date(), options = {}) {
  return persistDeletionRecords([{ identityHash: sha256(clerkId), clerkId, requestedAt, completedAt: null,
    attempts: 0, nextAttemptAt: requestedAt, appleRevocation: options.appleRevocation ?? 'manual_required' }], options);
}
export async function recordDeletionCompleted(clerkId, completedAt = new Date(), options = {}) {
  return persistDeletionRecords([{ identityHash: sha256(clerkId), clerkId: null, requestedAt: completedAt,
    completedAt, attempts: 0, nextAttemptAt: completedAt, appleRevocation: options.appleRevocation ?? 'manual_required' }], options);
}
export async function readDeletionLedger(options = {}) {
  const directory = options.directory || join(opsRoot(), 'deletions');
  return lock(directory, async () => {
    const current = await snapshot(directory, options.requireExisting !== false);
    const combined = new Map();
    for (const row of [...current.payload.records, ...await markerRows(directory)]) combined.set(row.identityHash, merge(combined.get(row.identityHash), row));
    const payload = { ...current.payload,
      records: [...combined.values()].sort((a,b)=>a.identityHash.localeCompare(b.identityHash)) };
    return { ...current, payload, sha256: sha256(JSON.stringify(payload)) };
  });
}
