// Transport smoke of an immutable artifact; no production configuration/database/provider.
import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { Socket } from 'node:net';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const [manifestPath, output] = process.argv.slice(2);
const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
const artifact = manifest.artifact;
assert.match(artifact, /^\/Users\/shan2new\/Infra\/previously\/releases\/\d{8}T\d{6}Z\/server$/);
assert.equal(process.env.DATABASE_URL, 'postgres://127.0.0.1:1/previously_qa_invalid');
assert.equal(process.env.DOTENV_CONFIG_PATH, '/dev/null');
assert.equal(process.env.APP_ENV, 'production');
assert.equal(process.env.DEV_AUTH_BYPASS, '0');
for (const key of ['CLERK_SECRET_KEY','CLERK_JWT_KEY','TMDB_ACCESS_TOKEN','APPLE_TEAM_ID','APPLE_KEY_ID','APPLE_PRIVATE_KEY_PATH']) assert.equal(process.env[key], '');
let outboundDenied = 0;
globalThis.fetch = async () => { outboundDenied++; throw new Error('Artifact QA denies providers'); };
const connect = Socket.prototype.connect;
Socket.prototype.connect = function(...args) {
  const options = args[0]; const host = typeof options === 'number' ? args[1] : options?.host;
  assert.ok(!options?.path && ['127.0.0.1','localhost','::1'].includes(host));
  return Reflect.apply(connect, this, args);
};
const load = module => import(pathToFileURL(join(artifact, 'dist', module + '.js')).href);
const { buildServer } = await load('server');
const { sql } = await load('db/index');
const app = await buildServer(); // no listen, worker, index or cron
const checks = [];
try {
  for (const [url, status] of [['/health',200], ['/me/library',401], ['/internal/metrics',404], ['/internal/usage',404], ['/ready',503]]) {
    const response = await app.inject(url); assert.equal(response.statusCode,status);checks.push({path:url,status});
    if (url==='/me/library') assert.equal(response.headers['cache-control'],'private, no-store');
  }
  const metrics = await app.inject({url:'/internal/metrics',headers:{authorization:'Bearer '+process.env.OBSERVABILITY_TOKEN}});
  assert.equal(metrics.statusCode,200);assert.equal(metrics.headers['cache-control'],'private, no-store');
  assert.equal(outboundDenied,0);
  await writeFile(output,JSON.stringify({at:new Date().toISOString(),artifact,runtime:process.version,checks,
    privateMetricsStatus:metrics.statusCode,privateMetricsCache:metrics.headers['cache-control'],
    databaseUnavailableReady:503,outboundDenied,listenerStarted:false,productionConfigurationRead:false,
    productionDatabaseReadOrWritten:false,providerCalls:0,installed:false},null,2)+'\n');
} finally {await app.close();await sql.end({timeout:5});}
