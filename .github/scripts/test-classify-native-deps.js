import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { classify } from './classify-native-deps.js';

const repo = fs.mkdtempSync(path.join(os.tmpdir(), 'sendmeter-native-deps-'));
const run = (args) => execFileSync('git', args, { cwd: repo, encoding: 'utf8' }).trim();
const write = (file, value) => {
  const target = path.join(repo, file);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, value);
};
run(['init', '-q']);
run(['config', 'user.email', 'test@example.com']);
run(['config', 'user.name', 'test']);
write('package.json', JSON.stringify({ devDependencies: { '@capacitor/cli': '^8.0.0', bridge: 'registry:bridge', typescript: '^6.0.0' } }, null, 2) + '\n');
write('package-lock.json', JSON.stringify({ packages: { '': {}, 'node_modules/@capacitor-community/safe-area': { version: '1.0.0', integrity: 'old' }, 'node_modules/wrapper': { resolved: 'https://registry.test/wrapper.tgz' } } }, null, 2) + '\n');
write('.github/workflows/ios-ci.yml', 'name: iOS CI\n');
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

const editPackage = (edit) => {
  const pkg = JSON.parse(fs.readFileSync(path.join(repo, 'package.json'), 'utf8'));
  edit(pkg.devDependencies);
  write('package.json', JSON.stringify(pkg, null, 2) + '\n');
};

assert.equal(scenario('unrelated', () => editPackage((deps) => { deps.typescript = '^7.0.0'; })), false);
assert.equal(scenario('native', () => editPackage((deps) => { deps['@capacitor/cli'] = '^8.1.0'; })), true);
assert.equal(scenario('safe-area', () => editPackage((deps) => { deps['@capacitor-community/safe-area'] = '^1.1.0'; })), true);
assert.equal(scenario('alias', () => editPackage((deps) => { deps.bridge = 'npm:@capacitor/core@8.0.0'; })), true);
assert.equal(scenario('url', () => editPackage((deps) => { deps.bridge = 'github:ionic-team/capacitor#v8.0.0'; })), true);
assert.equal(scenario('capacitor-community-url', () => editPackage((deps) => { deps.bridge = 'github:capacitor-community/http#v1.4.1'; })), true);
assert.equal(scenario('non-native-url', () => editPackage((deps) => { deps.bridge = 'github:someorg/some-lib#v2.0.0'; })), false);
assert.equal(scenario('lockfile-wrapper-resolved', () => {
  const lock = JSON.parse(fs.readFileSync(path.join(repo, 'package-lock.json'), 'utf8'));
  lock.packages['node_modules/wrapper'].resolved = 'github:ionic-team/capacitor#v8.1.0';
  write('package-lock.json', JSON.stringify(lock, null, 2) + '\n');
}), true);
assert.equal(scenario('workflow-path', () => write('.github/workflows/ios-ci.yml', 'name: changed\n')), true);
assert.equal(scenario('patch-path', () => write('patches/@capacitor-community+apple-sign-in+7.1.0.patch', 'native patch changed\n')), true);
console.log('classifier tests: 10 passed (unrelated, native, safe-area, alias, URL, capacitor-community URL, non-native URL, lockfile-only, workflow path, patch path)');
fs.rmSync(repo, { recursive: true, force: true });
