#!/usr/bin/env bash
# Runs the GasSnapshotE2E forge script against a local anvil node and writes
# the gas snapshot to snapshots/GasSnapshotE2E.txt.
set -euo pipefail

PORT="${PORT:-8585}"
RPC_URL="http://localhost:${PORT}"
OUT="snapshots/GasSnapshotE2E.txt"
# Default anvil dev key (account #0); only used against the local node.
PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

ANVIL_PID=""
cleanup() {
  [ -n "$ANVIL_PID" ] && kill "$ANVIL_PID" 2>/dev/null || true
  rm -rf broadcast/GasSnapshotE2E.s.sol
}
trap cleanup EXIT

anvil --port "$PORT" --code-size-limit 65536 --print-traces > /tmp/anvil-e2e.log 2>&1 &
ANVIL_PID=$!

until cast block-number --rpc-url "$RPC_URL" > /dev/null 2>&1; do sleep 0.1; done

forge script script/GasSnapshotE2E.s.sol \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --slow \
  --disable-code-size-limit \
  --private-key "$PRIVATE_KEY" \
  --non-interactive 2>&1 \
  | grep -iE 'gas used|\[[0-9]+\]' > "$OUT"

echo "Wrote $OUT"
