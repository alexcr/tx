#!/bin/sh
. "$(dirname "$0")/helpers.sh"

WS=$(make_workspace frontend backend)
tx_in "$WS" wt add frontend/wt1 >/dev/null

it "list is empty on a fresh workspace"
assert_contains "$(tx_in "$WS" serv list)" "No servers"

it "start at the workspace root is ambiguous"
out=$(tx_in "$WS" serv start); TX_STATUS=$?
assert_fails "$TX_STATUS"
assert_contains "$out" "pass a target"

if ! command -v python3 >/dev/null 2>&1; then
  echo "  skip: python3 not available, skipping server lifecycle tests"
  cleanup_workspace "$WS"
  finish
fi

printf 'TX_PORT_START="9700"\nTX_START_CMD="python3 -m http.server \$PORT"\nTX_SERV_TIMEOUT="15"\n' \
  > "$WS/.tx/config"

it "starts a server for an explicit target"
out=$(tx_in "$WS" serv start frontend/wt1); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_contains "$out" "9700"

it "records the server under .tx/run/serv"
assert_eq "$(ls "$WS/.tx/run/serv"/*.pid 2>/dev/null | wc -l | tr -d ' ')" "1"

it "shows the canonical id in list"
assert_contains "$(tx_in "$WS" serv list)" "frontend/wt1"

it "reports it as running"
assert_contains "$(tx_in "$WS" serv list)" "running"

it "shows the resolved url in list"
assert_contains "$(tx_in "$WS" serv list)" "http://localhost:9700"

it "refuses to start twice"
out=$(tx_in "$WS" serv start frontend/wt1)
assert_contains "$out" "already running"

it "finds the same server from inside the worktree"
out=$(tx_in "$WS/.worktrees/frontend/wt1" serv log); TX_STATUS=$?
assert_ok "$TX_STATUS"

it "stops from inside the worktree with no target"
out=$(tx_in "$WS/.worktrees/frontend/wt1" serv stop); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_contains "$out" "Stopped"

it "cleans up its state files"
assert_eq "$(ls "$WS/.tx/run/serv"/*.pid 2>/dev/null | wc -l | tr -d ' ')" "0"

it "uses the project port base"
printf 'TX_PORT_START="9800"\n' > "$WS/.tx/projects/frontend.conf"
out=$(tx_in "$WS" serv start frontend/wt1)
assert_contains "$out" "9800"
tx_in "$WS" serv stop frontend/wt1 >/dev/null

it "stop all reports when there is nothing"
assert_contains "$(tx_in "$WS" serv stop all)" "No running servers"

cleanup_workspace "$WS"
finish
