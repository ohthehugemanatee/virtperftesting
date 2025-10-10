#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
export OC_LOG=$(mktemp --suffix=perfprep.log)

source "$DIR/mocks.sh"

# Run prep script with harmless defaults in the same shell to inherit mocks
ASK_ALL=true COMPUTE_MACHINESET=Standard_D96s_v5 COMPUTE_COUNT=3 USE_ODF_POOL=false \
  source ./scripts/prep-cluster.sh || true

# Compare generated log with expected
if diff -u "$DIR/expected-commands.txt" "$OC_LOG"; then
  echo "All tests passed."
  rm -rf $OC_LOG
else
  echo "Test failed."
  diff "$DIR/expected-commands.txt" "$OC_LOG"
  rm -rf $OC_LOG
  exit 1
fi

