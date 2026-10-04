#!/bin/bash
# Host-guarded xcodebuild runner for lane impl-923 (sendmeter).
# Rule (brief): one xcodebuild at a time host-wide, /tmp/sendmeter-xcodebuild.lock,
# stale-guard, release on every exit path. Peer xcodebuilds that ignore the lock are
# waited out first (bounded), then the flock is taken (kernel-released on exit,
# so a crashed holder can never leave a stale lock).
# Usage: run-guarded-xcodebuild.sh <logfile> <command...>
set -u
LOG="$1"; shift
LOCK=/tmp/sendmeter-xcodebuild.lock
: > "$LOG"
exec >>"$LOG" 2>&1
echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ) guarded xcodebuild runner start =="

# 1) Wait out any uncoordinated xcodebuild (bounded: 45 min).
deadline=$(( $(date +%s) + 2700 ))
while pgrep -x xcodebuild >/dev/null 2>&1; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "BLOCKED: a peer xcodebuild is still running after the wait budget"
    exit 3
  fi
  echo "$(date -u +%H:%M:%SZ) peer xcodebuild present (pids: $(pgrep -x xcodebuild | tr '\n' ' ')) - waiting 20s"
  sleep 20
done

# 2) Take the flock (stale-guard: flock is kernel-released; a zero-byte leftover file is harmless).
exec 9>"$LOCK"
if ! flock -w 2700 9; then
  echo "BLOCKED: could not acquire $LOCK within the wait budget"
  exit 3
fi
echo "== $(date -u +%H:%M:%SZ) lock acquired =="
echo "pgrep -x xcodebuild at lock: $(pgrep -x xcodebuild || echo none)"

# 3) Double-check no peer slipped in between the pgrep wait and the lock.
if pgrep -x xcodebuild >/dev/null 2>&1; then
  echo "BLOCKED: a peer xcodebuild appeared while acquiring the lock; releasing and failing"
  exit 3
fi

echo "== running: $*"
"$@"
status=$?
echo "== xcodebuild exit=$status at $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
exit $status
