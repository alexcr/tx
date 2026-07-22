#!/bin/sh
. "$(dirname "$0")/helpers.sh"

WS=$(make_workspace frontend) || exit 1

it "lists the current commands"
out=$(tx_in "$WS" help)
assert_contains "$out" "tx wt"
assert_contains "$out" "tx serv"
assert_contains "$out" "tx db"

it "no longer mentions removed commands"
out=$(tx_in "$WS" help)
assert_not_contains "$out" "tunnel"
assert_not_contains "$out" "tx code"

it "has per-command help"
assert_contains "$(tx_in "$WS" help wt)" "wt add"

it "responds to --help on a command"
assert_contains "$(tx_in "$WS" wt --help)" "wt add"

it "emits completions mentioning the current commands"
out=$(tx_in "$WS" completions)
assert_contains "$out" "compdef _tx tx"
assert_contains "$out" "wt"
assert_not_contains "$out" "tunnel"

it "works outside a workspace"
OUTSIDE=$(mktemp -d "${TMPDIR:-/tmp}/tx-test.XXXXXX")
out=$(tx_in "$OUTSIDE" help); TX_STATUS=$?
assert_ok "$TX_STATUS"
cleanup_workspace "$OUTSIDE"

cleanup_workspace "$WS"
finish
