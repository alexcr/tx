#!/bin/sh
. "$(dirname "$0")/helpers.sh"

WS=$(make_workspace frontend backend)
tx_in "$WS" wt add frontend/b_second >/dev/null
tx_in "$WS" wt add frontend/a_first >/dev/null
tx_in "$WS" wt add backend/only >/dev/null

it "lists every worktree across projects"
out=$(tx_in "$WS" wt list)
assert_contains "$out" "frontend/a_first"
assert_contains "$out" "backend/only"

it "sorts by project then worktree"
out=$(tx_in "$WS" wt list)
assert_eq "$(echo "$out" | awk '{print $1}' | tr '\n' ' ')" \
  "backend/only frontend/a_first frontend/b_second "

it "narrows to one project"
out=$(tx_in "$WS" wt list frontend)
assert_not_contains "$out" "backend/only"

it "shows the branch"
assert_contains "$(tx_in "$WS" wt list backend)" "only"

it "gives the same output from anywhere in the workspace"
assert_eq "$(tx_in "$WS/frontend" wt list)" "$(tx_in "$WS" wt list)"

it "says so when there is nothing"
WS2=$(make_workspace solo)
assert_contains "$(tx_in "$WS2" wt list)" "No worktrees"
cleanup_workspace "$WS2"

it "supports --names for completions"
out=$(tx_in "$WS" wt list --names)
assert_eq "$(echo "$out" | head -1)" "backend/only"

cleanup_workspace "$WS"
finish
