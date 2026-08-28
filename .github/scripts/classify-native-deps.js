/* global process */

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';

const NATIVE_PACKAGE = /^(?:@capacitor(?:\/|-)|sendlog-)/;
const NATIVE_LOCK = /node_modules\/(?:@capacitor(?:\/|-)|sendlog-)/;

function git(args, cwd) {
  return execFileSync('git', args, { cwd, encoding: 'utf8' });
}

export function classify({ base, head, cwd = process.cwd() }) {
  const files = git(['diff', '--name-only', base, head], cwd).trim().split('\n').filter(Boolean);
  if (files.some((file) => file.startsWith('ios/') || file.startsWith('native-plugins/'))) {
    return { nativeChanged: true, reason: 'native path changed' };
  }
  if (!files.includes('package.json') && !files.includes('package-lock.json')) {
    return { nativeChanged: false, reason: 'no root dependency manifest changed' };
  }

  const before = JSON.parse(git(['show', `${base}:package.json`], cwd));
  const after = JSON.parse(fs.readFileSync(`${cwd}/package.json`, 'utf8'));
  const sections = ['dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies'];
  const changed = [];
  for (const section of sections) {
    const names = new Set([...Object.keys(before[section] || {}), ...Object.keys(after[section] || {})]);
    for (const name of names) {
      if (NATIVE_PACKAGE.test(name) && before[section]?.[name] !== after[section]?.[name]) changed.push(name);
    }
  }

  const lockDiff = git(['diff', '--unified=3', base, head, '--', 'package-lock.json'], cwd);
  let lockPackage = '';
  let lockNative = false;
  for (const line of lockDiff.split('\n')) {
    if (line.startsWith('@@')) {
      lockPackage = '';
      continue;
    }
    const key = line.match(/node_modules\/(?:@capacitor(?:\/|-)|sendlog-)[^" ]*/);
    if (key) lockPackage = key[0];
    if ((line.startsWith('+') || line.startsWith('-')) && NATIVE_LOCK.test(lockPackage)) lockNative = true;
  }
  return {
    nativeChanged: changed.length > 0 || lockNative,
    reason: changed.length ? `native package changed: ${[...new Set(changed)].join(', ')}` : (lockNative ? `native lockfile package changed: ${lockPackage}` : 'root dependency change is unrelated to native packages'),
  };
}

if (process.argv[1] && new URL(import.meta.url).pathname === process.argv[1]) {
  const [base, head] = process.argv.slice(2);
  if (!base || !head) throw new Error('usage: classify-native-deps.js BASE_SHA HEAD_SHA');
  const result = classify({ base, head });
  console.log(`native_changed=${result.nativeChanged}`);
  console.log(result.reason);
}
