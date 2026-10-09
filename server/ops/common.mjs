import { createHash, randomBytes } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { spawn } from 'node:child_process';
import { chmod, lstat, mkdir, open, readFile, readdir, realpath, rename, rm, stat } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import dotenv from 'dotenv';

export const serverRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const sha256 = (value) => createHash('sha256').update(value).digest('hex');
export async function hashFile(path) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest('hex');
}
export const stamp = () => new Date().toISOString().replace(/[-:.]/g, '');
export const nonce = () => randomBytes(6).toString('hex');
export function opsRoot() {
  return resolve(process.env.PREVIOUSLY_OPS_ROOT || join(homedir(), 'Infra', 'previously'));
}
export async function privateDirectory(path) {
  await mkdir(path, { recursive: true, mode: 0o700 });
  const info = await lstat(path);
  if (!info.isDirectory() || info.isSymbolicLink()) throw new Error('unsafe operational directory');
  await chmod(path, 0o700);
  return realpath(path);
}
export async function atomicJSON(path, data) {
  await privateDirectory(dirname(path));
  const temp = path + '.pending-' + nonce();
  const file = await open(temp, 'wx', 0o600);
  try { await file.writeFile(JSON.stringify(data) + '\n'); await file.sync(); }
  finally { await file.close(); }
  try {
    await rename(temp, path);
    // Make the rename durable as well as the content before reporting success.
    const directory = await open(dirname(path), 'r');
    try { await directory.sync(); } finally { await directory.close(); }
  } catch (error) { await rm(temp, { force: true }); throw error; }
}
export async function config() {
  const file = process.env.PREVIOUSLY_ENV_FILE || join(serverRoot, '.env');
  const info = await lstat(file);
  if (!info.isFile() || info.isSymbolicLink() || (info.mode & 0o077) !== 0) throw new Error('unsafe environment file');
  const values = dotenv.parse(await readFile(file));
  return { ...values, ...process.env };
}
export function pgEnvironment(values, database) {
  const url = new URL(values.DATABASE_URL || 'postgres://localhost:5432/previously');
  if (!['postgres:', 'postgresql:'].includes(url.protocol) || url.hash) throw new Error('invalid database configuration');
  const name = database || decodeURIComponent(url.pathname.slice(1));
  if (!/^[A-Za-z0-9_][A-Za-z0-9_.-]{0,62}$/.test(name)) throw new Error('invalid database name');
  const env = { ...process.env, PGDATABASE: name, PGHOST: url.hostname || 'localhost', PGPORT: url.port || '5432',
    ...(url.username ? { PGUSER: decodeURIComponent(url.username) } : {}),
    ...(url.password ? { PGPASSWORD: decodeURIComponent(url.password) } : {}) };
  const sslmode = url.searchParams.get('sslmode');
  if (sslmode) env.PGSSLMODE = sslmode;
  // Credentials travel only in the subprocess environment, never in arguments.
  return env;
}
export async function command(binary, args, env, { timeoutMs = 120_000, stdoutLimit = 16 * 1024 * 1024 } = {}) {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(binary, args, { env, stdio: ['ignore', 'pipe', 'pipe'] });
    const chunks = []; let bytes = 0; let stderrBytes = 0; let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; child.kill('SIGKILL'); }, timeoutMs);
    child.stdout.on('data', (chunk) => {
      bytes += chunk.length;
      if (bytes > stdoutLimit) { child.kill('SIGKILL'); return; }
      chunks.push(chunk);
    });
    // Do not copy provider/connection stderr into logs or exception strings.
    child.stderr.on('data', (chunk) => { stderrBytes += chunk.length; });
    child.once('error', () => { clearTimeout(timer); reject(new Error('operational command could not start')); });
    child.once('close', (code) => {
      clearTimeout(timer);
      if (code !== 0 || timedOut || bytes > stdoutLimit) {
        const error = new Error(timedOut ? 'operational command timed out' : 'operational command failed');
        error.code = code; error.stderrBytes = stderrBytes; reject(error);
      } else resolvePromise(Buffer.concat(chunks).toString('utf8'));
    });
  });
}
export async function pruneOwned(directory, regex, maxAgeDays, maxFiles = Infinity) {
  const cutoff = Date.now() - maxAgeDays * 86_400_000;
  const entries = [];
  for (const name of await readdir(directory)) {
    if (!regex.test(name)) continue;
    const path = join(directory, name); const info = await lstat(path);
    if (!info.isFile() || info.isSymbolicLink()) throw new Error('unsafe owned operational file');
    entries.push({ path, modified: info.mtimeMs });
  }
  entries.sort((a, b) => b.modified - a.modified);
  let removed = 0;
  for (let index = 0; index < entries.length; index++) {
    if (entries[index].modified < cutoff || index >= maxFiles) { await rm(entries[index].path); removed++; }
  }
  return removed;
}
export async function sourceFingerprint(root = serverRoot) {
  const result = {};
  async function visit(directory, relative) {
    for (const entry of (await readdir(directory, { withFileTypes: true })).sort((a,b)=>a.name.localeCompare(b.name))) {
      if (entry.isSymbolicLink()) throw new Error('source manifest contains a symlink');
      const next = relative + '/' + entry.name;
      if (entry.isDirectory()) await visit(join(directory, entry.name), next);
      else if (entry.isFile()) result[next] = sha256(await readFile(join(directory, entry.name)));
    }
  }
  for (const name of ['src','drizzle','ops']) await visit(join(root, name), name);
  const compiled = await lstat(join(root, 'dist')).catch(error => { if (error.code === 'ENOENT') return null; throw error; });
  if (compiled) { if (!compiled.isDirectory() || compiled.isSymbolicLink()) throw new Error('unsafe compiled source directory'); await visit(join(root, 'dist'), 'dist'); }
  for (const name of ['package.json','package-lock.json']) result[name] = sha256(await readFile(join(root, name)));
  return { sha256: sha256(JSON.stringify(result)), files: result };
}
