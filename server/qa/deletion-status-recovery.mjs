// Self-owned fixture runner. Never accepts a production database URL and never reaches Clerk.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, readFile, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Socket } from 'node:net';
import { command } from '../ops/common.mjs';
const serverRoot=resolve(fileURLToPath(new URL('..',import.meta.url)));
const node='/opt/homebrew/opt/node@24/bin/node';
async function child() {
  const target=new URL(process.env.DATABASE_URL||'');
  assert.equal(target.hostname,'127.0.0.1');assert.match(target.pathname,/^\/previously_qa_status_[a-f0-9]{32}$/);
  assert.equal(process.env.DOTENV_CONFIG_PATH,'/dev/null');assert.equal(process.env.APP_ENV,'test');assert.equal(process.env.DEV_AUTH_BYPASS,'1');assert.match(basename(process.env.PREVIOUSLY_OPS_ROOT||''),/^previously_qa_status_ops_/);
  for(const key of ['CLERK_SECRET_KEY','CLERK_JWT_KEY','OPENROUTER_API_KEY','CEREBRAS_API_KEY','TMDB_ACCESS_TOKEN'])assert.equal(process.env[key],'');
  let rejectedOutbound=0;const oldFetch=globalThis.fetch,oldConnect=Socket.prototype.connect;
  globalThis.fetch=async()=>{rejectedOutbound++;throw new Error('Status recovery QA forbids outbound fetch');};
  Socket.prototype.connect=function(...args){const options=args[0],host=typeof options==='number'?args[1]:options?.host;assert.ok(!options?.path&&['127.0.0.1','localhost','::1'].includes(host),'Loopback sockets only');return Reflect.apply(oldConnect,this,args);};
  const {persistDeletionRecords,readDeletionLedger}=await import('../ops/ledger.mjs');await persistDeletionRecords([]);
  const {db,sql}=await import('../src/db/index.js');
  const {buildServer}=await import('../src/server.js');
  const {upsertUser}=await import('../src/services/users.js');
  const {deletionState,identityHash}=await import('../src/services/deletionLedger.js');
  const app=await buildServer(); // inject only: no listener, worker, cron or explicit reconciliation.
  const cases=[];const record=(name,evidence)=>cases.push({name,status:'passed',evidence});
  const identity='qa-status-'+randomUUID(),headers={authorization:'Bearer dev:'+identity},media=340000001;
  try {
    assert.equal((await sql`select current_database() as name`)[0].name,target.pathname.slice(1));
    await sql`insert into media(id,title_english,format,status,episodes) values(${media},'Synthetic status QA','TV','FINISHED',12)`;
    const account=await upsertUser(identity);
    await sql`insert into progress(user_id,media_id,episodes_watched) values(${account.id},${media},7)`;
    await sql`insert into client_mutation_operations(user_id,operation_id,writer_id,sequence,request_hash,kind) values(${account.id},${randomUUID()},${randomUUID()},1,${'0'.repeat(64)},'qa')`;
    await sql`insert into client_mutation_resources(user_id,writer_id,resource_key,sequence) values(${account.id},${randomUUID()},${'media:'+media},1)`;
    await sql`create table qa_status_fault(clerk_id text primary key)`;
    await sql.unsafe(`create function qa_status_fail_delete() returns trigger language plpgsql as $$ begin if exists(select 1 from qa_status_fault where clerk_id=OLD.clerk_id) then raise exception 'Synthetic commit failure' using errcode='P0001'; end if; return OLD; end $$`);
    await sql.unsafe('create trigger qa_status_before_delete before delete on users for each row execute function qa_status_fail_delete()');
    await sql`insert into qa_status_fault values(${identity})`;
    const attempt=await app.inject({method:'DELETE',url:'/me',headers});assert.equal(attempt.statusCode,500);
    const counts=async()=>{const [row]=await sql`select (select count(*)::int from users where id=${account.id}) as users,(select count(*)::int from progress where user_id=${account.id}) as progress,(select count(*)::int from client_mutation_operations where user_id=${account.id}) as receipts,(select count(*)::int from client_mutation_resources where user_id=${account.id}) as cursors`;return {...row};};
    assert.deepEqual(await counts(),{users:1,progress:1,receipts:1,cursors:1});assert.equal(await deletionState(identity),undefined);
    const journal=await readDeletionLedger();assert.ok(journal.payload.records.some(row=>row.identityHash===identityHash(identity)&&row.clerkId===identity));
    record('real DELETE rollback leaves rows intact and only independent pending intent',{deleteStatus:500,users:1,progress:1,receipts:1,cursors:1,dbDeletionRows:0,journalPending:true});
    const unavailable=await app.inject({method:'GET',url:'/me/deletion',headers});assert.equal(unavailable.statusCode,500);assert.notEqual(unavailable.json().status,'active');assert.notEqual(unavailable.json().status,'pending');assert.deepEqual(await counts(),{users:1,progress:1,receipts:1,cursors:1});
    record('failed status reconciliation remains unknown and cannot release native hold',{status:500,active:false,pendingReceipt:false,trackingRowsStillPresent:true});
    await sql`delete from qa_status_fault`;
    const status=await app.inject({method:'GET',url:'/me/deletion',headers});assert.equal(status.statusCode,202);assert.deepEqual(status.json(),{deleted:false,status:'pending',appleRevocation:'manual_required'});assert.deepEqual(await counts(),{users:0,progress:0,receipts:0,cursors:0});const deletion=await deletionState(identity);assert.ok(deletion);assert.equal(deletion.completedAt,null);
    record('authenticated status alone reconciles and erases rows before pending receipt',{status:202,users:0,progress:0,receipts:0,cursors:0,pending:true,explicitReconcileInvocations:0});
    const write=await app.inject({method:'PUT',url:'/me/progress',headers,payload:{mediaId:media,episodesWatched:8}});assert.equal(write.statusCode,401);assert.deepEqual(write.json(),{error:'account deleted'});assert.deepEqual(await counts(),{users:0,progress:0,receipts:0,cursors:0});assert.equal((await sql`select count(*)::int as count from users where clerk_id=${identity}`)[0].count,0);
    record('subsequent real authenticated progress write is denied without recreating account',{status:401,accountRecreated:false,ownedRows:0});
    assert.equal(rejectedOutbound,0);return {fixtureVersion:'deletion-status-recovery-v1',cases,summary:{passed:cases.length,failed:0,total:cases.length},rejectedOutbound,realClerkCalls:0,listenerStarted:false,productionDataReadOrWritten:false};
  }finally{await app.close();await sql.end({timeout:5});globalThis.fetch=oldFetch;Socket.prototype.connect=oldConnect;}
}
async function parent() {
  process.chdir(serverRoot);
  const directory=await mkdtemp(join(tmpdir(),'previously_qa_status_ops_')),database='previously_qa_status_'+randomUUID().replaceAll('-','');
  const output=resolve(process.argv[2]||join(serverRoot,'../docs/qa/2026-10-06/deletion-status-recovery',new Date().toISOString().replaceAll(':','-')));await mkdir(output,{recursive:true,mode:0o700});
  const env=Object.fromEntries(['PATH','HOME','TMPDIR','LANG'].filter(key=>process.env[key]).map(key=>[key,process.env[key]]));env.PATH=join(node,'..')+':'+env.PATH;
  Object.assign(env,{DATABASE_URL:'postgres://127.0.0.1:5432/'+database,DOTENV_CONFIG_PATH:'/dev/null',APP_ENV:'test',DEV_AUTH_BYPASS:'1',CLERK_SECRET_KEY:'',CLERK_JWT_KEY:'',OPENROUTER_API_KEY:'',CEREBRAS_API_KEY:'',TMDB_ACCESS_TOKEN:'',ANTHROPIC_API_KEY:'',NEWS_AGENT_DISABLED:'1',NEWS_CODEX_FALLBACK_ENABLED:'0',GROUPING_LLM_DISABLED:'1',SEARCH_CORRECT_DISABLED:'1',SOCIAL_COMMENTS_ENABLED:'0',MODERATION_ALERT_WEBHOOK_URL:'',PREVIOUSLY_OPS_ROOT:directory,PREVIOUSLY_STATUS_CHILD:'1',PGHOST:'127.0.0.1',PGDATABASE:'postgres'});
  const ledger={startedAt:new Date().toISOString(),database,databaseCreated:false,databaseRemoved:false,opsRemoved:false,productionDataReadOrWritten:false,dotenvLoaded:false,nodeVersion:(await command(node,['--version'],env)).trim()};let result;
  try {
    assert.equal((await command('psql',['-X','-At','-c',`select count(*) from pg_database where datname='${database}'`],env)).trim(),'0');
    await command('createdb',[database],env);ledger.databaseCreated=true;
    const migrations=await command(node,['--import','tsx',join(serverRoot,'src/db/migrate.ts')],env,{timeoutMs:60000});await writeFile(join(output,'migrations.log'),migrations,{mode:0o600});
    const run=await command(node,['--import','tsx',fileURLToPath(import.meta.url)],env,{timeoutMs:90000});await writeFile(join(output,'run.log'),run,{mode:0o600});
    result=JSON.parse(run.trim().split('\n').at(-1));await writeFile(join(output,'results.json'),JSON.stringify(result,null,2)+'\n',{mode:0o600});
  }finally{
    try {if(ledger.databaseCreated){assert.match(database,/^previously_qa_status_[a-f0-9]{32}$/);const activeConnections=async()=>(await command('psql',['-X','-At','-c',`select count(*) from pg_stat_activity where datname='${database}'`],env)).trim();let active=await activeConnections();const deadline=Date.now()+5000;while(active!=='0'&&Date.now()<deadline){await new Promise(resolve=>setTimeout(resolve,100));active=await activeConnections();}assert.equal(active,'0','Owned sockets must drain naturally before drop');await command('dropdb',[database],env);ledger.databaseRemoved=true;}}
    finally{assert.match(basename(directory),/^previously_qa_status_ops_/);await rm(directory,{recursive:true});ledger.opsRemoved=true;ledger.finishedAt=new Date().toISOString();await writeFile(join(output,'run-ledger.json'),JSON.stringify(ledger,null,2)+'\n',{mode:0o600});}
  }
  console.log(JSON.stringify({output,...ledger,...result}));
}
if(process.env.PREVIOUSLY_STATUS_CHILD==='1')child().then(result=>console.log(JSON.stringify(result)),()=>{console.error('Status recovery QA failed; no production access attempted.');process.exitCode=1;});
else parent().catch(()=>{console.error('Status recovery fixture failed; see private run ledger.');process.exitCode=1;});
