import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { sha256, sourceFingerprint } from './common.mjs';
test('compiled JavaScript bytes participate in the actual artifact fingerprint',async()=>{
  const root=await mkdtemp(join(tmpdir(),'previously-artifact-'));
  try {
    for(const directory of ['src','drizzle','ops','dist'])await mkdir(join(root,directory));
    await writeFile(join(root,'package.json'),'{}');await writeFile(join(root,'package-lock.json'),'{}');
    await writeFile(join(root,'dist/index.js'),'compiled first');const before=await sourceFingerprint(root);
    assert.equal(before.files['dist/index.js'],sha256('compiled first'));
    await writeFile(join(root,'dist/index.js'),'compiled changed');const after=await sourceFingerprint(root);
    assert.equal(after.files['dist/index.js'],sha256('compiled changed'));assert.notEqual(after.sha256,before.sha256);
  }finally{await rm(root,{recursive:true});}
});
