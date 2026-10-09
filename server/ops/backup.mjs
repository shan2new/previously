import { chmod, lstat, open, readFile, readdir, rename, rm, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { atomicJSON, command, config, hashFile, nonce, opsRoot, pgEnvironment, privateDirectory, pruneOwned, sourceFingerprint, stamp } from './common.mjs';
import { readDeletionLedger } from './ledger.mjs';

export async function backupDatabase({ values, directory = join(opsRoot(), 'backups'), ledgerDirectory = join(opsRoot(), 'deletions') } = {}) {
  values ||= await config(); await privateDirectory(directory);
  const ledger = await readDeletionLedger({ directory: ledgerDirectory });
  const name = 'previously-' + stamp() + '-' + nonce();
  const pending = join(directory, name + '.pending'); const final = join(directory, name + '.dump');
  try {
    // Set privacy before pg_dump writes any account data, independently of the parent's umask.
    const empty=await open(pending,'wx',0o600);await empty.close();
    await command('pg_dump', ['--format=custom', '--file', pending], pgEnvironment(values), { timeoutMs: 300_000 });
    await chmod(pending, 0o600);
    const durable=await open(pending,'r');try{await durable.sync();}finally{await durable.close();}
    const info = await stat(pending); if (!info.size) throw new Error('empty database backup');
    const toc = await command('pg_restore', ['--list', pending], pgEnvironment(values));
    const tocEntries = toc.split('\n').filter(line => /^\d+;/.test(line)).length;
    if (!tocEntries) throw new Error('backup has no restore entries');
    const source = await sourceFingerprint();
    const manifest = { version: 1, createdAt: new Date().toISOString(), file: name + '.dump', bytes: info.size,
      sha256: await hashFile(pending), tocEntries, sourceFingerprint: source.sha256,
      deletionLedgerSHA256: ledger.sha256, deletionRecords: ledger.payload.records.length };
    const metadata = join(directory, name + '.manifest.json');
    await atomicJSON(metadata, manifest);
    await rename(pending, final);
    const durableDir=await open(directory,'r');try{await durableDir.sync();}finally{await durableDir.close();}
    await pruneBackups(directory);
    return manifest;
  } catch (error) { await rm(pending,{force:true}); throw error; }
}
export async function pruneBackups(directory=join(opsRoot(),'backups')) {
    await privateDirectory(directory);
    // Age pruning also catches an abandoned partial dump or orphaned pair after a crash.
    await pruneOwned(directory,/^previously-\d{8}T\d{9}Z-[a-f0-9]{12}\.(dump|pending|manifest\.json)$/,7);
    const completed = [];
    for (const entry of await readdir(directory)) {
      if (!/^previously-\d{8}T\d{9}Z-[a-f0-9]{12}\.manifest\.json$/.test(entry)) continue;
      const path = join(directory,entry); const info = await lstat(path);
      if (!info.isFile() || info.isSymbolicLink()) throw new Error('unsafe backup manifest');
      const data = JSON.parse(await readFile(path,'utf8'));
      if (!/^previously-\d{8}T\d{9}Z-[a-f0-9]{12}\.dump$/.test(data.file)) throw new Error('invalid backup manifest');
      const dump = join(directory,data.file); const dumpInfo = await lstat(dump).catch(()=>null);
      if (!dumpInfo) continue;
      if (!dumpInfo.isFile() || dumpInfo.isSymbolicLink()) throw new Error('unsafe backup dump');
      completed.push({ path, dump, createdAt: Date.parse(data.createdAt) });
    }
    completed.sort((a,b)=>b.createdAt-a.createdAt);
    for (let index=0;index<completed.length;index++) if(index>=7 || completed[index].createdAt<Date.now()-7*86_400_000) {
      await rm(completed[index].dump); await rm(completed[index].path);
    }
}
if (process.argv[1]?.endsWith('/backup.mjs')) {
  backupDatabase().then(result=>console.log(JSON.stringify({event:'ops.backup_complete',bytes:result.bytes,tocEntries:result.tocEntries,sha256:result.sha256})),
    ()=>{ console.error(JSON.stringify({event:'ops.backup_failed'}));process.exitCode=1; });
}
