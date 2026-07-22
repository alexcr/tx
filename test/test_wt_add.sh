#!/bin/sh
. "$(dirname "$0")/helpers.sh"

WS=$(make_workspace frontend backend)

it "creates the worktree under .worktrees/<project>/<name>"
out=$(tx_in "$WS" wt add frontend/wt1); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_dir "$WS/.worktrees/frontend/wt1"

it "creates a branch named after the worktree"
assert_eq "$(git -C "$WS/.worktrees/frontend/wt1" rev-parse --abbrev-ref HEAD)" "wt1"

it "keeps projects separate"
out=$(tx_in "$WS" wt add backend/wt1); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_dir "$WS/.worktrees/backend/wt1"

it "honours -b for the branch name"
out=$(tx_in "$WS" wt add frontend/hotfix -b fix/login); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_eq "$(git -C "$WS/.worktrees/frontend/hotfix" rev-parse --abbrev-ref HEAD)" "fix/login"

it "checks out an existing branch instead of recreating it"
git -C "$WS/frontend" branch already-here main
out=$(tx_in "$WS" wt add frontend/reuse -b already-here); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_eq "$(git -C "$WS/.worktrees/frontend/reuse" rev-parse --abbrev-ref HEAD)" "already-here"

it "infers the project when run from inside it"
out=$(tx_in "$WS/frontend" wt add inferred); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_dir "$WS/.worktrees/frontend/inferred"

it "refuses when the worktree already exists"
out=$(tx_in "$WS" wt add frontend/wt1); TX_STATUS=$?
assert_fails "$TX_STATUS"
assert_contains "$out" "already exists"

it "refuses an unknown project"
out=$(tx_in "$WS" wt add nope/wt1); TX_STATUS=$?
assert_fails "$TX_STATUS"
assert_contains "$out" "no project 'nope'"

it "refuses when the project checkout is dirty"
echo dirty > "$WS/backend/README.md"
out=$(tx_in "$WS" wt add backend/wt2); TX_STATUS=$?
assert_fails "$TX_STATUS"
assert_contains "$out" "dirty"
git -C "$WS/backend" checkout --quiet -- README.md

it "copies TX_COPY patterns into the new worktree"
printf 'TX_COPY=".env"\n' > "$WS/.tx/projects/backend.conf"
echo "SECRET=1" > "$WS/backend/.env"
out=$(tx_in "$WS" wt add backend/withenv); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_eq "$(cat "$WS/.worktrees/backend/withenv/.env" 2>/dev/null)" "SECRET=1"

it "globs TX_COPY patterns against the project, not the caller's CWD"
printf 'TX_COPY="config/*.json"\n' > "$WS/.tx/projects/frontend.conf"
# Untracked, so the file reaches the worktree ONLY via TX_COPY (git checkout
# would carry a committed file regardless, masking the glob bug).
mkdir -p "$WS/frontend/config"
printf '{"real":1}\n' > "$WS/frontend/config/real.json"
# A decoy in the caller's CWD (workspace root) matching the same glob. The old
# code expanded the glob here, against CWD, and copied a decoy path absent from
# the repo, so the real file never arrived. The fix globs inside the repo.
mkdir -p "$WS/config"
printf '{"decoy":1}\n' > "$WS/config/decoy.json"
out=$(tx_in "$WS" wt add frontend/globtest); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_eq "$(cat "$WS/.worktrees/frontend/globtest/config/real.json" 2>/dev/null)" '{"real":1}'
assert_eq "$(cat "$WS/.worktrees/frontend/globtest/config/decoy.json" 2>/dev/null)" ""

it "requires a worktree name at the workspace root"
out=$(tx_in "$WS" wt add); TX_STATUS=$?
assert_fails "$TX_STATUS"

cleanup_workspace "$WS"
finish
