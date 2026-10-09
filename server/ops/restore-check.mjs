import postgres from 'postgres';
import { lstat, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { command, config, hashFile, nonce, opsRoot, pgEnvironment, stamp } from './common.mjs';
import { readDeletionLedger } from './ledger.mjs';

// This check NEVER replaces or restores over the configured production database.
export async function restoreCheck(manifestPath, { values, ledgerDirectory=join(opsRoot(),'deletions') }={}) {
  values ||= await config();
  const info=await lstat(manifestPath);if(!info.isFile()||info.isSymbolicLink())throw new Error('unsafe restore manifest');
  const manifest=JSON.parse(await readFile(manifestPath,'utf8'));
  if(manifest.version!==1||!/^previously-\d{8}T\d{9}Z-[a-f0-9]{12}\.dump$/.test(manifest.file))throw new Error('invalid restore manifest');
  const dump=join(manifestPath,'..',manifest.file);const dumpInfo=await lstat(dump);
  if(!dumpInfo.isFile()||dumpInfo.isSymbolicLink()||dumpInfo.size!==manifest.bytes||await hashFile(dump)!==manifest.sha256)throw new Error('restore checksum mismatch');
  const ledger=await readDeletionLedger({directory:ledgerDirectory});
  const scratch='previously_restore_'+stamp().slice(0,15).toLowerCase()+'_'+nonce();
  if(!/^previously_restore_[a-z0-9_]+$/.test(scratch))throw new Error('invalid owned scratch database');
  const admin=pgEnvironment(values,'postgres');let owned=false;let sql;
  try {
    await command('createdb',[scratch],admin);owned=true;
    await command('pg_restore',['--exit-on-error','--no-owner','--no-privileges','--dbname',scratch,dump],admin,{timeoutMs:300_000});
    const url=new URL(values.DATABASE_URL||'postgres://localhost:5432/previously');url.pathname='/'+scratch;
    sql=postgres(url.toString(),{max:1,connect_timeout:10});
    // Every user ownership column must have a real cascading FK before a sweep can be trusted.
    const missing=await sql`select c.table_name,c.column_name from information_schema.columns c
      where c.table_schema='public' and c.column_name in ('user_id','actor_user_id','blocked_user_id')
      and not exists(select 1 from pg_constraint fk join pg_class t on t.oid=fk.conrelid
        join pg_namespace ns on ns.oid=t.relnamespace join pg_attribute a on a.attrelid=t.oid and a.attnum=any(fk.conkey)
        where fk.contype='f' and ns.nspname='public' and t.relname=c.table_name and a.attname=c.column_name
          and fk.confrelid='public.users'::regclass and fk.confdeltype='c')`;
    if(missing.length)throw new Error('restored ownership constraints are incomplete');
    const [before]=await sql`select count(*)::int as count from users`;
    await sql.begin(async tx=>{
      // Old dumps can predate additive migration0015. This is the owned scratch restore only;
      // production schema changes remain the release migrator's responsibility.
      await tx`alter table account_deletions add column if not exists apple_revocation text not null default 'manual_required'`;
      await tx`create temporary table ops_erased_identities(identity_hash text primary key) on commit drop`;
      if(ledger.payload.records.length)await tx`insert into ops_erased_identities ${tx(ledger.payload.records.map(r=>({identity_hash:r.identityHash})),'identity_hash')}`;
      // Existing users supply any pending raw ID absent from a conservative marker.
      const ids=await tx`select u.clerk_id,encode(sha256(convert_to(u.clerk_id,'UTF8')),'hex') as identity_hash
        from users u join ops_erased_identities d on d.identity_hash=encode(sha256(convert_to(u.clerk_id,'UTF8')),'hex')`;
      const raw=new Map(ids.map(r=>[r.identity_hash,r.clerk_id]));
      for(const row of ledger.payload.records) {
        await tx`insert into account_deletions(identity_hash,clerk_id,requested_at,completed_at,attempts,next_attempt_at,apple_revocation)
          values(${row.identityHash},${row.completedAt?null:row.clerkId||raw.get(row.identityHash)||null},${row.requestedAt},${row.completedAt},${row.attempts},${row.nextAttemptAt},${row.appleRevocation??'manual_required'})
          on conflict(identity_hash) do update set
            completed_at=coalesce(account_deletions.completed_at,excluded.completed_at),
            clerk_id=case when account_deletions.completed_at is not null or excluded.completed_at is not null then null else coalesce(excluded.clerk_id,account_deletions.clerk_id) end,
            requested_at=least(account_deletions.requested_at,excluded.requested_at),
            attempts=greatest(account_deletions.attempts,excluded.attempts),
            apple_revocation=case when account_deletions.apple_revocation='revoked' or excluded.apple_revocation='revoked' then 'revoked'
              when account_deletions.apple_revocation='not_applicable' or excluded.apple_revocation='not_applicable' then 'not_applicable' else 'manual_required' end`;
      }
      await tx`delete from users where encode(sha256(convert_to(clerk_id,'UTF8')),'hex') in(select identity_hash from ops_erased_identities)`;
    });
    const [after]=await sql`select count(*)::int as count from users`;
    const hashes=ledger.payload.records.map(r=>r.identityHash);
    const remaining=hashes.length?await sql`select count(*)::int as count from users where encode(sha256(convert_to(clerk_id,'UTF8')),'hex') in ${sql(hashes)}`:[{count:0}];
    if(remaining[0].count!==0)throw new Error('deleted identity survived restore sweep');
    const outcomes=await sql`select identity_hash,apple_revocation from account_deletions`;
    const byHash=new Map(outcomes.map(row=>[row.identity_hash,row.apple_revocation]));
    for(const row of ledger.payload.records){
      const stored=byHash.get(row.identityHash);const expected=row.appleRevocation??'manual_required';
      if(!['revoked','manual_required','not_applicable'].includes(stored)
        || expected==='revoked'&&stored!=='revoked'
        || expected==='not_applicable'&&stored==='manual_required')throw new Error('Apple outcome lost during restore');
    }
    const retained=await sql`select count(*)::int as count from account_deletions`;
    return {scratch,usersBefore:before.count,usersAfter:after.count,deletedUsersSwept:before.count-after.count,
      ledgerRecords:ledger.payload.records.length,restoredDeletionRecords:retained[0].count,deletedIdentitiesRemaining:0,sha256:manifest.sha256};
  } finally {
    try { if(sql)await sql.end({timeout:5}); }
    finally { if(owned)await command('dropdb',['--if-exists',scratch],admin); }
  }
}
if(process.argv[1]?.endsWith('/restore-check.mjs')) {
  const path=process.argv[2];
  if(!path){console.error('Usage: node ops/restore-check.mjs /private/path/manifest.json');process.exitCode=1;}
  else restoreCheck(path).then(result=>console.log(JSON.stringify({event:'ops.restore_check_complete',...result})),
    ()=>{console.error(JSON.stringify({event:'ops.restore_check_failed'}));process.exitCode=1;});
}
