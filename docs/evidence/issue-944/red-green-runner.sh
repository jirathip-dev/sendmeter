#!/usr/bin/env bash
# #944 local RED/GREEN + fail-closed legs for the wired stale-command check.
#
# Run from a scratch worktree whose HEAD is the lane's implementation commit:
#   bash red-green-runner.sh <scratch-worktree> <lane-worktree> <lane-head-sha>
#
# The snippet reintroduced in leg 3 is the pre-#945 `.claude/launch.json`
# (recovered from b931401) — a retired root npm command in a current
# entrypoint, exactly the class the check exists to catch.
set -uo pipefail

scratch=${1:?scratch worktree}
lane=${2:?lane worktree}
head=${3:?lane head sha}
pre_945=b931401

cd "$scratch"

leg() { printf '\n===== %s =====\n' "$1"; }

leg "0. scratch worktree state"
git -C "$scratch" rev-parse HEAD
git -C "$scratch" status --short

leg "1. GREEN — check run directly at the unmodified head"
bash scripts/check-docs-stale-commands.sh
echo "EXIT=$?"

leg "2. GREEN — wired recipe (just docs-check)"
just docs-check
echo "EXIT=$?"

leg "3. RED — retire-fix reverted: pre-#945 .claude/launch.json reintroduced"
git show "$pre_945:.claude/launch.json" > .claude/launch.json
git add .claude/launch.json
git -c user.email=lane@example.invalid -c user.name=lane commit -q -m "probe: reintroduce the retired root npm dev command into .claude/launch.json"
git rev-parse HEAD
echo "--- check run directly ---"
bash scripts/check-docs-stale-commands.sh
echo "EXIT=$?"
echo "--- wired recipe ---"
just docs-check
echo "EXIT=$?"

leg "4. GREEN — the exact revert of that revert"
git -c user.email=lane@example.invalid -c user.name=lane revert --no-edit HEAD
git rev-parse HEAD
bash scripts/check-docs-stale-commands.sh
echo "EXIT_DIRECT=$?"
just docs-check
echo "EXIT_RECIPE=$?"
echo "--- scratch tree vs lane head ---"
git diff --stat "$head" HEAD || true
echo "splice_diffs:"
git show --stat HEAD~0 | head -5
echo "restore proof (sha256, scratch vs lane head blob):"
echo "$(shasum -a 256 < .claude/launch.json | cut -d' ' -f1)  scratch"
echo "$(git -C "$lane" show "$head:.claude/launch.json" | shasum -a 256 | cut -d' ' -f1)  lane-head"

leg "5. FAIL-CLOSED — a scanned file is missing"
mv .agent/config.yaml /tmp/impl944-logs/agent-config.yaml.parked
bash scripts/check-docs-stale-commands.sh
echo "EXIT=$?"
mv /tmp/impl944-logs/agent-config.yaml.parked .agent/config.yaml
git status --short

leg "6. FAIL-CLOSED — a scanned file is unreadable"
chmod 000 .agent/config.yaml
bash scripts/check-docs-stale-commands.sh
echo "EXIT=$?"
chmod 644 .agent/config.yaml
echo "$(shasum -a 256 < .agent/config.yaml | cut -d' ' -f1)  scratch"
echo "$(git -C "$lane" show "$head:.agent/config.yaml" | shasum -a 256 | cut -d' ' -f1)  lane-head"

leg "7. POSITIVE VALIDATION — a recipe referenced by a current entrypoint is renamed"
perl -pi -e 's/^fast:/fast-renamed:/' justfile
bash scripts/check-docs-stale-commands.sh
echo "EXIT=$?"
git checkout -- justfile
git status --short

leg "8. final scratch state"
git -C "$scratch" status --short
git -C "$scratch" log --oneline -4
