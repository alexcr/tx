#!/bin/sh
# test/test_root.sh — workspace root discovery, tx init and tx root.
. "$(dirname "$0")/helpers.sh"

# --- tx init on a bare directory ---

BARE=$(mktemp -d "${TMPDIR:-/tmp}/tx-test.XXXXXX") || exit 1
BARE=$(cd "$BARE" && pwd -P) || exit 1

it "tx init creates the .tx directory"
out=$(tx_in "$BARE" init); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_dir "$BARE/.tx/projects"

it "tx init reports where the root was created"
assert_contains "$out" "$BARE"

it "tx init is idempotent"
out=$(tx_in "$BARE" init); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_dir "$BARE/.tx/projects"

it "tx init refuses to nest a root inside a root"
mkdir -p "$BARE/inner"
out=$(tx_in "$BARE/inner" init); TX_STATUS=$?
assert_fails "$TX_STATUS"
assert_contains "$out" "already inside"
assert_no_dir "$BARE/inner/.tx"

it "tx init errors go to stderr, not stdout"
# tx_in merges the streams, so this one case redirects by hand.
out=$({ cd "$BARE/inner" && HOME="$TX_TEST_HOME" sh "$TX_BIN" init; } 2>/dev/null); TX_STATUS=$?
assert_fails "$TX_STATUS"
assert_eq "$out" ""

cleanup_workspace "$BARE"

# --- root discovery from nested directories ---

WS=$(make_workspace frontend) || exit 1
mkdir -p "$WS/.worktrees/frontend/wt1"

it "finds the root from the root itself"
out=$(tx_in "$WS" root); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_eq "$out" "$WS"

it "finds the root from a project directory"
out=$(tx_in "$WS/frontend" root); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_eq "$out" "$WS"

it "finds the root from deep inside a worktree"
out=$(tx_in "$WS/.worktrees/frontend/wt1" root); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_eq "$out" "$WS"

it "errors outside any workspace"
OUTSIDE=$(mktemp -d "${TMPDIR:-/tmp}/tx-test.XXXXXX") || exit 1
out=$(tx_in "$OUTSIDE" root); TX_STATUS=$?
assert_fails "$TX_STATUS"
assert_contains "$out" "not inside a tx workspace"
cleanup_workspace "$OUTSIDE"

it "tx --version works outside a workspace and outside a repo"
OUTSIDE=$(mktemp -d "${TMPDIR:-/tmp}/tx-test.XXXXXX") || exit 1
out=$(tx_in "$OUTSIDE" --version); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_not_contains "$out" "fatal"

it "tx --help works outside a workspace and outside a repo"
out=$(tx_in "$OUTSIDE" --help); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_not_contains "$out" "fatal"
cleanup_workspace "$OUTSIDE"

it "unknown commands still fail cleanly"
out=$(tx_in "$WS" nosuchcommand); TX_STATUS=$?
assert_fails "$TX_STATUS"
assert_contains "$out" "unknown command"

cleanup_workspace "$WS"

# --- tx_tilde: ~ substitution (never exercised above, since BARE/WS and
# TX_TEST_HOME are distinct dirs, so every assertion took the fallthrough).
# Set HOME just for this call's environment; the harness's tx_in hardcodes
# HOME, so this test invokes tx by hand like the stderr case above.

it "tx init abbreviates HOME to ~ in its output"
TW=$(mktemp -d "${TMPDIR:-/tmp}/tx-test.XXXXXX") || exit 1
TW=$(cd "$TW" && pwd -P) || exit 1
TWPARENT=$(dirname "$TW")
out=$({ cd "$TW" && HOME="$TWPARENT" sh "$TX_BIN" init; } 2>&1); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_contains "$out" "~/$(basename "$TW")"
assert_not_contains "$out" "$TWPARENT/"
cleanup_workspace "$TW"

# --- root resolution through a space in the path and a symlinked ancestor.
# pwd -P must return the physical root, not the symlink path we cd'd through.

it "resolves the root through a spaced path and a symlinked ancestor"
SP="${TMPDIR:-/tmp}/tx-test.sp $$"
mkdir -p "$SP/.tx/projects" "$SP/proj" || exit 1
SPP=$(cd "$SP" && pwd -P) || exit 1
LINK="${TMPDIR:-/tmp}/tx-test.link.$$"
ln -s "$SPP" "$LINK" || exit 1
out=$(tx_in "$LINK/proj" root); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_eq "$out" "$SPP"
rm -f "$LINK"
cleanup_workspace "$SP"

finish
