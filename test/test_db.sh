#!/bin/sh
. "$(dirname "$0")/helpers.sh"

WS=$(make_workspace frontend) || exit 1

it "reports not running on a fresh workspace"
assert_contains "$(tx_in "$WS" db status)" "Not running"

it "refuses to start without a configured command"
out=$(tx_in "$WS" db start); TX_STATUS=$?
assert_fails "$TX_STATUS"
assert_contains "$out" "No db command configured"

it "lists aliases from .tx/databases"
printf 'staging:db.example.com:5432:app:alex\n' > "$WS/.tx/databases"
out=$(tx_in "$WS" db list)
assert_contains "$out" "staging"
assert_contains "$out" "alex@db.example.com:5432/app"

it "errors on an unknown alias"
out=$(tx_in "$WS" db run nope "select 1"); TX_STATUS=$?
assert_fails "$TX_STATUS"
assert_contains "$out" "Unknown alias"

it "starts and stops a configured command"
printf 'TX_DB_CMD="sleep 30"\n' > "$WS/.tx/config"
out=$(tx_in "$WS" db start); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_contains "$(tx_in "$WS" db status)" "Running"
# Pin the relocation: state lands under <root>/.tx/run/, not /tmp.
assert_eq "$(ls "$WS/.tx/run/db.pid" 2>/dev/null | wc -l | tr -d ' ')" "1"
out=$(tx_in "$WS" db stop)
assert_contains "$out" "Stopped"

it "works from inside a worktree"
tx_in "$WS" wt add frontend/wt1 >/dev/null
assert_contains "$(tx_in "$WS/.worktrees/frontend/wt1" db list)" "staging"

cleanup_workspace "$WS"
finish
