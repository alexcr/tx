#!/bin/sh
. "$(dirname "$0")/helpers.sh"

WS=$(make_workspace frontend backend) || exit 1

it "shows workspace config with no args"
out=$(tx_in "$WS" config)
assert_contains "$out" "start"
assert_contains "$out" "yarn start"

it "sets a workspace key"
out=$(tx_in "$WS" config start "npm run dev"); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_contains "$(cat "$WS/.tx/config")" 'TX_START_CMD="npm run dev"'

it "reads a single workspace key"
assert_eq "$(tx_in "$WS" config start)" "npm run dev"

it "sets a project key"
out=$(tx_in "$WS" config frontend/port 9300); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_contains "$(cat "$WS/.tx/projects/frontend.conf")" 'TX_PORT_START="9300"'

it "shows a project's effective config"
out=$(tx_in "$WS" config frontend)
assert_contains "$out" "9300"
assert_contains "$out" "npm run dev"

it "leaves other projects on the workspace value"
assert_contains "$(tx_in "$WS" config backend)" "9001"

it "unsets a key"
out=$(tx_in "$WS" config frontend/port --unset); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_not_contains "$(cat "$WS/.tx/projects/frontend.conf")" "TX_PORT_START"

it "rejects an unknown key"
out=$(tx_in "$WS" config bogus somevalue); TX_STATUS=$?
assert_fails "$TX_STATUS"
assert_contains "$out" "unknown config key"

it "rejects a workspace-only key at project scope"
out=$(tx_in "$WS" config frontend/db "some cmd"); TX_STATUS=$?
assert_fails "$TX_STATUS"
assert_contains "$out" "workspace-level"

it "infers the project from PWD"
out=$(tx_in "$WS/frontend" config)
assert_contains "$out" "frontend"

it "round-trips a value with shell operators inside quotes"
# `&&` survives because it is written inside the double-quoted value and the
# loader's eval keeps quoted operators literal.
out=$(tx_in "$WS" config start 'echo hi && echo bye'); TX_STATUS=$?
assert_ok "$TX_STATUS"
assert_eq "$(tx_in "$WS" config start)" "echo hi && echo bye"

it "does not store a \$-value literally (characterization)"
# Known limitation: config values are shell-eval'd on load; $, backtick, and a
# trailing \ are not literal. A $-reference expands on read-back — here $PORT is
# unset, so 'http://x/$PORT' comes back as 'http://x/', not the input.
out=$(tx_in "$WS" config url 'http://x/$PORT'); TX_STATUS=$?
assert_ok "$TX_STATUS"
back=$(tx_in "$WS" config url)
assert_not_contains "$back" 'PORT'
assert_eq "$back" "http://x/"

cleanup_workspace "$WS"
finish
