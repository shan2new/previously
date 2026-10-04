import {writeFile} from 'node:fs/promises'
import {sql} from '../db/index.js'
try{
 const id='da83cb93-042e-48d8-95ad-e4a463752caf'
 const [f]=await sql`select id,title,upcoming from franchise where id=${id}`
 if(!f?.upcoming)throw new Error('Missing fact')
 const source='https://futsutsuka.net/en/'
 const evidence={url:source,tier:'reputable',primary:true,publisher:'Official Though I Am an Inept Villainess website',publishedAt:null}
 const upcoming={...f.upcoming,source,evidence:[evidence],note:'The official anime website confirms the second cour, The First Royal Outing, premieres in January 2027. No exact day is given.',checked:new Date().toISOString()}
 await writeFile('../docs/audits/2026-10-04/data-integrity/source-repair.json',JSON.stringify({before:f,after:upcoming,reason:'Stored Crunchyroll URL returned generic news index; replace with verified official production site.'},null,2))
 await sql.begin(async tx=>{
  await tx`update franchise set upcoming=${JSON.stringify(upcoming)} where id=${id}`
  const rows=await tx`update announcements set source=${source},note=${upcoming.note},last_seen_at=now() where franchise_id=${id} and next=${upcoming.next} and status<>'retracted' returning id`
  const [ob]=await tx`insert into announcement_observations(franchise_id,announcement_id,dedupe_key,status,next,release,note) values(${id},${rows[0]?.id??null},'season 2',${upcoming.status},${upcoming.next},${upcoming.release},${upcoming.note}) returning id`
  await tx`insert into announcement_evidence(observation_id,url,publisher,tier,"primary") values(${ob!.id},${source},${evidence.publisher},${evidence.tier},true)`
 })
 console.log('Updated confirmed January 2027 claim to the official production source')
}finally{await sql.end()}
