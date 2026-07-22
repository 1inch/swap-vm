#!/usr/bin/env bash
# Runs the GasSnapshotE2E forge script against a local anvil node and writes
# the gas snapshot to snapshots/GasSnapshotE2E.txt.
set -euo pipefail

PORT="${PORT:-8585}"
RPC_URL="http://localhost:${PORT}"
OUT="snapshots/GasSnapshotE2E.txt"
# Default anvil dev key (account #0); only used against the local node.
PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

trap 'rm -rf broadcast/GasSnapshotE2E.s.sol' EXIT

{
  anvil --port "$PORT" --code-size-limit 65536 --print-traces & ANVIL_PID=$!

  until cast block-number --rpc-url "$RPC_URL" > /dev/null 2>&1; do sleep 0.1; done
  FORGE_STATUS=0

  forge script script/GasSnapshotE2E.s.sol \
    --rpc-url "$RPC_URL" \
    --broadcast \
    --slow \
    --disable-code-size-limit \
    --private-key "$PRIVATE_KEY" \
    --non-interactive > /dev/null || FORGE_STATUS=$?

  kill "$ANVIL_PID" 2>/dev/null || true
  exit "$FORGE_STATUS"
} | grep -iE 'gas used|\[[0-9]+\]' > "$OUT"

echo "Wrote $OUT"
