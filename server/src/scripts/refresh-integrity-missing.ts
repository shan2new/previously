import {readFile,writeFile} from 'node:fs/promises'
import {sql} from '../db/index.js'
import {refreshTvShow} from '../tmdb/service.js'
const base='../docs/audits/2026-10-04/data-integrity'
try {
 const plan=JSON.parse(await readFile(`${base}/repair-plan.json`,'utf8'))
 const shows=[...new Map(plan.missingTvParts.map((p:any)=>[p.franchiseId,p])).values()] as {franchiseId:string;showId:number}[]
 const results=[]
 for(const p of shows){const result=await refreshTvShow(p.franchiseId,p.showId);results.push({...p,...result});console.log(JSON.stringify({...p,...result}))}
 await writeFile(`${base}/missing-parts-result.json`,JSON.stringify(results,null,2))
}finally{await sql.end()}
