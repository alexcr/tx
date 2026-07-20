#!/bin/sh
# test/run.sh — run every test/test_*.sh, report a summary, exit non-zero on failure.

cd "$(dirname "$0")" || exit 1
failed=0
for t in test_*.sh; do
  [ -f "$t" ] || continue
  echo "== $t"
  if ! sh "$t"; then
    failed=$((failed + 1))
  fi
done
echo ""
if [ "$failed" -gt 0 ]; then
  echo "FAILED: $failed test file(s)"
  exit 1
fi
echo "All test files passed."
