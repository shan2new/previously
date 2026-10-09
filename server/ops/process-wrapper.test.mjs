import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runServer } from './run-server.mjs';
test('production wrapper applies heap budget, sanitizes both streams and drains SIGTERM',async()=>{
  const directory=await mkdtemp(join(tmpdir(),'previously-wrapper-'));const script=join(directory,'child.mjs');const statePath=join(directory,'state.json');const logs=[];let closed=false;
  try {
    await writeFile(script,`import {writeFileSync} from 'node:fs';
const state={pid:process.pid,nodeOptions:process.env.NODE_OPTIONS,nodeEnv:process.env.NODE_ENV,appEnv:process.env.APP_ENV,drained:false};
console.log(JSON.stringify({event:'request.complete',status:200,email:'private@example.com',token:'sk_live_private'}));
console.error('unstructured private@example.com');
process.on('SIGTERM',()=>{state.drained=true;writeFileSync(process.env.TEST_STATE_FILE,JSON.stringify(state));setTimeout(()=>process.exit(0),20);});
// Publish readiness only after the synthetic child can drain a signal.
writeFileSync(process.env.TEST_STATE_FILE,JSON.stringify(state));
setInterval(()=>{},1000);`);
    const running=runServer({values:{...process.env,TEST_STATE_FILE:statePath,NODE_OPTIONS:'--max-old-space-size=999'},script,writer:{async write(row){logs.push(row);},async maintain(){},async close(){closed=true;}}});
    let state;const deadline=Date.now()+5000;
    while(Date.now()<deadline){try{state=JSON.parse(await readFile(statePath,'utf8'));break;}catch{await new Promise(resolve=>setTimeout(resolve,20));}}
    assert.ok(state,'owned child started');assert.equal(state.nodeOptions,'--max-old-space-size=256 --max-semi-space-size=8');assert.equal(state.nodeEnv,'production');assert.equal(state.appEnv,'production');
    process.emit('SIGTERM');const result=await running;assert.equal(result.code,0);assert.equal(closed,true);
    state=JSON.parse(await readFile(statePath,'utf8'));assert.equal(state.drained,true);assert.throws(()=>process.kill(state.pid,0));
    assert.ok(logs.some(row=>row.event==='request.complete'));assert.ok(logs.some(row=>row.event==='child.unstructured_output_redacted'));assert.ok(!JSON.stringify(logs).includes('private'));
  }finally{await rm(directory,{recursive:true});}
});
