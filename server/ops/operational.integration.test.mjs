import test from 'node:test';
import assert from 'node:assert/strict';
import postgres from 'postgres';
import { mkdtemp, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { backupDatabase, pruneBackups } from './backup.mjs';
import { restoreCheck } from './restore-check.mjs';
import { collect } from './collect.mjs';
import { initializeLedger } from './initialize-ledger.mjs';
import { command, nonce, pgEnvironment, sha256 } from './common.mjs';
import { recordDeletionCompleted, recordDeletionRequested } from './ledger.mjs';

test('real PostgreSQL backup, deletion-safe restore, isolated cleanup and collection',async t=>{
  const directory=await mkdtemp(join(tmpdir(),'previously-ops-integration-'));
  const database='previously_ops_fixture_'+nonce();const values={DATABASE_URL:'postgres://localhost:5432/'+database,OBSERVABILITY_TOKEN:'test-only-not-a-real-secret-token-12345',PORT:'19499',PREVIOUSLY_OPS_PUBLIC_ORIGIN:'https://example.invalid'};
  const admin=pgEnvironment(values,'postgres');let sql;let owned=false;
  try {
    await command('createdb',[database],admin);owned=true;sql=postgres(values.DATABASE_URL,{max:1});
    await sql`create table users(id serial primary key,clerk_id text unique not null)`;
    await sql`create table account_deletions(identity_hash text primary key,clerk_id text,requested_at timestamptz not null,completed_at timestamptz,attempts integer not null default 0,next_attempt_at timestamptz not null,apple_revocation text not null default 'manual_required')`;
    await sql`create table library(id serial primary key,user_id integer not null references users(id) on delete cascade,title text)`;
    await sql`create table progress(id serial primary key,user_id integer not null references users(id) on delete cascade,episode integer)`;
    await sql`insert into users(clerk_id) values('user_keep'),('user_erased')`;
    await sql`insert into library(user_id,title) values(1,'kept library'),(2,'erased library')`;
    await sql`insert into progress(user_id,episode) values(1,7),(2,9)`;
    const ledgerDirectory=join(directory,'deletions');const backupDirectory=join(directory,'backups');
    await initializeLedger({values,directory:ledgerDirectory});
    const manifest=await backupDatabase({values,directory:backupDirectory,ledgerDirectory});
    const manifestPath=join(backupDirectory,manifest.file.replace('.dump','.manifest.json'));
    await t.test('custom dump has a checked SHA, TOC and private permissions',async()=>{
      assert.ok(manifest.bytes>0);assert.ok(manifest.tocEntries>=5);assert.match(manifest.sha256,/^[a-f0-9]{64}$/);assert.equal(manifest.deletionRecords,0);
      assert.equal((await stat(join(backupDirectory,manifest.file))).mode&0o777,0o600);assert.equal((await stat(manifestPath)).mode&0o777,0o600);
    });
    await recordDeletionRequested('user_erased',new Date(),{directory:ledgerDirectory});await recordDeletionCompleted('user_erased',new Date(),{directory:ledgerDirectory,appleRevocation:'revoked'});
    await t.test('newer independent tombstone sweeps a deleted identity from the older backup',async()=>{
      const result=await restoreCheck(manifestPath,{values,ledgerDirectory});assert.equal(result.usersBefore,2);assert.equal(result.usersAfter,1);assert.equal(result.deletedUsersSwept,1);assert.equal(result.deletedIdentitiesRemaining,0);assert.equal(result.restoredDeletionRecords,1);
      const adminSql=postgres('postgres://localhost:5432/postgres',{max:1});try{assert.equal((await adminSql`select datname from pg_database where datname=${result.scratch}`).length,0);}finally{await adminSql.end();}
      assert.equal((await sql`select count(*)::int as count from users`)[0].count,2);assert.equal((await sql`select count(*)::int as count from library`)[0].count,2);
    });
    await t.test('pre0015 backup restores proven Apple outcome in its owned scratch only',async()=>{
      await sql`alter table account_deletions drop column apple_revocation`;
      try{
        const legacy=await backupDatabase({values,directory:join(directory,'legacy'),ledgerDirectory});
        const path=join(directory,'legacy',legacy.file.replace('.dump','.manifest.json'));
        const result=await restoreCheck(path,{values,ledgerDirectory});
        assert.equal(result.deletedIdentitiesRemaining,0);assert.equal(result.restoredDeletionRecords,1);
      }finally{await sql`alter table account_deletions add column apple_revocation text not null default 'manual_required'`;}
    });
    await t.test('missing live ledger and altered dump fail before any scratch database survives',async()=>{
      await assert.rejects(restoreCheck(manifestPath,{values,ledgerDirectory:join(directory,'absent')}));
      const wrong=join(backupDirectory,'wrong.manifest.json');await writeFile(wrong,JSON.stringify({...manifest,sha256:'a'.repeat(64)}));
      await assert.rejects(restoreCheck(wrong,{values,ledgerDirectory}),/checksum mismatch/);await rm(wrong);
    });
    await t.test('hourly snapshot authenticates only to loopback and excludes individual data',async()=>{
      const calls=[];
      const fetcher=async(url,options)=>{calls.push({url,authorization:options.headers.Authorization});
        if(url.endsWith('/internal/metrics'))return new Response(JSON.stringify({measuredAt:100,uptimeSeconds:9,routes:{'GET /me':{requests:10,errors:0,totalMs:10,statuses:{'2xx':10},buckets:[10]}},clerkId:'private-user'}));
        if(url.endsWith('/internal/usage'))return new Response(JSON.stringify({measuredAt:100,counts:{registered:2,active_24h:1,email:'private-email'},deletion:{pending:0}}));
        return new Response(JSON.stringify({ok:true}));};
      const result=await collect({values,directory,fetcher});assert.equal(result.publicReady,true);assert.equal(result.deletion.pending,0);assert.equal(result.deletion.total,1);assert.ok(result.backup.ageHours<1);
      assert.equal(calls.filter(c=>c.authorization).length,2);assert.ok(calls.filter(c=>c.authorization).every(c=>c.url.startsWith('http://127.0.0.1:')));assert.equal(calls.find(c=>c.url.startsWith('https://')).authorization,undefined);
      const snapshot=await readFile(join(directory,'status.json'),'utf8');assert.ok(!snapshot.includes('private-user'));assert.ok(!snapshot.includes('private-email'));assert.ok(!snapshot.includes('user_erased'));assert.ok(!snapshot.includes(values.OBSERVABILITY_TOKEN));
    });
    await t.test('seven-pair retention prunes only owned backups',async()=>{
      await writeFile(join(backupDirectory,'other-project.dump'),'untouched');
      for(let i=0;i<8;i++){const name='previously-20261006T00000000'+i+'Z-'+nonce();await writeFile(join(backupDirectory,name+'.dump'),'fixture');await writeFile(join(backupDirectory,name+'.manifest.json'),JSON.stringify({file:name+'.dump',createdAt:new Date(Date.now()-i*1000).toISOString()}));}
      await pruneBackups(backupDirectory);assert.equal((await readdir(backupDirectory)).filter(name=>name.endsWith('.manifest.json')).length,7);assert.equal(await readFile(join(backupDirectory,'other-project.dump'),'utf8'),'untouched');
    });
    await t.test('non-cascading ownership fails closed and still drops scratch database',async()=>{
      await sql`create table unsafe_owner(id serial primary key,user_id integer)`;
      const bad=await backupDatabase({values,directory:join(directory,'bad'),ledgerDirectory});
      const badPath=join(directory,'bad',bad.file.replace('.dump','.manifest.json'));
      await assert.rejects(restoreCheck(badPath,{values,ledgerDirectory}),/ownership constraints/);
      const adminSql=postgres('postgres://localhost:5432/postgres',{max:1});try{assert.equal((await adminSql`select datname from pg_database where datname like 'previously_restore_%'`).length,0);}finally{await adminSql.end();}
    });
  }finally{try{if(sql)await sql.end();}finally{if(owned)await command('dropdb',['--if-exists',database],admin);await rm(directory,{recursive:true});}}
});
