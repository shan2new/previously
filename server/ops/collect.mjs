import postgres from 'postgres';
import { lstat, readFile, readdir, statfs } from 'node:fs/promises';
import { join } from 'node:path';
import { atomicJSON, config, opsRoot, privateDirectory, pruneOwned, stamp } from './common.mjs';
import { pruneBackups } from './backup.mjs';
import { persistDeletionRecords } from './ledger.mjs';
const finite=(value)=>typeof value==='number'&&Number.isFinite(value)&&value>=0;
function numbers(input,keys) { const out={};for(const key of keys)if(finite(input?.[key]))out[key]=input[key];return out; }
export function sanitizeMetrics(input) {
  if(!input||!finite(input.uptimeSeconds)||!input.routes||typeof input.routes!=='object')throw new Error('invalid metrics response');
  const routes={};
  for(const [name,row] of Object.entries(input.routes).slice(0,200)) {
    if(!/^(GET|POST|PUT|DELETE|PATCH|OPTIONS|HEAD) (\/[A-Za-z0-9_/:.-]*|unmatched)$/.test(name))continue;
    const safe=numbers(row,['requests','errors','totalMs']);
    if(Array.isArray(row.buckets)&&row.buckets.length<=16&&row.buckets.every(finite))safe.buckets=row.buckets;
    safe.statuses=numbers(row.statuses,['1xx','2xx','3xx','4xx','5xx']);routes[name]=safe;
  }
  return {...numbers(input,['measuredAt','startedAt','uptimeSeconds']), memory:numbers(input.memory,['rss','heapTotal','heapUsed','external','arrayBuffers']),
    cpu:numbers(input.cpu,['user','system']),eventLoopMs:numbers(input.eventLoopMs,['mean','p95','p99']),
    latencyBucketUpperMs:Array.isArray(input.latencyBucketUpperMs)?input.latencyBucketUpperMs.filter(finite).slice(0,16):[],routes};
}
export function sanitizeUsage(input) {
  if(!finite(input?.counts?.registered))throw new Error('invalid usage response');
  return {...numbers(input,['measuredAt']),counts:numbers(input.counts,['registered','active_24h','active_7d','registered_7d','library_users','progress_users']),deletion:numbers(input.deletion,['pending'])};
}
async function boundedJSON(url,headers,limit,fetcher) {
  const response=await fetcher(url,{headers,signal:AbortSignal.timeout(8000)});
  if(response.status!==200)throw new Error('operational endpoint not healthy');
  const chunks=[];let bytes=0;
  for await(const chunk of response.body){bytes+=chunk.length;if(bytes>limit)throw new Error('operational response too large');chunks.push(chunk);}
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}
async function newestBackup(directory) {
  let latest=null;
  for(const name of await readdir(directory)) {
    if(!/^previously-\d{8}T\d{9}Z-[a-f0-9]{12}\.manifest\.json$/.test(name))continue;
    const path=join(directory,name);const info=await lstat(path);
    if(!info.isFile()||info.isSymbolicLink())throw new Error('unsafe backup metadata');
    const row=JSON.parse(await readFile(path,'utf8'));
    if(!/^previously-\d{8}T\d{9}Z-[a-f0-9]{12}\.dump$/.test(row.file)||!/^[a-f0-9]{64}$/.test(row.sha256)||!Number.isFinite(Date.parse(row.createdAt)))throw new Error('invalid backup metadata');
    const dump=await lstat(join(directory,row.file)).catch(()=>null);
    if(!dump||!dump.isFile()||dump.isSymbolicLink()||dump.size!==row.bytes)continue;
    if(!latest||row.createdAt>latest.createdAt)latest=row;
  }
  return latest?{createdAt:latest.createdAt,bytes:latest.bytes,sha256:latest.sha256,ageHours:(Date.now()-Date.parse(latest.createdAt))/3_600_000}:null;
}
async function collectSnapshot({values,directory=opsRoot(),fetcher=fetch}={}) {
  values ||= await config();await privateDirectory(directory);
  // Retention must continue even when the app endpoints are down or the token is rejected.
  await pruneBackups(join(directory,'backups'));
  const logs=join(directory,'logs');await privateDirectory(logs);
  await pruneOwned(logs,/^previously-\d{8}T\d{9}Z-[a-f0-9]{12}\.ndjson$/,7,16);
  const snapshots=join(directory,'snapshots');await privateDirectory(snapshots);
  await pruneOwned(snapshots,/^previously-\d{8}T\d{9}Z\.json$/,30);
  if(!values.OBSERVABILITY_TOKEN||values.OBSERVABILITY_TOKEN.length<32)throw new Error('operational token is missing');
  const port=Number(values.PORT||8787);if(!Number.isInteger(port)||port<1||port>65535)throw new Error('invalid operational port');
  const publicOrigin=new URL(values.PREVIOUSLY_OPS_PUBLIC_ORIGIN||'https://anime.cognipin.com');
  if(publicOrigin.protocol!=='https:'||publicOrigin.username||publicOrigin.password||publicOrigin.pathname!=='/'||publicOrigin.search||publicOrigin.hash)throw new Error('invalid public origin');
  const authorization={Authorization:'Bearer '+values.OBSERVABILITY_TOKEN};
  const [metrics,usage,ready]=await Promise.all([
    boundedJSON(`http://127.0.0.1:${port}/internal/metrics`,authorization,512*1024,fetcher).then(sanitizeMetrics),
    boundedJSON(`http://127.0.0.1:${port}/internal/usage`,authorization,16*1024,fetcher).then(sanitizeUsage),
    boundedJSON(publicOrigin.origin+'/ready',{},1024,fetcher).then(row=>row.ok===true,()=>false),
  ]);
  const sql=postgres(values.DATABASE_URL||'postgres://localhost:5432/previously',{max:1,connect_timeout:10});
  let ledger;
  try {
    const rows=await sql`select identity_hash as "identityHash",clerk_id as "clerkId",requested_at as "requestedAt",completed_at as "completedAt",attempts,next_attempt_at as "nextAttemptAt",apple_revocation as "appleRevocation" from account_deletions`;
    ledger=await persistDeletionRecords(rows,{directory:join(directory,'deletions')});
  }finally{await sql.end({timeout:5});}
  // No historical snapshot contains raw identifiers or per-person events.
  const pending=ledger.payload.records.filter(row=>!row.completedAt);
  const backup=await newestBackup(join(directory,'backups'));
  const disk=await statfs(directory);const freeDiskBytes=disk.bavail*disk.bsize;
  const snapshot={version:1,measuredAt:new Date().toISOString(),publicReady:ready,metrics,usage,
    deletion:{sha256:ledger.sha256,total:ledger.payload.records.length,pending:pending.length,
      oldestPendingHours:pending.length?Math.max(...pending.map(row=>(Date.now()-Date.parse(row.requestedAt))/3_600_000)):0,
      missingPendingIdentity:pending.filter(row=>!row.clerkId).length},backup,freeDiskBytes};
  await atomicJSON(join(snapshots,'previously-'+stamp()+'.json'),snapshot);
  await pruneOwned(snapshots,/^previously-\d{8}T\d{9}Z\.json$/,30);
  await atomicJSON(join(directory,'status.json'),{...snapshot,healthy:ready&&backup!==null&&backup.ageHours<=26&&freeDiskBytes>=2*1024**3&&snapshot.deletion.missingPendingIdentity===0});
  return snapshot;
}
export async function collect(options={}) {
  const directory=options.directory||opsRoot();
  try { return await collectSnapshot(options); }
  catch {
    // A failed probe must invalidate a previous healthy status. Keep historical successful
    // aggregate snapshots separately; never store the endpoint error or connection details.
    await atomicJSON(join(directory,'status.json'),{version:1,measuredAt:new Date().toISOString(),
      healthy:false,reason:'collection_failed'});
    throw new Error('operational collection failed');
  }
}
if(process.argv[1]?.endsWith('/collect.mjs')) {
  collect().then(result=>{const healthy=result.publicReady&&result.backup!==null&&result.backup.ageHours<=26&&result.freeDiskBytes>=2*1024**3&&result.deletion.missingPendingIdentity===0;
    console.log(JSON.stringify({event:'ops.snapshot_complete',healthy,pending:result.deletion.pending}));if(!healthy)process.exitCode=1;},
    ()=>{console.error(JSON.stringify({event:'ops.snapshot_failed'}));process.exitCode=1;});
}
