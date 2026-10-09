import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, readdir, rm, stat, utimes, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { sanitizeLog, rotatingWriter } from './run-server.mjs';
import { collect, sanitizeMetrics, sanitizeUsage } from './collect.mjs';
import { pruneOwned } from './common.mjs';
async function scratch(run){const directory=await mkdtemp(join(tmpdir(),'previously-ops-'));try{await run(directory);}finally{await rm(directory,{recursive:true});}}
test('sanitized logs exclude identities, query strings, tokens and free text',()=>{
  const result=sanitizeLog(JSON.stringify({event:'request.error',level:50,status:500,route:'GET /me',requestId:'req-123',reason:'api_error',err:{code:'ECONNRESET',stack:'private'},email:'owner@example.com',token:'sk_live_secret',query:'secret search',message:'private',clerkId:'user_private'}));
  assert.deepEqual(result,{event:'request.error',level:50,status:500,route:'GET /me',requestId:'req-123',reason:'api_error',errorCode:'ECONNRESET'});
  assert.deepEqual(sanitizeLog('owner@example.com sk_live_secret'),{event:'child.unstructured_output_redacted'});
  assert.equal(sanitizeLog(JSON.stringify({route:'GET /me?q=user_private'})).route,undefined);
  assert.equal(sanitizeLog(JSON.stringify({event:'cron.failed',job:'anime_sync',message:'private'})).job,'anime_sync');
  assert.equal(sanitizeLog(JSON.stringify({job:'private@example.com'})).job,undefined);
});
test('metrics and usage snapshots retain only aggregate fields',()=>{
  const metrics=sanitizeMetrics({measuredAt:42,uptimeSeconds:4,clerkId:'user_secret',routes:{'GET /me':{requests:5,errors:1,totalMs:10,buckets:[1,2],statuses:{'2xx':4,'5xx':1,email:'secret'},search:'secret'},'GET /me?q=private':{requests:1}},memory:{rss:9,user:'secret'}});
  assert.equal(Object.keys(metrics.routes).length,1);assert.ok(!JSON.stringify(metrics).includes('secret'));
  const usage=sanitizeUsage({measuredAt:{email:'secret'},counts:{registered:2,email:'secret'},deletion:{pending:1,clerkId:'secret'}});
  assert.deepEqual(usage,{counts:{registered:2},deletion:{pending:1}});
});
test('rotation enforces segment and age limits without deleting foreign files',()=>scratch(async directory=>{
  const old=join(directory,'previously-20260101T000000000Z-abcdefabcdef.ndjson');await writeFile(old,'old');await utimes(old,new Date(0),new Date(0));
  await writeFile(join(directory,'other-project.log'),'untouched');
  const writer=await rotatingWriter(directory,{segmentBytes:90,maxSegments:3,maxAgeDays:7});
  for(let i=0;i<10;i++)await writer.write({event:'request.complete',status:200,durationMs:i});
  await writer.close();const files=(await readdir(directory)).filter(name=>name.endsWith('.ndjson'));
  assert.ok(files.length<=3);assert.ok(!files.includes(old.split('/').pop()));
  assert.equal(await readFile(join(directory,'other-project.log'),'utf8'),'untouched');
  for(const file of files){assert.ok((await stat(join(directory,file))).size<=90);assert.equal((await stat(join(directory,file))).mode&0o777,0o600);}
}));
test('30-day aggregate pruning only removes owned expired files',()=>scratch(async directory=>{
  const old=join(directory,'previously-20260101T000000000Z.json');await writeFile(old,'old');await utimes(old,new Date(0),new Date(0));
  await writeFile(join(directory,'other.json'),'private');await writeFile(join(directory,'previously-20261006T120000000Z.json'),'new');
  assert.equal(await pruneOwned(directory,/^previously-\d{8}T\d{9}Z\.json$/,30),1);
  assert.deepEqual((await readdir(directory)).sort(),['other.json','previously-20261006T120000000Z.json']);
}));
test('a stopped backend does not suspend backup, log or snapshot expiry',()=>scratch(async directory=>{
  const names={backups:'previously-20260101T000000000Z-abcdefabcdef.pending',logs:'previously-20260101T000000000Z-abcdefabcdef.ndjson',snapshots:'previously-20260101T000000000Z.json'};
  for(const [sub,name] of Object.entries(names)){await mkdir(join(directory,sub));const old=join(directory,sub,name);await writeFile(old,'expired');await utimes(old,new Date(0),new Date(0));await writeFile(join(directory,sub,'other-project.file'),'retained');}
  await writeFile(join(directory,'status.json'),JSON.stringify({healthy:true,measuredAt:'2026-10-05T00:00:00.000Z'}));
  await assert.rejects(collect({values:{OBSERVABILITY_TOKEN:'test-only-not-a-real-token-12345678'},directory,fetcher:async()=>{throw new Error('backend stopped: private-connection-detail');}}),/operational collection failed/);
  for(const sub of Object.keys(names))assert.deepEqual(await readdir(join(directory,sub)),['other-project.file']);
  const status=JSON.parse(await readFile(join(directory,'status.json'),'utf8'));
  assert.equal(status.healthy,false);assert.equal(status.reason,'collection_failed');
  assert.ok(Date.parse(status.measuredAt)>Date.parse('2026-10-05T00:00:00.000Z'));
  assert.ok(!JSON.stringify(status).includes('private-connection-detail'));
}));
