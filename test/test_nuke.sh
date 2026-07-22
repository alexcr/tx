#!/bin/sh
. "$(dirname "$0")/helpers.sh"

WS=$(make_workspace frontend backend) || exit 1
tx_in "$WS" wt add frontend/a >/dev/null
tx_in "$WS" wt add backend/b >/dev/null

it "scoped to a project, removes only that project's worktrees"
out=$(tx_in "$WS" nuke frontend -y); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_no_dir "$WS/.worktrees/frontend/a"
assert_dir "$WS/.worktrees/backend/b"

it "removes everything with no argument"
tx_in "$WS" wt add frontend/c >/dev/null
out=$(tx_in "$WS" nuke -y); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_no_dir "$WS/.worktrees/frontend/c"
assert_no_dir "$WS/.worktrees/backend/b"

it "forces past dirty worktrees"
tx_in "$WS" wt add frontend/d >/dev/null
echo dirty > "$WS/.worktrees/frontend/d/README.md"
out=$(tx_in "$WS" nuke -y)
assert_no_dir "$WS/.worktrees/frontend/d"

it "leaves the projects themselves alone"
assert_dir "$WS/frontend/.git"

it "is a no-op on a clean workspace"
out=$(tx_in "$WS" nuke -y); TX_STATUS=$?
assert_ok "$TX_STATUS"

# --- server / db stop coverage (state-file based, sandbox-safe) ---
#
# A live server/db is not needed to test which state nuke tears down:
# _serv_stop_dir removes .tx/run/serv/<hash>.* whether or not the pid is alive
# (the kill is guarded by tx_is_alive), and _db_stop removes db.pid even for a
# stale pid. So we register fake state pointing at a dead pid and assert on the
# files. File-existence checks run in the normal in-sandbox suite.

SERV_DIR="$WS/.tx/run/serv"
DB_PID_FILE="$WS/.tx/run/db.pid"

# Same hashing as tx_hash_dir (md5 of the absolute dir path).
serv_hash() { printf '%s' "$1" | md5 -q 2>/dev/null || printf '%s' "$1" | md5sum | cut -d' ' -f1; }

# Register a fake tracked server for a directory, pointing at a dead pid.
reg_serv() {
  local h; h=$(serv_hash "$1")
  echo 99999 > "$SERV_DIR/$h.pid"
  echo 9001  > "$SERV_DIR/$h.port"
  echo "$1"  > "$SERV_DIR/$h.dir"
  echo "http://localhost:9001" > "$SERV_DIR/$h.url"
}
serv_file() { echo "$SERV_DIR/$(serv_hash "$1").pid"; }

assert_file()    { if [ -f "$1" ]; then pass; else fail "expected file to exist: $1"; fi; }
assert_no_file() { if [ -f "$1" ]; then fail "expected file to be gone: $1"; else pass; fi; }

it "scoped nuke stops only that project's server, leaving others"
reg_serv "$WS/frontend"
reg_serv "$WS/backend"
out=$(tx_in "$WS" nuke frontend -y); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_no_file "$(serv_file "$WS/frontend")"
assert_file "$(serv_file "$WS/backend")"

it "scoped nuke never stops the workspace db"
echo 99999 > "$DB_PID_FILE"
out=$(tx_in "$WS" nuke frontend -y); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_file "$DB_PID_FILE"

it "full nuke stops every server and the db"
reg_serv "$WS/frontend"
reg_serv "$WS/backend"
echo 99999 > "$DB_PID_FILE"
out=$(tx_in "$WS" nuke -y); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_no_file "$(serv_file "$WS/frontend")"
assert_no_file "$(serv_file "$WS/backend")"
assert_no_file "$DB_PID_FILE"

cleanup_workspace "$WS"
finish
