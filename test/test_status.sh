#!/bin/sh
. "$(dirname "$0")/helpers.sh"

WS=$(make_workspace frontend backend) || exit 1
tx_in "$WS" wt add frontend/wt1 >/dev/null

it "groups by project"
out=$(tx_in "$WS" status)
assert_contains "$out" "=== frontend ==="
assert_contains "$out" "=== backend ==="

it "lists worktrees under their project"
assert_contains "$(tx_in "$WS" status)" "wt1"

it "says when a project has no worktrees"
assert_contains "$(tx_in "$WS" status)" "(no worktrees)"

it "includes a db section"
assert_contains "$(tx_in "$WS" status)" "=== DB ==="

it "narrows to one project"
out=$(tx_in "$WS" status frontend)
assert_not_contains "$out" "=== backend ==="

it "is identical from anywhere in the workspace"
assert_eq "$(tx_in "$WS/frontend" status)" "$(tx_in "$WS" status)"

it "flags orphaned server state"
mkdir -p "$WS/.tx/run/serv"
echo 99999 > "$WS/.tx/run/serv/deadbeef.pid"
echo 9999 > "$WS/.tx/run/serv/deadbeef.port"
echo "/nowhere/gone" > "$WS/.tx/run/serv/deadbeef.dir"
assert_contains "$(tx_in "$WS" status)" "Orphaned"

cleanup_workspace "$WS"
finish
