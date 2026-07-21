#!/bin/sh
. "$(dirname "$0")/helpers.sh"

# replacement for the body above — drives tx_load_config directly
TX_ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$TX_ROOT/lib/common.sh"

WS=$(make_workspace frontend backend)
printf 'TX_PORT_START="9500"\nTX_START_CMD="workspace-cmd"\nTX_DB_CMD="workspace-db"\n' > "$WS/.tx/config"
printf 'TX_START_CMD="frontend-cmd"\nTX_DB_CMD="frontend-db"\n' > "$WS/.tx/projects/frontend.conf"

cd "$WS" || exit 1
tx_require_root

it "uses the workspace default for a project without overrides"
tx_load_config backend
assert_eq "$TX_START_CMD" "workspace-cmd"

it "lets a project override a workspace value"
tx_load_config frontend
assert_eq "$TX_START_CMD" "frontend-cmd"

it "inherits non-overridden workspace values"
assert_eq "$TX_PORT_START" "9500"

it "falls back to the built-in default when nothing is set"
assert_eq "$TX_INSTALL_CMD" "yarn install"

it "auto-detects the default branch per project"
assert_eq "$TX_DEFAULT_BRANCH" "main"

it "does not leak one project's config into the next"
tx_load_config backend
assert_eq "$TX_START_CMD" "workspace-cmd"

it "ignores a workspace-only key set in a project file"
tx_load_config frontend
assert_eq "$TX_DB_CMD" "workspace-db"

it "still applies a workspace-only key from the workspace config"
assert_eq "$TX_DB_CMD" "workspace-db"

it "dies with the file and line on a malformed config line"
BAD=$(make_workspace app)
printf 'TX_START_CMD=yarn start\n' > "$BAD/.tx/config"
out=$(cd "$BAD" && sh -c '. "'"$TX_ROOT"'/lib/common.sh"; tx_require_root; tx_load_config app' 2>&1)
assert_contains "$out" "invalid config line in $BAD/.tx/config"
cleanup_workspace "$BAD"

cleanup_workspace "$WS"
finish
