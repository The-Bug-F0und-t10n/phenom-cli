// Verifies the WORKSPACE_NOT_GIT gate so the model stops looping git_* tools
// in directories that aren't git repos.
//
// Reproduces the user's loop: agent kept calling git_status / git_diff /
// git_log in a non-git folder, each returned the raw "fatal: not a git
// repository" message, and the model couldn't tell it was a workspace-wide
// condition — it retried in different shapes. The gate returns a directive
// once and reuses the cached verdict for every subsequent call.

import os from 'os';
import path from 'path';
import { promises as fs } from 'fs';
import type { SimpleGit } from 'simple-git';
import simpleGit from 'simple-git';

import type { Tool } from '../../tools.js';
import { registerGitTools } from '../../tools/registrars/git-tools.js';

let passed = 0;
const tests: { name: string; fn: () => Promise<void> }[] = [];
function test(name: string, fn: () => Promise<void>): void { tests.push({ name, fn }); }
function assert(c: boolean, m: string): void { if (!c) throw new Error(m); }

async function withNonGitCwd(fn: (git: SimpleGit) => Promise<void>): Promise<void> {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'phenom-nogit-'));
  // Reset the module-cached verdict between runs by re-importing fresh state.
  // We can't easily clear the module-level variable from outside, so we run
  // the whole assertion fresh and accept that order matters in this file.
  const prevCwd = process.cwd();
  try {
    process.chdir(tmp);
    const git = simpleGit({ baseDir: tmp });
    await fn(git);
  } finally {
    process.chdir(prevCwd);
    await fs.rm(tmp, { recursive: true, force: true });
  }
}

function collectTools(git: SimpleGit): Map<string, Tool> {
  const out = new Map<string, Tool>();
  registerGitTools({ register: t => { out.set(t.name, t); }, git });
  return out;
}

test('git_status returns WORKSPACE_NOT_GIT directive in non-git dir', async () => {
  await withNonGitCwd(async git => {
    const tools = collectTools(git);
    const st = tools.get('git_status')!;
    const r = await st.execute({});
    assert(r.success === false, 'expected failure');
    assert(/WORKSPACE_NOT_GIT/.test(String(r.error)), `expected directive error, got: ${r.error}`);
    assert(!/^fatal:/.test(String(r.error)), `raw fatal should be replaced; got: ${r.error}`);
  });
});

test('second git_* call in same process short-circuits via cache', async () => {
  await withNonGitCwd(async git => {
    const tools = collectTools(git);
    const status = tools.get('git_status')!;
    const log = tools.get('git_log')!;
    const diff = tools.get('git_diff')!;
    const r1 = await status.execute({});
    const r2 = await log.execute({});
    const r3 = await diff.execute({});
    for (const [name, r] of [['status', r1], ['log', r2], ['diff', r3]] as const) {
      assert(r.success === false, `${name}: expected failure`);
      assert(/WORKSPACE_NOT_GIT/.test(String(r.error)), `${name}: expected directive, got ${r.error}`);
    }
  });
});

(async () => {
  let failures = 0;
  for (const { name, fn } of tests) {
    try { await fn(); passed++; console.log(`  ✅ ${name}`); }
    catch (e: any) { failures++; console.log(`  ❌ ${name}: ${e.message}`); }
  }
  console.log(`\nGit non-repo gate tests: ${passed}/${tests.length} passaram`);
  if (failures > 0) process.exit(1);
})();
