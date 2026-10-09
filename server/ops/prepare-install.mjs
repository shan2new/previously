import { lstat, mkdir, readFile, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { atomicJSON, privateDirectory, sha256 } from './common.mjs';
const xml=(value)=>String(value).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;');
const item=(key,value)=>`<key>${xml(key)}</key>`+(Array.isArray(value)?'<array>'+value.map(v=>'<string>'+xml(v)+'</string>').join('')+'</array>':typeof value==='boolean'?value?'<true/>':'<false/>':typeof value==='number'?'<integer>'+value+'</integer>':typeof value==='object'?'<dict>'+Object.entries(value).map(([k,v])=>item(k,v)).join('')+'</dict>':'<string>'+xml(value)+'</string>');
export async function prepareInstall({serverDirectory,envFile,operationsDirectory,outputDirectory,nodeBinary='/opt/homebrew/opt/node@24/bin/node',previousPlist=join(homedir(),'Library/LaunchAgents/com.shan.previously.plist')}={}) {
  for(const value of [serverDirectory,envFile,operationsDirectory,outputDirectory,nodeBinary])if(!value||!value.startsWith('/'))throw new Error('absolute install paths are required');
  serverDirectory=resolve(serverDirectory);envFile=resolve(envFile);operationsDirectory=resolve(operationsDirectory);outputDirectory=resolve(outputDirectory);
  if(outputDirectory===operationsDirectory||outputDirectory.startsWith(join(homedir(),'Library/LaunchAgents')))throw new Error('candidate output must be separate from installed jobs');
  const envInfo=await lstat(envFile);if(!envInfo.isFile()||envInfo.isSymbolicLink()||(envInfo.mode&0o077)!==0)throw new Error('private environment file required');
  const compiled=await lstat(join(serverDirectory,'dist/index.js'));if(!compiled.isFile()||compiled.isSymbolicLink())throw new Error('compiled backend entry is missing');
  for(const file of ['run-server.mjs','backup.mjs','collect.mjs','initialize-ledger.mjs','restore-check.mjs']){const info=await lstat(join(serverDirectory,'ops',file));if(!info.isFile()||info.isSymbolicLink())throw new Error('artifact ops script is missing');}
  await privateDirectory(outputDirectory);
  const environment={PATH:'/opt/homebrew/bin:/usr/bin:/bin',PREVIOUSLY_ENV_FILE:envFile,PREVIOUSLY_OPS_ROOT:operationsDirectory,NODE_ENV:'production',APP_ENV:'production'};
  const base={WorkingDirectory:serverDirectory,EnvironmentVariables:environment,StandardOutPath:'/dev/null',StandardErrorPath:'/dev/null',ProcessType:'Background',ThrottleInterval:10};
  const jobs=[
    {...base,Label:'com.shan.previously',ProgramArguments:[nodeBinary,join(serverDirectory,'ops/run-server.mjs')],RunAtLoad:true,KeepAlive:true,ExitTimeOut:40},
    {...base,Label:'com.shan.previously.backup',ProgramArguments:[nodeBinary,join(serverDirectory,'ops/backup.mjs')],StartCalendarInterval:{Hour:3,Minute:15},ExitTimeOut:360},
    {...base,Label:'com.shan.previously.ops',ProgramArguments:[nodeBinary,join(serverDirectory,'ops/collect.mjs')],RunAtLoad:true,StartInterval:3600,ExitTimeOut:45},
  ];
  const hashes={};for(const job of jobs){const name=job.Label+'.plist';const content='<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>'+Object.entries(job).map(([key,value])=>item(key,value)).join('')+'</dict></plist>\n';await writeFile(join(outputDirectory,name),content,{mode:0o600,flag:'wx'});hashes[name]=sha256(content);}
  try{const oldInfo=await lstat(previousPlist);if(!oldInfo.isFile()||oldInfo.isSymbolicLink())throw new Error('unsafe rollback plist');const old=await readFile(previousPlist);const rollback=join(outputDirectory,'rollback');await privateDirectory(rollback);await writeFile(join(rollback,'com.shan.previously.plist'),old,{mode:0o600,flag:'wx'});hashes['rollback/com.shan.previously.plist']=sha256(old);}catch(error){if(error.code!=='ENOENT')throw error;}
  await atomicJSON(join(outputDirectory,'candidate-manifest.json'),{version:1,preparedAt:new Date().toISOString(),serverDirectory,envFile,operationsDirectory,nodeBinary,files:hashes,installed:false});
  return {directory:outputDirectory,jobs:jobs.map(job=>job.Label),installed:false};
}
if(process.argv[1]?.endsWith('/prepare-install.mjs')) {
  const [serverDirectory,envFile,operationsDirectory,outputDirectory]=process.argv.slice(2);
  prepareInstall({serverDirectory,envFile,operationsDirectory,outputDirectory}).then(result=>console.log(JSON.stringify({event:'ops.install_candidate_prepared',...result})),()=>{console.error(JSON.stringify({event:'ops.install_candidate_failed'}));process.exitCode=1;});
}
