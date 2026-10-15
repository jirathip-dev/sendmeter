#!/usr/bin/env bash
# #1038 — regenerate design-output/1038/SHA256SUMS over every committed PNG and
# the tools (repo-root-relative paths, sorted). Verify with:
#   shasum -a 256 -c design-output/1038/SHA256SUMS      (from the repo root)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
find design-output/1038/screens design-output/1038/sheets design-output/1038/tools -type f \
  | LC_ALL=C sort | xargs shasum -a 256 > design-output/1038/SHA256SUMS
echo "$(wc -l < design-output/1038/SHA256SUMS | tr -d ' ') files -> design-output/1038/SHA256SUMS"
