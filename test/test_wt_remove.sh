#!/bin/sh
. "$(dirname "$0")/helpers.sh"

WS=$(make_workspace frontend backend) || exit 1

it "removes a single worktree by target"
tx_in "$WS" wt add frontend/one >/dev/null
out=$(tx_in "$WS" wt remove frontend/one -y); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_no_dir "$WS/.worktrees/frontend/one"

it "keeps the branch"
assert_eq "$(git -C "$WS/frontend" show-ref --verify --quiet refs/heads/one; echo $?)" "0"

it "refuses a dirty worktree"
tx_in "$WS" wt add frontend/dirty >/dev/null
echo change > "$WS/.worktrees/frontend/dirty/README.md"
out=$(tx_in "$WS" wt remove frontend/dirty -y); TX_STATUS=$?
assert_fails "$TX_STATUS"
assert_contains "$out" "uncommitted changes"
assert_dir "$WS/.worktrees/frontend/dirty"

it "removes a dirty worktree with -f"
out=$(tx_in "$WS" wt remove frontend/dirty -y -f); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_no_dir "$WS/.worktrees/frontend/dirty"

# Pins the deliberate asymmetry with _wt_add's preflight: add ignores untracked
# files in the source repo (--untracked-files=no), but remove DELETES the
# worktree, so a lone untracked file must block the delete without -f.
it "refuses a worktree dirtied only by an untracked file"
tx_in "$WS" wt add frontend/untracked >/dev/null
echo secret > "$WS/.worktrees/frontend/untracked/.env"
out=$(tx_in "$WS" wt remove frontend/untracked -y); TX_STATUS=$?
assert_fails "$TX_STATUS"
assert_contains "$out" "uncommitted changes"
assert_dir "$WS/.worktrees/frontend/untracked"

it "removes the untracked-dirty worktree with -f"
out=$(tx_in "$WS" wt remove frontend/untracked -y -f); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_no_dir "$WS/.worktrees/frontend/untracked"

it "refuses a worktree with unpushed commits"
tx_in "$WS" wt add frontend/unpushed >/dev/null
WT="$WS/.worktrees/frontend/unpushed"
git -C "$WT" config user.email tx@test
git -C "$WT" config user.name tx
echo more > "$WT/NEW.md"
git -C "$WT" add NEW.md
git -C "$WT" commit --quiet -m "local only"
out=$(tx_in "$WS" wt remove frontend/unpushed -y); TX_STATUS=$?
assert_fails "$TX_STATUS"
assert_contains "$out" "not on origin"

it "removes it with -f"
out=$(tx_in "$WS" wt remove frontend/unpushed -y -f); TX_STATUS=$?
assert_ok "$TX_STATUS"

it "removes every worktree of a project when given a bare project"
tx_in "$WS" wt add frontend/a >/dev/null
tx_in "$WS" wt add frontend/b >/dev/null
tx_in "$WS" wt add backend/keep >/dev/null
out=$(tx_in "$WS" wt remove frontend -y); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_no_dir "$WS/.worktrees/frontend/a"
assert_no_dir "$WS/.worktrees/frontend/b"

it "leaves other projects alone"
assert_dir "$WS/.worktrees/backend/keep"

it "skips a blocked worktree in a bulk removal without aborting"
tx_in "$WS" wt add backend/clean >/dev/null
tx_in "$WS" wt add backend/messy >/dev/null
echo change > "$WS/.worktrees/backend/messy/README.md"
out=$(tx_in "$WS" wt remove backend -y); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_no_dir "$WS/.worktrees/backend/clean"
assert_dir "$WS/.worktrees/backend/messy"
assert_contains "$out" "Skipped"

it "removes the current worktree when run from inside it with no target"
tx_in "$WS" wt add frontend/inside >/dev/null
out=$(tx_in "$WS/.worktrees/frontend/inside" wt remove -y); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_no_dir "$WS/.worktrees/frontend/inside"

it "errors on an unknown worktree"
out=$(tx_in "$WS" wt remove frontend/ghost -y); TX_STATUS=$?
assert_fails "$TX_STATUS"
assert_contains "$out" "no worktree"

cleanup_workspace "$WS"
finish
