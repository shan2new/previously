import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { persistDeletionRecords, readDeletionLedger, recordDeletionCompleted, recordDeletionRequested } from './ledger.mjs';
import { sha256 } from './common.mjs';

async function scratch(run) {
  const directory = await mkdtemp(join(tmpdir(), 'previously-ledger-'));
  try { await run(directory); } finally { await rm(directory, { recursive: true }); }
}
test('precommit intent survives an absent database refresh',()=>scratch(async directory=>{
  await recordDeletionRequested('user_precommit',new Date('2026-10-06T00:00:00Z'),{directory});
  await persistDeletionRecords([],{directory});
  const value=await readDeletionLedger({directory});
  assert.equal(value.payload.records.length,1); assert.equal(value.payload.records[0].clerkId,'user_precommit');
  assert.equal(value.payload.records[0].completedAt,null);
}));
test('completion cannot be downgraded or restore raw ID by delayed request',()=>scratch(async directory=>{
  await recordDeletionRequested('user_order',new Date('2026-10-06T00:00:00Z'),{directory});
  await recordDeletionCompleted('user_order',new Date('2026-10-06T01:00:00Z'),{directory});
  await recordDeletionRequested('user_order',new Date('2026-10-06T02:00:00Z'),{directory});
  const value=await readDeletionLedger({directory});
  assert.equal(value.payload.records[0].clerkId,null);assert.equal(value.payload.records[0].completedAt,'2026-10-06T01:00:00.000Z');
  assert.equal(value.payload.records[0].requestedAt,'2026-10-06T00:00:00.000Z');
  for(const name of await readdir(join(directory,'markers')))assert.ok(!(await readFile(join(directory,'markers',name),'utf8')).includes('user_order'));
  assert.ok(!(await readFile(join(directory,'current.json'),'utf8')).includes('user_order'));
}));
test('concurrent requests retain every identity',()=>scratch(async directory=>{
  await Promise.all(Array.from({length:12},(_,i)=>recordDeletionRequested('user_parallel_'+i,new Date(),{directory})));
  assert.equal((await readDeletionLedger({directory})).payload.records.length,12);
}));
test('missing or corrupted authoritative current ledger fails closed',()=>scratch(async directory=>{
  await assert.rejects(readDeletionLedger({directory}));
  await recordDeletionRequested('user_corrupt',new Date(),{directory});
  const path=join(directory,'current.json');const value=JSON.parse(await readFile(path,'utf8'));
  value.payload.records=[];await writeFile(path,JSON.stringify(value));
  await assert.rejects(readDeletionLedger({directory}),/invalid current ledger/);
}));
test('immutable markers restore a tombstone after an older empty valid snapshot',()=>scratch(async directory=>{
  const empty=await persistDeletionRecords([],{directory});
  await recordDeletionRequested('user_restore',new Date(),{directory});await recordDeletionCompleted('user_restore',new Date(),{directory});
  await writeFile(join(directory,'current.json'),JSON.stringify(empty));
  const value=await persistDeletionRecords([],{directory});
  assert.equal(value.payload.records.length,1);assert.ok(value.payload.records[0].completedAt);assert.equal(value.payload.records[0].clerkId,null);
}));
test('private snapshot and marker permissions',()=>scratch(async directory=>{
  await recordDeletionRequested('user_private',new Date(),{directory});
  assert.equal((await stat(directory)).mode&0o777,0o700);
  assert.equal((await stat(join(directory,'current.json'))).mode&0o777,0o600);
  for(const name of await readdir(join(directory,'markers')))assert.equal((await stat(join(directory,'markers',name))).mode&0o777,0o600);
}));
test('unchanged ledger reads retain stable records and a matching checksum',()=>scratch(async directory=>{
  await recordDeletionRequested('user_stable',new Date('2026-10-06T00:00:00Z'),{directory});
  const first=await readDeletionLedger({directory});
  await new Promise(resolve=>setTimeout(resolve,10));
  const second=await readDeletionLedger({directory});
  assert.deepEqual(second,first);
  assert.equal(second.payload.records[0].nextAttemptAt,'2026-10-06T00:00:00.000Z');
}));
test('legacy hash-only deletion records default to conservative manual Apple fallback',()=>scratch(async directory=>{
  const value=await persistDeletionRecords([{identityHash:sha256('user_legacy'),clerkId:null,requestedAt:new Date(),completedAt:new Date()}],{directory});
  assert.equal(value.payload.records[0].appleRevocation,'manual_required');
}));
test('late Apple success survives restoring an older completed snapshot and cannot downgrade',()=>scratch(async directory=>{
  await recordDeletionRequested('user_apple',new Date(),{directory});
  const old=await recordDeletionCompleted('user_apple',new Date(),{directory});
  await persistDeletionRecords([{...old.payload.records[0],appleRevocation:'revoked'}],{directory});
  await writeFile(join(directory,'current.json'),JSON.stringify(old));
  await persistDeletionRecords([],{directory});
  await recordDeletionRequested('user_apple',new Date(),{directory,appleRevocation:'manual_required'});
  const record=(await readDeletionLedger({directory})).payload.records[0];
  assert.equal(record.appleRevocation,'revoked');assert.equal(record.clerkId,null);
  for(const name of await readdir(join(directory,'markers'))){
    const text=await readFile(join(directory,'markers',name),'utf8');
    assert.ok(!text.includes('user_apple'));assert.ok(!text.includes('authorizationCode'));assert.ok(!text.includes('identityToken'));
  }
}));
test('unknown Apple outcome is refused instead of silently claiming revocation',()=>scratch(async directory=>{
  await assert.rejects(persistDeletionRecords([{identityHash:sha256('user_unknown'),requestedAt:new Date(),appleRevocation:'maybe'}],{directory}),/invalid Apple revocation outcome/);
}));
