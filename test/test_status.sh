#!/bin/sh
. "$(dirname "$0")/helpers.sh"

WS=$(make_workspace frontend backend) || exit 1
tx_in "$WS" wt add frontend/wt1 >/dev/null

it "shows the workspace header"
assert_contains "$(tx_in "$WS" status)" "Workspace:"

it "lists a project that has worktrees"
assert_contains "$(tx_in "$WS" status)" "=== frontend ==="

it "lists worktrees under their project"
assert_contains "$(tx_in "$WS" status)" "wt1"

it "omits projects with no worktrees from the full view"
assert_not_contains "$(tx_in "$WS" status)" "=== backend ==="

it "omits the db section when the db is not running"
assert_not_contains "$(tx_in "$WS" status)" "=== DB ==="

it "shows the db section when the db is running"
mkdir -p "$WS/.tx/run"
echo $$ > "$WS/.tx/run/db.pid"          # this test shell's own pid — genuinely alive
printf 'TX_DB_CMD="my-db-proxy"\n' > "$WS/.tx/config"
out=$(tx_in "$WS" status)
assert_contains "$out" "=== DB ==="
assert_contains "$out" "Running"
assert_contains "$out" "my-db-proxy"
rm -f "$WS/.tx/run/db.pid" "$WS/.tx/config"

it "scoped to an empty project still shows it with (no worktrees)"
out=$(tx_in "$WS" status backend)
assert_contains "$out" "=== backend ==="
assert_contains "$out" "(no worktrees)"

it "narrows to one project"
assert_not_contains "$(tx_in "$WS" status frontend)" "=== backend ==="

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
