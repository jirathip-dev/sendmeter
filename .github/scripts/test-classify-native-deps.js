import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { classify } from './classify-native-deps.js';

const repo = fs.mkdtempSync(path.join(os.tmpdir(), 'sendmeter-native-deps-'));
const run = (args) => execFileSync('git', args, { cwd: repo, encoding: 'utf8' }).trim();
const write = (file, value) => fs.writeFileSync(path.join(repo, file), value);
run(['init', '-q']);
run(['config', 'user.email', 'test@example.com']);
run(['config', 'user.name', 'test']);
write('package.json', JSON.stringify({ devDependencies: { '@capacitor/cli': '^8.0.0', typescript: '^6.0.0' } }, null, 2) + '\n');
write('package-lock.json', JSON.stringify({ packages: { '': {}, 'node_modules/@capacitor-community/safe-area': { version: '1.0.0', integrity: 'old' } } }, null, 2) + '\n');
run(['add', '.']);
run(['commit', '-qm', 'base']);
const base = run(['rev-parse', 'HEAD']);

function scenario(name, mutate) {
  run(['reset', '--hard', '-q', base]);
  mutate();
  run(['add', '.']);
  run(['commit', '-qm', name]);
  return classify({ base, head: run(['rev-parse', 'HEAD']), cwd: repo }).nativeChanged;
}

assert.equal(scenario('unrelated', () => write('package.json', JSON.stringify({ devDependencies: { '@capacitor/cli': '^8.0.0', typescript: '^7.0.0' } }, null, 2) + '\n')), false);
assert.equal(scenario('native', () => write('package.json', JSON.stringify({ devDependencies: { '@capacitor/cli': '^8.1.0', typescript: '^6.0.0' } }, null, 2) + '\n')), true);
assert.equal(scenario('safe-area', () => write('package.json', JSON.stringify({ devDependencies: { '@capacitor/cli': '^8.0.0', '@capacitor-community/safe-area': '^1.1.0', typescript: '^6.0.0' } }, null, 2) + '\n')), true);
assert.equal(scenario('lockfile-only', () => write('package-lock.json', JSON.stringify({ packages: { '': {}, 'node_modules/@capacitor-community/safe-area': { version: '1.0.1', integrity: 'new' } } }, null, 2) + '\n')), true);
console.log('classifier tests: 4 passed (unrelated, native, safe-area, lockfile-only)');
fs.rmSync(repo, { recursive: true, force: true });
