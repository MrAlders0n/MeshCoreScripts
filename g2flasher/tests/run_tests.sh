#!/usr/bin/env bash
# Run every g2flasher shell test. Usage: bash g2flasher/tests/run_tests.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
rc=0

for t in "$HERE"/test_*.sh; do
    printf '\n=== %s ===\n' "$(basename "$t")"
    if ! bash "$t"; then rc=1; fi
done

printf '\n'
if [ "$rc" -eq 0 ]; then printf 'ALL TESTS PASSED\n'; else printf 'TESTS FAILED\n'; fi
exit "$rc"
