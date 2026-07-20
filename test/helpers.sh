# test/helpers.sh — assertions and workspace fixtures for tx tests.
# Sourced by every test/test_*.sh. Not executable on its own.
#
# Limitation: tx_in merges tx's stdout and stderr into one captured string.
# That is deliberate — these tests assert on user-visible output, not on which
# stream it came from. A test that must distinguish the two needs its own
# redirection.

TX_BIN="$(cd "$(dirname "$0")/.." && pwd)/bin/tx"
[ -f "$TX_BIN" ] || { printf 'helpers.sh: tx not found at %s\n' "$TX_BIN" >&2; exit 1; }

# An inert, test-owned HOME for tx runs, so a developer's real ~/.txrc cannot
# leak into a test. Created once per test file; the target architecture reads
# nothing from $HOME, so this is only belt-and-braces for the transition.
TX_TEST_HOME="${TMPDIR:-/tmp}/tx-test.home"
mkdir -p "$TX_TEST_HOME"

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_TEST=""
TX_STATUS=""

# --- assertions ---

# Note: every helper that prints a variable uses printf, not echo. Both dash
# and macOS /bin/sh expand backslash escapes in echo, which would silently
# corrupt captured tx output (e.g. 'C:\temp' printed as 'C:<TAB>emp').

fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '  FAIL: %s\n' "$CURRENT_TEST"
  printf '        %s\n' "$1"
  # Indent continuation lines so multi-line output stays readable.
  [ -n "$2" ] && printf '%s\n' "$2" | sed -e '1s/^/        got: /' -e '2,$s/^/             /'
  return 0
}

pass() {
  printf '  ok:   %s\n' "$CURRENT_TEST"
  return 0
}

it() {
  CURRENT_TEST="$1"
  TESTS_RUN=$((TESTS_RUN + 1))
  # Clear any status left by a previous tx_in, so a test that forgets its
  # `TX_STATUS=$?` trips the guard in assert_ok/assert_fails instead of
  # silently asserting against the previous test's exit code.
  TX_STATUS=""
}

# assert_eq <actual> <expected>
assert_eq() {
  if [ "$1" = "$2" ]; then pass; else fail "expected '$2'" "'$1'"; fi
}

assert_contains() {
  case "$1" in
    *"$2"*) pass ;;
    *) fail "expected output to contain '$2'" "'$1'" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "expected output NOT to contain '$2'" "'$1'" ;;
    *) pass ;;
  esac
}

assert_dir() {
  if [ -d "$1" ]; then pass; else fail "expected directory to exist: $1"; fi
}

assert_no_dir() {
  if [ -d "$1" ]; then fail "expected directory to be gone: $1"; else pass; fi
}

assert_ok() {
  case "$1" in
    ''|*[!0-9]*) fail "expected exit 0, but got no exit code (missing 'TX_STATUS=\$?'?)" "'$1'"; return 0 ;;
  esac
  if [ "$1" -eq 0 ]; then pass; else fail "expected exit 0" "exit $1"; fi
}

assert_fails() {
  case "$1" in
    ''|*[!0-9]*) fail "expected an exit code, but got none (missing 'TX_STATUS=\$?'?)" "'$1'"; return 0 ;;
  esac
  if [ "$1" -ne 0 ]; then pass; else fail "expected non-zero exit" "exit 0"; fi
}

# --- fixtures ---

# git with the developer's global/system config ignored, so a stray
# core.hooksPath, commit.template or signing key cannot break the fixtures.
_test_git() {
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git "$@"
}

# Create a temp workspace root with N git repos in it.
# Usage: WS=$(make_workspace frontend backend)
# Each repo gets one commit on branch "main" and a local bare "origin".
make_workspace() {
  local ws
  ws=$(mktemp -d "${TMPDIR:-/tmp}/tx-test.XXXXXX")
  ws=$(cd "$ws" && pwd -P)
  mkdir -p "$ws/.tx/projects" "$ws/.tx/run/serv"
  local name
  for name in "$@"; do
    if ! make_repo "$ws" "$name"; then
      printf 'make_workspace: failed to create repo %s in %s\n' "$name" "$ws" >&2
      rm -rf "$ws"
      return 1
    fi
  done
  printf '%s\n' "$ws"
}

# Create a git repo <ws>/<name> with an origin remote it is up to date with.
# Body is a subshell with `set -e` so any failing git step aborts non-zero.
make_repo() (
  set -e
  ws="$1"
  name="$2"
  repo="$ws/$name"
  remote="$ws/.remotes/$name.git"
  mkdir -p "$repo" "$(dirname "$remote")"
  _test_git init --quiet --bare "$remote"
  _test_git init --quiet -b main "$repo"
  _test_git -C "$repo" config user.email tx@test
  _test_git -C "$repo" config user.name tx
  _test_git -C "$repo" config commit.gpgsign false
  printf '%s\n' "$name" > "$repo/README.md"
  _test_git -C "$repo" add README.md
  _test_git -C "$repo" commit --quiet -m "init"
  _test_git -C "$repo" remote add origin "$remote"
  _test_git -C "$repo" push --quiet -u origin main
)

# Run tx from a directory, capturing stdout+stderr and tx's exit code.
#
#   out=$(tx_in "$WS/frontend" wt list); TX_STATUS=$?
#
# The `TX_STATUS=$?` is required: command substitution runs in a subshell, so a
# variable set inside tx_in cannot reach the caller. tx_in returns tx's exit
# code as its own, which `$?` picks up after the substitution.
tx_in() {
  local dir="$1"
  shift
  local out status
  # The braces put the `cd` inside the capture: without them a failing cd
  # writes to the test's stderr instead of into "$out".
  out=$({ cd "$dir" && HOME="$TX_TEST_HOME" sh "$TX_BIN" "$@"; } 2>&1)
  status=$?
  TX_STATUS=$status
  printf '%s\n' "$out"
  return "$status"
}

cleanup_workspace() {
  case "$1" in
    /*/tx-test.*) rm -rf "$1" ;;
    *) printf "refusing to rm '%s'\n" "$1" >&2 ;;
  esac
}

finish() {
  echo ""
  printf '  %s tests, %s failed assertions\n' "$TESTS_RUN" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ] || exit 1
  exit 0
}
