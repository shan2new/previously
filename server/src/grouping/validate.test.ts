import {describe,expect,it} from 'vitest'
import {validateGrouping} from './validate.js'
import type {GroupingInput,GroupingResult} from './llm.js'
const input:GroupingInput={candidates:[1,2].map(id=>({id,title:`Title ${id}`,format:'TV',status:'FINISHED',seasonYear:2026,episodes:12,synopsis:''})),edges:[]}
function result():GroupingResult{return {model:null,confidence:1,franchises:[{canonicalName:'Show',parts:[1,2].map(id=>({id,partKind:'season',sequence:id,label:`Season ${id}`}))}]}}
describe('grouping identity validation',()=>{
 it('accepts a complete non-overlapping partition',()=>expect(()=>validateGrouping(result(),input)).not.toThrow())
 it.each(['duplicate','unknown','missing','sequence','label'] as const)('rejects %s identities before persistence',problem=>{
  const r=result(),parts=r.franchises[0]!.parts
  if(problem==='duplicate')parts[1]!.id=1
  if(problem==='unknown')parts[1]!.id=999
  if(problem==='missing')parts.pop()
  if(problem==='sequence')parts[1]!.sequence=1
  if(problem==='label')parts[1]!.label='Season 1'
  expect(()=>validateGrouping(r,input)).toThrow()
 })
})
