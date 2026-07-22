#!/bin/sh
. "$(dirname "$0")/helpers.sh"
TX_ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$TX_ROOT/lib/common.sh"

WS=$(make_workspace frontend backend)
mkdir -p "$WS/.worktrees/frontend/wt1/src"

cd "$WS" || exit 1
tx_require_root

it "parses project/worktree"
assert_eq "$(tx_resolve_target frontend/wt1)" \
  "frontend	wt1	$WS/.worktrees/frontend/wt1"

it "parses a bare project"
assert_eq "$(tx_resolve_target frontend)" "frontend		$WS/frontend"

it "rejects an unknown project"
out=$(tx_resolve_target nope 2>&1); TX_STATUS=$?
assert_fails "$TX_STATUS"

it "rejects a nested worktree name"
out=$(tx_resolve_target frontend/a/b 2>&1); TX_STATUS=$?
assert_fails "$TX_STATUS"

it "infers a project from PWD"
cd "$WS/frontend" || exit 1
assert_eq "$(tx_resolve_target)" "frontend		$WS/frontend"

it "infers a worktree from PWD"
cd "$WS/.worktrees/frontend/wt1" || exit 1
assert_eq "$(tx_resolve_target)" "frontend	wt1	$WS/.worktrees/frontend/wt1"

it "infers a worktree from deep inside it"
cd "$WS/.worktrees/frontend/wt1/src" || exit 1
assert_eq "$(tx_resolve_target)" "frontend	wt1	$WS/.worktrees/frontend/wt1"

it "returns an empty project at the workspace root"
cd "$WS" || exit 1
assert_eq "$(tx_resolve_target)" "		$WS"

cd / || exit 1
cleanup_workspace "$WS"
finish
