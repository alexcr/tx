#!/bin/sh
. "$(dirname "$0")/helpers.sh"

WS=$(make_workspace frontend backend) || exit 1
mkdir -p "$WS/notarepo" "$WS/.hidden"

it "lists git repos under the root, sorted"
out=$(tx_in "$WS" projects); TX_STATUS=$?
assert_eq "$out" "backend
frontend"

it "exits 0 when listing projects"
out=$(tx_in "$WS" projects); TX_STATUS=$?
assert_ok "$TX_STATUS"

it "ignores non-repo directories"
assert_not_contains "$(tx_in "$WS" projects)" "notarepo"

it "ignores dotfile directories"
assert_not_contains "$(tx_in "$WS" projects)" ".hidden"

it "works from inside a project"
assert_contains "$(tx_in "$WS/frontend" projects)" "frontend"

it "does not treat a subdirectory of a repo as a project"
mkdir -p "$WS/frontend/packages/ui"
assert_not_contains "$(tx_in "$WS" projects)" "packages"

# --- tx_project_path (unit-tested by sourcing common.sh directly) ---
# tx_project_path is a resolver used by later commands, not a command itself.
# Source common.sh into this shell and drive it from the workspace root. Each
# call runs in a command-substitution subshell so its tx_die (exit 1) is caught
# by $? rather than killing the test run.
TX_ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$TX_ROOT/lib/common.sh"
mkdir -p "$WS/.dotrepo"
_test_git -C "$WS/.dotrepo" init --quiet
cd "$WS" || exit 1
tx_require_root

it "resolves a valid project name to its absolute path"
out=$(tx_project_path frontend); TX_STATUS=$?
assert_eq "$out" "$WS/frontend"

it "resolves with exit 0"
out=$(tx_project_path frontend); TX_STATUS=$?
assert_ok "$TX_STATUS"

it "dies on an unknown name, listing known projects"
out=$(tx_project_path nope 2>&1); TX_STATUS=$?
assert_fails "$TX_STATUS"
assert_contains "$out" "no project 'nope'"
assert_contains "$out" "frontend"

it "rejects a slash-containing name that would escape the root"
out=$(tx_project_path "../outside" 2>&1); TX_STATUS=$?
assert_fails "$TX_STATUS"

it "rejects a dotfile name the lister hides, even when it is a repo"
out=$(tx_project_path ".dotrepo" 2>&1); TX_STATUS=$?
assert_fails "$TX_STATUS"

it "rejects a trailing-dot name like frontend/."
out=$(tx_project_path "frontend/." 2>&1); TX_STATUS=$?
assert_fails "$TX_STATUS"

cleanup_workspace "$WS"
finish
