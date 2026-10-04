// Read-only whole-catalogue assertion of the production read/composition paths.
import {writeFile} from 'node:fs/promises'
import {sql} from '../db/index.js'
import {getFeedFranchises,getSummaries} from '../services/franchiseView.js'
import {loadResearchHistory} from '../feed/history.js'
import {composePosts,composePostById} from '../feed/compose.js'
import {currentUpcoming,FUTURE_NEWS_STATUSES} from '../services/catalogUpcoming.js'
import {listNotifications} from '../services/notifications.js'
const now=Date.now()
try{
 const rows=await sql`select id,title,upcoming from franchise order by title`
 const retracted=await sql`select id,franchise_id from announcements where status='retracted'`
 const failures:any[]=[],samples:any[]=[],posts:any[]=[]
 let parts=0,returned=0
 for(let offset=0;offset<rows.length;offset+=100){
  const batch=rows.slice(offset,offset+100),ids=batch.map(r=>r.id)
  const [loaded,summaries,history]=await Promise.all([getFeedFranchises(ids,null),getSummaries(ids),loadResearchHistory(ids)])
  const input={franchises:loaded.franchises,observations:history.observations,announcements:history.announcements,memberAddedAt:loaded.memberAddedAt,externalIds:loaded.externalIdById,nowMs:now,episodes:true}
  const composed=composePosts(input)
  posts.push(...composed.map(p=>({id:p.id,franchiseId:p.franchiseId,kind:p.kind,installment:p.installment})))
  for(const f of loaded.franchises){
   returned++;parts+=f.parts.length
   const summary=summaries.find(s=>s.id===f.id)
   if(JSON.stringify(summary?.upcoming)!==JSON.stringify(f.upcoming))failures.push({id:f.id,title:f.title,reason:'summary/detail disagree'})
   if(f.upcoming&&FUTURE_NEWS_STATUSES.has(f.upcoming.status)&&!currentUpcoming(f.upcoming,f.parts,now))failures.push({id:f.id,title:f.title,reason:'expired or already out upcoming'})
   for(const r of retracted.filter(r=>r.franchise_id===f.id))if(composePostById(input,`news:${r.id}`)||composed.some(p=>p.id===`news:${r.id}`))failures.push({id:f.id,title:f.title,reason:'retracted post resurfaced'})
   if(['The Boys','The Big Bang Theory','Game of Thrones','ted','The Traitors','The Witcher','Mushoku Tensei','Kaiju No. 8','Hunter x Hunter (2011)'].includes(f.title))samples.push({id:f.id,title:f.title,isReleasing:f.isReleasing,upcoming:f.upcoming,parts:f.parts.map(p=>({label:p.label,status:p.status,aired:p.airedEpisodes,total:p.totalEpisodes}))})
  }
 }
 const recipients=await sql`select distinct n.user_id from notifications n join announcements a on a.id=n.announcement_id where a.status='retracted'`
 const suppressedIds=new Set(retracted.map(r=>`news:${r.id}`))
 for(const userId of recipients.length?recipients.map(r=>r.user_id):['00000000-0000-4000-8000-000000000000']){
  const page=await listNotifications(userId,{limit:100,cursor:null,includeSocial:false})
  if(page.items.some(n=>n.postId&&suppressedIds.has(n.postId)))failures.push({reason:'retracted announcement resurfaced in notifications'})
 }
 const result={checked:new Date(now).toISOString(),franchises:returned,parts,retracted:retracted.length,posts:posts.length,notificationRecipientsChecked:recipients.length,failures,samples}
 await writeFile('../docs/audits/2026-10-04/data-integrity/verification.json',JSON.stringify(result,null,2))
 console.log(JSON.stringify({...result,samples:undefined}));if(failures.length)process.exitCode=1
}finally{await sql.end()}
