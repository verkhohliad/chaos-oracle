#!/usr/bin/env bash
# Wait for anvil RPC to be ready.
# Usage: ./wait-for-anvil.sh [rpc_url] [max_retries]

set -euo pipefail

RPC_URL="${1:-http://anvil:8545}"
MAX_RETRIES="${2:-60}"

echo "Waiting for anvil at $RPC_URL ..."

for i in $(seq 1 "$MAX_RETRIES"); do
    if cast block-number --rpc-url "$RPC_URL" >/dev/null 2>&1; then
        echo "Anvil is ready (attempt $i)"
        exit 0
    fi
    sleep 1
done

echo "ERROR: Anvil not ready after $MAX_RETRIES seconds"
exit 1
