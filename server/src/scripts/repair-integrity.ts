// 2026-10-04 evidence-backed repair. Dry run by default; --apply writes atomically, no notifications.
import { readFile, writeFile, mkdir } from 'node:fs/promises'
import { sql } from '../db/index.js'
import { isDeepStrictEqual } from 'node:util'
import { tmdbSeasonToMediaRow, includedSeasons } from '../tmdb/mapping.js'
import { currentUpcoming, deriveCatalogUpcoming, isCatalogueUpcoming } from '../services/catalogUpcoming.js'
import { dedupeKey } from '../news/installment.js'
import type { TmdbShow } from '../tmdb/types.js'
const base='../docs/audits/2026-10-04/data-integrity'
const apply=process.argv.includes('--apply')
const tv=JSON.parse(await readFile(`${base}/catalogue-audit.json`,'utf8'))
const anime=JSON.parse(await readFile('/tmp/previously-anime-integrity.json','utf8'))
const fixes=JSON.parse(await readFile(`${base}/editorial-corrections.json`,'utf8'))
const now=Date.now(),checked=new Date(now).toISOString()
try {
  const franchises=await sql`select id,title,source,external_id,upcoming from franchise order by title`
  const media=await sql`select id,source,status,episodes,episodes_list,next_airing_episode,last_aired_at,fetched_at,title_english,title_romaji from media`
  const members=await sql`select franchise_id,media_id,label,sequence,part_kind from franchise_member`
  const beforeAnnouncements=await sql`select * from announcements`
  const byMedia=new Map(media.map(m=>[m.id,m]))
  const mediaChanges:any[]=[],missingTvParts:any[]=[]
  for(const p of tv.provider.filter((p:any)=>!p.error)) {
    const show={id:p.externalId,name:p.title,status:p.status,seasons:p.seasons,last_episode_to_air:p.last,next_episode_to_air:p.next} as TmdbShow
    for(const s of includedSeasons(show)) {
      const old=byMedia.get(1_000_000_000+s.id)
      if(!old){missingTvParts.push({franchiseId:p.id,showId:p.externalId,season:s.season_number});continue}
      if(new Date(old.fetched_at).getTime()>Date.parse(tv.checked))continue
      const row=tmdbSeasonToMediaRow(show,s,now,old.episodes_list??[])
      const patch={status:row.status,episodes:row.episodes,next_airing_episode:row.nextAiringEpisode??null,last_aired_at:row.lastAiredAt??null}
      if(Object.entries(patch).some(([k,v])=>!isDeepStrictEqual(k==='last_aired_at'&&old[k]!=null?Number(old[k]):old[k],v))) {
        mediaChanges.push({id:old.id,source:'tmdb',patch,expectedFetchedAt:old.fetched_at});Object.assign(old,patch)
      }
    }
  }
  for(const row of anime.fresh) {
    const old=byMedia.get(row.id)
    if(!old||new Date(old.fetched_at).getTime()>new Date(row.fetchedAt).getTime())continue
    const patch={status:row.status,episodes:row.episodes,episodes_list:row.episodesList,next_airing_episode:row.nextAiringEpisode??null}
    if(Object.entries(patch).some(([k,v])=>!isDeepStrictEqual(k==='last_aired_at'&&old[k]!=null?Number(old[k]):old[k],v))) {
      mediaChanges.push({id:old.id,source:'anilist',patch,expectedFetchedAt:old.fetched_at});Object.assign(old,patch)
    }
  }
  const franchiseChanges:any[]=[]
  for(const f of franchises) {
    const parts=members.filter(m=>m.franchise_id===f.id).map(m=>{
      const row=byMedia.get(m.media_id)!
      return {mediaId:row.id,kind:m.part_kind,sequence:m.sequence,label:m.label,title:row.title_english??row.title_romaji??'',status:row.status,nextAiringAt:row.next_airing_episode?.airingAt?row.next_airing_episode.airingAt*1000:null,fetchedAt:row.fetched_at?new Date(row.fetched_at):null}
    })
    const catalog=deriveCatalogUpcoming({source:f.source,franchiseExternalId:f.external_id,parts,nowMs:now})
    const fix=fixes.find((x:any)=>x.id===f.id)
    const old=f.upcoming
    let next=old,reason=''
    if(fix){next=fix.patch?{...old,...fix.patch,checked}:catalog;reason=fix.reason}
    else if(old&&isCatalogueUpcoming(old)){next=catalog;reason='Recompute from actual future parts, never a guessed next season.'}
    else if(old&&!currentUpcoming(old,parts,now)){next=catalog;reason='Retire elapsed or already-aired research claim.'}
    const comparable=(u:any)=>u?{...u,checked:null}:null
    if(JSON.stringify(comparable(old))!==JSON.stringify(comparable(next))||fix?.retract)franchiseChanges.push({id:f.id,title:f.title,before:old,after:next,reason,retract:fix?.retract??false,editorial:!!fix})
  }
  const summary={media:mediaChanges.length,tv:mediaChanges.filter(x=>x.source==='tmdb').length,anime:mediaChanges.filter(x=>x.source==='anilist').length,franchises:franchiseChanges.length,editorial:fixes.length,missingTvParts:missingTvParts.length}
  await writeFile(`${base}/repair-plan.json`,JSON.stringify({checked,apply,mediaChanges,missingTvParts,franchiseChanges,summary},null,2))
  if(apply){
    const backupDir=`/tmp/previously-integrity-backup-${now}`
    await mkdir(backupDir)
    await writeFile(`${backupDir}/before.json`,JSON.stringify({franchises,media:await sql`select * from media`,announcements:beforeAnnouncements},null,2))
    const result=await sql.begin(async tx=>{
      let changedMedia=0,changedFranchises=0,retracted=0
      for(const c of mediaChanges){
        const p=c.patch
        const r=c.source==='tmdb'
          ? await tx`update media set status=${p.status},episodes=${p.episodes},next_airing_episode=${p.next_airing_episode===null?null:JSON.stringify(p.next_airing_episode)},last_aired_at=${p.last_aired_at} where id=${c.id} and fetched_at is not distinct from ${c.expectedFetchedAt} returning id`
          : await tx`update media set status=${p.status},episodes=${p.episodes},next_airing_episode=${p.next_airing_episode===null?null:JSON.stringify(p.next_airing_episode)},episodes_list=${JSON.stringify(p.episodes_list)} where id=${c.id} and fetched_at is not distinct from ${c.expectedFetchedAt} returning id`
        if(!r.length)throw new Error(`Concurrent media change ${c.id}; retry audit`)
        changedMedia+=r.length
      }
      for(const c of franchiseChanges){
        const r=await tx`update franchise set upcoming=${c.after===null?null:JSON.stringify(c.after)} where id=${c.id} and upcoming is not distinct from ${c.before===null?null:JSON.stringify(c.before)} returning id`
        if(!r.length)throw new Error(`Concurrent franchise change ${c.title}; retry audit`)
        changedFranchises+=r.length
        if(c.retract)retracted+=(await tx`update announcements set status='retracted',last_seen_at=now() where franchise_id=${c.id} and status<>'retracted' returning id`).length
        const oldA=beforeAnnouncements.find(a=>a.franchise_id===c.id&&a.next===c.before?.next)
        let aid:string|null=null
        if(c.editorial&&!c.retract&&oldA&&c.after){aid=oldA.id;await tx`update announcements set status=${c.after.status},next=${c.after.next},release=${c.after.release},note=${c.after.note},source=${c.after.source},last_seen_at=now() where id=${aid}`}
        if((c.before&&!isCatalogueUpcoming(c.before))||c.retract){
          const state=c.after??{status:'unknown',next:'',release:'TBA',note:c.reason,evidence:[]}
          const [ob]=await tx`insert into announcement_observations(franchise_id,announcement_id,dedupe_key,status,next,release,note) values(${c.id},${aid},${aid?dedupeKey(state.next):'__integrity_correction__'},${state.status},${state.next},${state.release},${state.note??c.reason}) returning id`
          for(const e of state.evidence??[])await tx`insert into announcement_evidence(observation_id,url,publisher,published_at,tier,"primary") values(${ob!.id},${e.url},${e.publisher??null},${e.publishedAt??null},${e.tier},${e.primary}) on conflict do nothing`
        }
      }
      return {changedMedia,changedFranchises,retracted}
    })
    await writeFile(`${base}/repair-result.json`,JSON.stringify({...result,checked,backupDir},null,2));console.log(JSON.stringify({...result,backupDir}))
  }
  console.log(JSON.stringify(summary))
}finally{await sql.end()}
