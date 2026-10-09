import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { prepareInstall } from './prepare-install.mjs';
import { command, serverRoot } from './common.mjs';
test('candidate plists are valid, LTS pinned, reversible and remain uninstalled',async()=>{
  const directory=await mkdtemp(join(tmpdir(),'previously-install-'));const envFile=join(directory,'production.env');const old=join(directory,'old.plist');
  try {
    await writeFile(envFile,'TEST_ONLY=private-not-a-real-secret\n',{mode:0o600});await writeFile(old,'old immutable rollback candidate');
    const artifact=join(directory,'immutable-server');await mkdir(join(artifact,'ops'),{recursive:true});await mkdir(join(artifact,'dist'));
    for(const name of ['run-server.mjs','backup.mjs','collect.mjs','initialize-ledger.mjs','restore-check.mjs'])await writeFile(join(artifact,'ops',name),await readFile(join(serverRoot,'ops',name)));
    const output=join(directory,'candidate');
    const options={serverDirectory:artifact,envFile,operationsDirectory:join(directory,'ops-data'),outputDirectory:output,previousPlist:old};
    await assert.rejects(prepareInstall(options));
    await writeFile(join(artifact,'dist/index.js'),'// compiled fixture entry\n');
    const result=await prepareInstall(options);
    assert.equal(result.installed,false);assert.equal(result.jobs.length,3);
    for(const label of result.jobs){const file=join(output,label+'.plist');await command('plutil',['-lint',file],process.env);const content=await readFile(file,'utf8');assert.ok(content.includes('/opt/homebrew/opt/node@24/bin/node'));assert.ok(content.includes('/dev/null'));assert.ok(!content.includes('private-not-a-real-secret'));assert.equal((await stat(file)).mode&0o777,0o600);}
    assert.equal(await readFile(join(output,'rollback/com.shan.previously.plist'),'utf8'),'old immutable rollback candidate');
    assert.equal((await stat(output)).mode&0o777,0o700);
  }finally{await rm(directory,{recursive:true});}
});
