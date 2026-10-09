import { spawn } from 'node:child_process';
import { open, lstat, readdir, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { config, nonce, opsRoot, privateDirectory, serverRoot, stamp } from './common.mjs';

const reasonAllow=new Set(['deleted','failed','skipped','banned','not_found','pending','complete','unavailable','timeout','missing_key','api_error']);
export function sanitizeLog(line) {
  let row;try{row=JSON.parse(line);}catch{return {event:'child.unstructured_output_redacted'};}
  if(!row||typeof row!=='object')return {event:'child.invalid_output_redacted'};
  const safe={event:/^[a-z][a-z0-9._-]{0,80}$/.test(row.event||'')?row.event:'child.output_sanitized'};
  for(const key of ['time','level','status','durationMs','attempts','count'])if(typeof row[key]==='number'&&Number.isFinite(row[key]))safe[key]=row[key];
  if(/^(GET|POST|PUT|DELETE|PATCH|OPTIONS|HEAD) (\/[A-Za-z0-9_/:.-]*|unmatched)$/.test(row.route||''))safe.route=row.route;
  if(/^req-[a-z0-9-]{1,50}$/.test(row.requestId||''))safe.requestId=row.requestId;
  if(reasonAllow.has(row.reason))safe.reason=row.reason;
  if(/^[A-Za-z0-9_-]{1,64}$/.test(row.job||''))safe.job=row.job;
  const code=row.errorCode||row.err?.code;if(/^[A-Z][A-Z0-9_.-]{0,47}$/.test(code||''))safe.errorCode=code;
  return safe;
}
export async function rotatingWriter(directory,{segmentBytes=8*1024*1024,maxSegments=16,maxAgeDays=7}={}) {
  await privateDirectory(directory);let file;let current;let bytes=0;let began=0;let chain=Promise.resolve();
  async function prune() {
    const rows=[];
    for(const name of await readdir(directory)) {
      if(!/^previously-\d{8}T\d{9}Z-[a-f0-9]{12}\.ndjson$/.test(name))continue;
      const path=join(directory,name);const info=await lstat(path);
      if(!info.isFile()||info.isSymbolicLink())throw new Error('unsafe owned log');
      rows.push({path,at:info.mtimeMs});
    }
    rows.sort((a,b)=>b.at-a.at);
    for(let index=0;index<rows.length;index++)if(rows[index].path!==current&&(index>=maxSegments||rows[index].at<Date.now()-maxAgeDays*86_400_000))await rm(rows[index].path);
  }
  async function rotate() {
    if(file){await file.sync();await file.close();}
    current=join(directory,'previously-'+stamp()+'-'+nonce()+'.ndjson');file=await open(current,'wx',0o600);bytes=0;began=Date.now();await prune();
  }
  return {
    write(row){chain=chain.then(async()=>{const line=Buffer.from(JSON.stringify(row)+'\n');if(!file||bytes+line.length>segmentBytes||Date.now()-began>86_400_000)await rotate();await file.write(line);bytes+=line.length;});return chain;},
    maintain(){chain=chain.then(async()=>{if(file&&Date.now()-began>86_400_000)await rotate();await prune();});return chain;},
    close(){chain=chain.then(async()=>{if(file){await file.sync();await file.close();file=null;}await prune();});return chain;},
  };
}
export async function runServer({values,script=join(serverRoot,'dist/index.js'),writer}={}) {
  values ||= await config();writer ||=await rotatingWriter(join(opsRoot(),'logs'));
  const child=spawn(process.execPath,[script],{cwd:serverRoot,detached:true,
    env:{...values,NODE_ENV:'production',APP_ENV:'production',NODE_OPTIONS:'--max-old-space-size=256 --max-semi-space-size=8'},stdio:['ignore','pipe','pipe']});
  let stopping=false;let killTimer;
  const forward=(signal)=>{if(stopping)return;stopping=true;try{process.kill(-child.pid,signal);}catch{}
    killTimer=setTimeout(()=>{try{process.kill(-child.pid,'SIGKILL');}catch{}},35_000);};
  const term=()=>forward('SIGTERM');const interrupt=()=>forward('SIGINT');
  process.on('SIGTERM',term);process.on('SIGINT',interrupt);
  async function consume(stream) {
    let pending='';
    for await(const chunk of stream) {
      pending+=chunk.toString('utf8');
      if(pending.length>64*1024&&!pending.includes('\n')){await writer.write({event:'child.oversized_output_redacted'});pending='';continue;}
      const lines=pending.split('\n');pending=lines.pop();
      for(const line of lines)if(line)await writer.write(line.length>16*1024?{event:'child.oversized_output_redacted'}:sanitizeLog(line));
    }
    if(pending)await writer.write(sanitizeLog(pending.slice(0,16*1024)));
  }
  const maintain=setInterval(()=>{writer.maintain().catch(()=>forward('SIGTERM'));},3_600_000);maintain.unref();
  const outcome=new Promise((resolve)=>{child.once('exit',(code,signal)=>resolve({code,signal}));child.once('error',()=>resolve({code:1,signal:null}));});
  let streamFailure;
  const streams=Promise.all([consume(child.stdout),consume(child.stderr)]).catch(()=>{streamFailure=new Error('operational log capture failed');forward('SIGTERM');});
  console.log(JSON.stringify({event:'ops.server_started',heapLimitMiB:256}));
  try{const result=await outcome;await streams;await writer.close();if(streamFailure)throw streamFailure;return result;}
  finally{clearInterval(maintain);clearTimeout(killTimer);process.off('SIGTERM',term);process.off('SIGINT',interrupt);}
}
if(process.argv[1]?.endsWith('/run-server.mjs')) {
  runServer().then(result=>{console.log(JSON.stringify({event:'ops.server_stopped',code:result.code,signal:result.signal}));process.exitCode=result.code??1;},
    ()=>{console.error(JSON.stringify({event:'ops.server_failed'}));process.exitCode=1;});
}
