#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
gate="$repo_root/scripts/check-coverage-threshold.sh"

expect_failure() {
  if bash "$gate" "$@"; then
    echo "coverage threshold self-test expected failure: $1" >&2
    exit 1
  fi
}

expect_success() {
  if ! bash "$gate" "$@"; then
    echo "coverage threshold self-test expected success: $1" >&2
    exit 1
  fi
}

expect_failure "below-line-floor" 94.99 93.01 95 93
expect_failure "below-function-floor" 95.01 92.99 95 93
expect_success "above-both-floors" 95.01 93.01 95 93

echo "coverage threshold self-tests passed: below-floor results fail and above-floor results pass"
