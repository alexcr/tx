#!/bin/sh
. "$(dirname "$0")/helpers.sh"

WS=$(make_workspace frontend backend) || exit 1

it "creates the workspace root"
assert_dir "$WS/.tx"

it "creates each repo as a git worktree-capable repo"
assert_dir "$WS/frontend/.git"

it "puts the repo on the default branch"
assert_eq "$(_test_git -C "$WS/frontend" rev-parse --abbrev-ref HEAD)" "main"

it "gives the repo an up-to-date origin"
assert_eq "$(_test_git -C "$WS/frontend" rev-list --count origin/main..main)" "0"

it "reports a zero exit code from tx"
tx_in "$WS/frontend" --version >/dev/null; TX_STATUS=$?
assert_ok "$TX_STATUS"

it "reports a non-zero exit code from tx captured in a subshell"
out=$(tx_in "$WS/frontend" no-such-command); TX_STATUS=$?
assert_fails "$TX_STATUS"

it "captures tx stderr in the output"
assert_contains "$out" "unknown command 'no-such-command'"

cleanup_workspace "$WS"
finish
