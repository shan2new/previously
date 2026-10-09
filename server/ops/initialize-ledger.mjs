import postgres from 'postgres';
import { join } from 'node:path';
import { config, opsRoot } from './common.mjs';
import { persistDeletionRecords } from './ledger.mjs';
export async function initializeLedger({values,directory=join(opsRoot(),'deletions')}={}) {
  values ||= await config();
  const sql=postgres(values.DATABASE_URL||'postgres://localhost:5432/previously',{max:1,connect_timeout:10});
  try {
    const rows=await sql`select identity_hash as "identityHash",clerk_id as "clerkId",requested_at as "requestedAt",completed_at as "completedAt",attempts,next_attempt_at as "nextAttemptAt",apple_revocation as "appleRevocation" from account_deletions`;
    const result=await persistDeletionRecords(rows,{directory});
    return {records:result.payload.records.length,pending:result.payload.records.filter(row=>!row.completedAt).length,sha256:result.sha256};
  }finally{await sql.end({timeout:5});}
}
if(process.argv[1]?.endsWith('/initialize-ledger.mjs')) {
  initializeLedger().then(result=>console.log(JSON.stringify({event:'ops.ledger_initialized',...result})),
    ()=>{console.error(JSON.stringify({event:'ops.ledger_initialization_failed'}));process.exitCode=1;});
}
