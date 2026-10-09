import { readFile, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { randomBytes } from 'node:crypto';
import { config, command, pgEnvironment, hashFile } from '/Users/shan2new/Infra/previously/releases/20261006T123751Z/server/ops/common.mjs';
import { restoreCheck } from '/Users/shan2new/Infra/previously/releases/20261006T123751Z/server/ops/restore-check.mjs';
import { readDeletionLedger } from '/Users/shan2new/Infra/previously/releases/20261006T123751Z/server/ops/ledger.mjs';

const require = createRequire('/Users/shan2new/Infra/previously/releases/20261006T123751Z/server/package.json');
const postgres = require('postgres');
const manifestPath = '/Users/shan2new/Infra/previously/backups/previously-20261006T141015983Z-037be3a7225b.manifest.json';
const statePath = '/Users/shan2new/.config/previously/release/clerk-migration-state.json';
const receiptPath = '/Users/shan2new/Projects/previously/docs/qa/2026-10-06/operations/post-clerk-cutover-backup-restore.json';

async function run() {
  const values = await config();
  const state = JSON.parse(await readFile(statePath, 'utf8'));
  if (!state.appliedAt || state.rows.length !== 4 || state.rows.some(row => !row.productionUserId)) throw new Error('migration incomplete');
  const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
  if (Date.parse(manifest.createdAt) < Date.parse(state.appliedAt)) throw new Error('backup predates cutover');
  const qualifiedRestore = await restoreCheck(manifestPath, { values });
  const ledger = await readDeletionLedger({ directory: '/Users/shan2new/Infra/previously/deletions' });
  // The qualified restore above always replays the ledger. This additional identity
  // comparison is permitted only while the current ledger is empty and service stopped.
  if (ledger.payload.records.length !== 0) throw new Error('additional comparison requires an empty reconciled ledger');
  const dump = join(manifestPath, '..', manifest.file);
  if (await hashFile(dump) !== manifest.sha256) throw new Error('dump checksum changed');
  const scratch = 'previously_identity_restore_' + randomBytes(6).toString('hex');
  const environment = pgEnvironment(values, 'postgres');
  const live = postgres(values.DATABASE_URL, { max: 1 });
  let restored, owned = false, comparison;
  try {
    const deletions = await live`select count(*)::int as count from account_deletions`;
    if (deletions[0].count !== 0) throw new Error('unreconciled deletion exists');
    await command('createdb', [scratch], environment); owned = true;
    await command('pg_restore', ['--exit-on-error', '--no-owner', '--no-privileges', '--dbname', scratch, dump], environment);
    const url = new URL(values.DATABASE_URL); url.pathname = '/' + scratch;
    restored = postgres(url.toString(), { max: 1 });
    for (const row of state.rows) {
      const found = await restored`select count(*)::int as count from users where id=${row.internalUserId} and clerk_id=${row.productionUserId}`;
      if (found[0].count !== 1) throw new Error('restored production mapping mismatch');
    }
    const tables = await live`select distinct table_name from information_schema.columns where table_schema='public' and column_name in ('user_id','actor_user_id','blocked_user_id') order by table_name`;
    const names = ['users', ...tables.map(row => row.table_name)];
    comparison = [];
    for (const name of names) {
      if (!/^[a-z_][a-z0-9_]*$/.test(name)) throw new Error('unexpected table name');
      const summarize = sql => sql`select count(*)::int as count, encode(sha256(convert_to(coalesce(string_agg(to_jsonb(t)::text,E'\n' order by to_jsonb(t)::text),''),'UTF8')),'hex') as sha256 from ${sql(name)} t`;
      const before = (await summarize(live))[0], after = (await summarize(restored))[0];
      if (before.count !== after.count || before.sha256 !== after.sha256) throw new Error('restored owned data differs');
      comparison.push({ table: name, rows: before.count, sha256: before.sha256, exactMatch: true });
    }
    const currentLedger = await readDeletionLedger({ directory: '/Users/shan2new/Infra/previously/deletions' });
    if (currentLedger.payload.records.length !== 0) throw new Error('ledger changed during stopped comparison');
  } finally {
    if (restored) await restored.end({ timeout: 5 });
    await live.end({ timeout: 5 });
    if (owned) await command('dropdb', ['--if-exists', scratch], environment);
  }
  const receipt = { verifiedAt: new Date().toISOString(), realm: 'post-Clerk-cutover', manifest: manifestPath,
    backupCreatedAt: manifest.createdAt, backupBytes: manifest.bytes, backupSHA256: manifest.sha256,
    migrationAppliedAt: state.appliedAt, artifact: '/Users/shan2new/Infra/previously/releases/20261006T123751Z/server',
    qualifiedRestore, productionMappingsRestored: 4, internalUUIDsPreserved: true, exactOwnedTableComparison: comparison,
    bothOwnedScratchDatabasesRemoved: true, restoredOverLiveDatabase: false, ledgerRecords: 0,
    oldDevelopmentRealmBackupsAreNotConsumerRecoveryBaseline: true };
  await writeFile(receiptPath, JSON.stringify(receipt, null, 2) + '\n');
  console.log(JSON.stringify({ passed: true, restoredProductionMappings: 4, ownedTables: comparison.length, scratchRemoved: true, receipt: receiptPath }));
}
run().catch(() => { console.error('Post-cutover restore qualification failed; owned scratch cleanup attempted. No private data logged.'); process.exitCode = 1; });
