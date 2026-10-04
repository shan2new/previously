import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { codexEnvironment, runCodexResearch } from './codex.js'

let fixture: string
let command: string
beforeEach(async () => {
  fixture = await mkdtemp(join(tmpdir(), 'previously-codex-test-'))
  command = join(fixture, 'codex')
  // A real child process exercises framing, stdin, exit, timeout and temporary-file cleanup.
  await writeFile(command, `#!${process.execPath}
const fs = require('node:fs');
const args = process.argv.slice(2);
const output = args[args.indexOf('--output-last-message') + 1];
const receipt = ${JSON.stringify(join(fixture, 'receipt.json'))};
fs.writeFileSync(receipt, JSON.stringify({ args, cwd: process.cwd(), env: process.env }));
let prompt = '';
process.stdin.on('data', c => prompt += c);
process.stdin.on('end', () => {
  const mode = prompt.split('\\n').at(-1);
  const emit = event => process.stdout.write(JSON.stringify(event) + '\\n');
  if (mode === 'timeout') { process.on('SIGTERM', () => {}); setInterval(() => {}, 100); return; }
  if (mode === 'quota') { emit({ type: 'turn.failed', error: { message: '429 usage limit' } }); return; }
  if (mode === 'auth') { emit({ type: 'turn.failed', error: { message: '401 not logged in' } }); return; }
  if (mode === 'broken-jsonl') { process.stdout.write('broken\\n'); return; }
  if (mode === 'overflow') { process.stdout.write('a'.repeat(3 * 1024 * 1024)); return; }
  if (mode === 'unsafe') emit({ type: 'item.started', item: { type: 'command_execution' } });
  if (mode !== 'no-search') emit({ type: 'item.completed', item: { type: 'web_search' } });
  if (mode !== 'incomplete') emit({ type: 'turn.completed' });
  fs.writeFileSync(output, mode === 'bad-result' ? '{' : JSON.stringify({ status: 'concluded' }));
});
`, { mode: 0o700 })
})
afterEach(async () => { vi.unstubAllEnvs(); vi.restoreAllMocks(); await rm(fixture, { recursive: true, force: true }) })
const run = (mode: string, timeoutMs = 3_000) => runCodexResearch(mode, { type: 'object' }, { command, timeoutMs })

describe('isolated Codex CLI research', () => {
  it('accepts completed web research, isolates credentials and removes its scratch files', async () => {
    vi.stubEnv('OPENAI_API_KEY', 'must-not-inherit')
    vi.stubEnv('DATABASE_URL', 'must-not-inherit')
    vi.stubEnv('CODEX_THREAD_ID', 'must-not-inherit')
    expect(await run('success')).toEqual({ status: 'concluded' })
    const receipt = JSON.parse(await readFile(join(fixture, 'receipt.json'), 'utf8'))
    expect(receipt.args).toEqual(expect.arrayContaining(['--ephemeral', '--ignore-user-config', 'read-only', 'web_search="live"', 'features.shell_tool=false', 'mcp_servers={}']))
    expect(receipt.args).not.toContain('--model')
    expect(receipt.env.OPENAI_API_KEY).toBeUndefined()
    expect(receipt.env.DATABASE_URL).toBeUndefined()
    expect(receipt.env.CODEX_THREAD_ID).toBeUndefined()
    await expect(readFile(join(receipt.cwd, 'result.json'))).rejects.toMatchObject({ code: 'ENOENT' })
  })
  it.each(['no-search', 'incomplete', 'unsafe', 'broken-jsonl', 'overflow'])(
    'rejects untrustworthy execution: %s', async mode => { await expect(run(mode)).rejects.toThrow(/protocol/) },
  )
  it('rejects malformed final JSON', async () => { await expect(run('bad-result')).rejects.toThrow() })
  it('classifies a quota failure', async () => { await expect(run('quota')).rejects.toThrow(/quota/) })
  it.each(['quota', 'auth'])('backs off after Codex %s failure instead of retrying every title', async mode => {
    vi.resetModules()
    vi.stubEnv('NEWS_CODEX_COMMAND', command)
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const { researchWithCodex } = await import('./codex.js')
    expect(await researchWithCodex(mode, {})).toBeNull()
    // If a second process were launched it would succeed; the cooldown must skip it.
    expect(await researchWithCodex('success', {})).toBeNull()
    expect(warn).toHaveBeenCalledOnce()
  })
  it('kills an unresponsive subprocess and cleans up on timeout', async () => {
    await expect(run('timeout', 1_500)).rejects.toThrow(/timeout/)
    const receipt = JSON.parse(await readFile(join(fixture, 'receipt.json'), 'utf8'))
    await expect(readFile(join(receipt.cwd, 'schema.json'))).rejects.toMatchObject({ code: 'ENOENT' })
  })
  it('rejects an unavailable CLI without hanging', async () => {
    await expect(runCodexResearch('', {}, { command: join(fixture, 'missing'), timeoutMs: 500 })).rejects.toThrow(/execution/)
  })
  it('supplies the launchd-missing CLI directory without inheriting app secrets', () => {
    const env = codexEnvironment({ HOME: '/home/researcher', PATH: '/usr/bin:/bin', ANTHROPIC_API_KEY: 'secret', CODEX_HOME: '/other-session' })
    expect(env).toEqual({ HOME: '/home/researcher', PATH: '/usr/bin:/bin:/home/researcher/.local/bin' })
  })
})
