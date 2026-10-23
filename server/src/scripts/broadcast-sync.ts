import { sql } from '../db/index.js'
import { syncBroadcastTimes } from '../tvmaze/service.js'

// `npm run broadcast` syncs every followed TV show's TVmaze broadcast times now (the cron runs it
// every six hours); `npm run broadcast -- <franchiseId> …` syncs only those shows. It WRITES
// (catalog_links, media_broadcast_times): run it against production only with the owner's go-ahead.

const franchiseIds = process.argv.slice(2).filter(Boolean)
const result = await syncBroadcastTimes(franchiseIds.length ? { franchiseIds } : {})
console.log(JSON.stringify(result))
await sql.end()
