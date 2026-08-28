/* global process */

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';

const NATIVE_REFERENCE = /(?:@capacitor(?:\/|-)|sendlog-|(?:^|[/:-])capacitor(?:[/#@-]|$)|healthkit|bluetooth)/i;

function git(args, cwd) {
  return execFileSync('git', args, { cwd, encoding: 'utf8' });
}

function packageIsNative(name, value) {
  const serialized = typeof value === 'string' ? value : JSON.stringify(value ?? '');
  return NATIVE_REFERENCE.test(name) || NATIVE_REFERENCE.test(serialized);
}

function readPackageLock(ref, cwd) {
  return JSON.parse(git(['show', `${ref}:package-lock.json`], cwd));
}

export function classify({ base, head, cwd = process.cwd() }) {
  const files = git(['diff', '--name-only', base, head], cwd).trim().split('\n').filter(Boolean);
  if (files.some((file) => file.startsWith('ios/') || file.startsWith('native-plugins/') || file.startsWith('patches/') || file === '.github/workflows/ios-ci.yml')) {
    return { nativeChanged: true, reason: 'native path changed' };
  }

  const beforePackage = JSON.parse(git(['show', `${base}:package.json`], cwd));
  const afterPackage = JSON.parse(fs.readFileSync(`${cwd}/package.json`, 'utf8'));
  const sections = ['dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies'];
  for (const section of sections) {
    const names = new Set([...Object.keys(beforePackage[section] || {}), ...Object.keys(afterPackage[section] || {})]);
    for (const name of names) {
      const before = beforePackage[section]?.[name];
      const after = afterPackage[section]?.[name];
      if (before !== after && (packageIsNative(name, before) || packageIsNative(name, after))) {
        return { nativeChanged: true, reason: `native package or reference changed: ${name}` };
      }
    }
  }

  if (files.includes('package-lock.json')) {
    const beforeLock = readPackageLock(base, cwd).packages || {};
    const afterLock = JSON.parse(fs.readFileSync(`${cwd}/package-lock.json`, 'utf8')).packages || {};
    const keys = new Set([...Object.keys(beforeLock), ...Object.keys(afterLock)]);
    for (const key of keys) {
      const before = beforeLock[key];
      const after = afterLock[key];
      if (JSON.stringify(before) !== JSON.stringify(after) && (packageIsNative(key, before) || packageIsNative(key, after))) {
        return { nativeChanged: true, reason: `native lockfile package changed: ${key}` };
      }
    }
  }
  return { nativeChanged: false, reason: 'dependency change is unrelated to native packages' };
}

if (process.argv[1] && new URL(import.meta.url).pathname === process.argv[1]) {
  const [base, head] = process.argv.slice(2);
  if (!base || !head) throw new Error('usage: classify-native-deps.js BASE_SHA HEAD_SHA');
  const result = classify({ base, head });
  console.log(`native_changed=${result.nativeChanged}`);
  console.log(result.reason);
}
