#!/usr/bin/env bash
# #1032 diagnosis: run the Force clearance case and, once XCTest reports the
# app never went idle, sample the simulator app's main thread (the simulator
# app is a host process, so /usr/bin/sample can read it).
# Usage (repo root): bash docs/evidence/issue-1032/tools/sample-hang.sh <log-prefix>
set -uo pipefail
P="$1"
bash docs/evidence/issue-1032/tools/clearance-se.sh "$P.log" \
  SendmeterNativeUITests/TabBarClearanceUITests/testForceLastRowIsFullyVisibleAboveTheForceBarAndTabBar &
RUN=$!
for _ in $(seq 1 120); do
  sleep 5
  if grep -q "idle notification not received" "$P.log" 2>/dev/null; then
    PID=$(pgrep -f "Sendmeter.app/Sendmeter" | head -1)
    echo "sampling pid=$PID" > "$P.sample.txt"
    [[ -n "$PID" ]] && /usr/bin/sample "$PID" 4 -mayDie >> "$P.sample.txt" 2>&1
    break
  fi
  kill -0 $RUN 2>/dev/null || break
done
wait $RUN; echo "exit=$?"
