// Supplement discovered by validating all composed responses: duplicate installment labels and
// active seasons with a known partial run but no next air date. No notification/progress writes.
import {readFile,writeFile} from 'node:fs/promises'
import {sql} from '../db/index.js'
import {deriveSeasonStatus,includedSeasons} from '../tmdb/mapping.js'
const base='../docs/audits/2026-10-04/data-integrity'
try{
 const audit=JSON.parse(await readFile(`${base}/catalogue-audit.json`,'utf8'))
 const rows=await sql`select id,status,fetched_at from media where source='tmdb'`
 const changes:any[]=[]
 for(const p of audit.provider.filter((p:any)=>!p.error)){
  const show={id:p.externalId,status:p.status,seasons:p.seasons,last_episode_to_air:p.last,next_episode_to_air:p.next} as any
  for(const s of includedSeasons(show)){
   const row=rows.find(r=>r.id===s.id+1_000_000_000)
   if(!row||new Date(row.fetched_at).getTime()>Date.parse(audit.checked))continue
   const status=deriveSeasonStatus(show,s,Date.now())
   if(status!==row.status)changes.push({id:row.id,before:row.status,after:status,title:p.title,fetchedAt:row.fetched_at})
  }
 }
 const labels=[{id:213702,label:'Season 2'},{id:216346,label:'Nippon Sangoku (Zoku-hen)'}]
 const beforeLabels=await sql`select * from franchise_member where media_id in (213702,216346)`
 await writeFile(`${base}/followup-plan.json`,JSON.stringify({changes,beforeLabels,labels},null,2))
 if(process.argv.includes('--apply'))await sql.begin(async tx=>{
  for(const c of changes)await tx`update media set status=${c.after} where id=${c.id} and status=${c.before} and fetched_at=${c.fetchedAt}`
  for(const c of labels)await tx`update franchise_member set label=${c.label} where media_id=${c.id} and label='Season 1'`
 })
 console.log(JSON.stringify({statusChanges:changes,labels,applied:process.argv.includes('--apply')}))
}finally{await sql.end()}
