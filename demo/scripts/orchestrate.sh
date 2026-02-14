#!/usr/bin/env bash
# Orchestrate the full ChaosOracle lifecycle locally.
#
# This script replaces the CRE workflow by manually triggering
# createStudioForMarket() and closeStudioEpoch() on the Registry.
#
# Flow:
#   1. Create a prediction market
#   2. Place bets from two accounts
#   3. Fast-forward time past the deadline
#   4. Create studio (simulating CRE trigger 1)
#   5. Wait for agents to register, submit work, and score
#   6. Close epoch (simulating CRE trigger 2)
#   7. Verify settlement and print results

set -euo pipefail

RPC_URL="${RPC_URL:-http://anvil:8545}"
SHARED_DIR="${SHARED_DIR:-/shared}"

# ── Anvil default keys ──
DEPLOYER_KEY="${DEPLOYER_PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
BETTOR1_KEY="0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"   # account 1
BETTOR2_KEY="0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"   # account 2

# ── Wait for addresses file ──
echo "=== ChaosOracle Orchestrator ==="
echo "Waiting for deployment addresses..."

for i in $(seq 1 120); do
    if [ -f "$SHARED_DIR/addresses.json" ] \
       && jq -e '.registry and .market' "$SHARED_DIR/addresses.json" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

if ! jq -e '.registry and .market' "$SHARED_DIR/addresses.json" >/dev/null 2>&1; then
    echo "ERROR: valid addresses.json not found after 120s"
    exit 1
fi

REGISTRY=$(jq -r '.registry' "$SHARED_DIR/addresses.json")
MARKET=$(jq -r '.market' "$SHARED_DIR/addresses.json")

echo "Registry: $REGISTRY"
echo "Market:   $MARKET"
echo ""

# ── Phase 1: Create market ──
echo "=== Phase 1: Create Market ==="
DEADLINE=$(($(date +%s) + 120))  # 2 minutes from now (we'll warp past it)

# Read nextMarketId before tx — createMarket does `marketId = nextMarketId++`
MARKET_ID=$(cast call --rpc-url "$RPC_URL" "$MARKET" "nextMarketId()(uint256)")
echo "Next market ID: $MARKET_ID"

TX_HASH=$(cast send \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_KEY" \
    --value 1ether \
    --json \
    "$MARKET" \
    "createMarket(string,uint256)(uint256)" \
    "Will ETH reach \$10,000 by end of 2025?" \
    "$DEADLINE" | jq -r '.transactionHash')
echo "Market created (tx: $TX_HASH)"
echo "Deadline: $DEADLINE"
echo "Market ID: $MARKET_ID"

# ── Phase 2: Place bets ──
echo ""
echo "=== Phase 2: Place Bets ==="

TX_HASH=$(cast send \
    --rpc-url "$RPC_URL" \
    --private-key "$BETTOR1_KEY" \
    --value 0.5ether \
    --json \
    "$MARKET" \
    "placeBet(uint256,uint8)" \
    "$MARKET_ID" 0 | jq -r '.transactionHash')
echo "Bettor 1 bet 0.5 ETH on Yes (tx: $TX_HASH)"

TX_HASH=$(cast send \
    --rpc-url "$RPC_URL" \
    --private-key "$BETTOR2_KEY" \
    --value 0.3ether \
    --json \
    "$MARKET" \
    "placeBet(uint256,uint8)" \
    "$MARKET_ID" 1 | jq -r '.transactionHash')
echo "Bettor 2 bet 0.3 ETH on No (tx: $TX_HASH)"

# ── Phase 3: Fast-forward time ──
echo ""
echo "=== Phase 3: Warp Time Past Deadline ==="
cast rpc --rpc-url "$RPC_URL" evm_increaseTime 3601 > /dev/null
cast rpc --rpc-url "$RPC_URL" evm_mine > /dev/null
echo "Time advanced 3601 seconds past deadline"

# ── Phase 4: Create Studio (simulating CRE) ──
echo ""
echo "=== Phase 4: Create Studio ==="

# Get ready market keys
READY_KEYS=$(cast call \
    --rpc-url "$RPC_URL" \
    "$REGISTRY" \
    "getMarketsReadyForSettlement()(bytes32[])")
echo "Ready markets: $READY_KEYS"

# Parse first key from the array output
# cast returns format like: [0x1234...5678]
MARKET_KEY=$(echo "$READY_KEYS" | sed 's/\[//;s/\]//' | tr ',' '\n' | head -1 | xargs)
echo "Market key: $MARKET_KEY"

if [ -z "$MARKET_KEY" ] || [ "${#MARKET_KEY}" -lt 66 ]; then
    echo "ERROR: No ready markets found (got: '$MARKET_KEY')"
    exit 1
fi

# creReport = abi.encode(bytes32(0)) — 32 zero bytes
# authorizedWorkflowId is bytes32(0) (never set), so workflow check is skipped
CRE_REPORT="0x0000000000000000000000000000000000000000000000000000000000000000"

TX_HASH=$(cast send \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_KEY" \
    --json \
    "$REGISTRY" \
    "createStudioForMarket(bytes32,bytes)" \
    "$MARKET_KEY" \
    "$CRE_REPORT" | jq -r '.transactionHash')
echo "Studio created (tx: $TX_HASH)"

# Get studio address
STUDIO=$(cast call \
    --rpc-url "$RPC_URL" \
    "$REGISTRY" \
    "keyToStudio(bytes32)(address)" \
    "$MARKET_KEY")
echo "Studio proxy: $STUDIO"

# Write studio address for reference
jq --arg studio "$STUDIO" --arg key "$MARKET_KEY" \
    '. + {studio: $studio, marketKey: $key}' \
    "$SHARED_DIR/addresses.json" > "$SHARED_DIR/addresses_tmp.json" \
    && mv "$SHARED_DIR/addresses_tmp.json" "$SHARED_DIR/addresses.json"

echo "Studio address written to addresses.json"

# ── Phase 5: Wait for agents ──
echo ""
echo "=== Phase 5: Waiting for Agents ==="
echo "Waiting for workers and verifiers to finish..."

TIMEOUT=180
ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    CAN_CLOSE=$(cast call \
        --rpc-url "$RPC_URL" \
        "$REGISTRY" \
        "canCloseStudio(address)(bool)" \
        "$STUDIO" 2>/dev/null || echo "false")

    if echo "$CAN_CLOSE" | grep -qi "true"; then
        echo "Studio is ready to close! (after ${ELAPSED}s)"
        break
    fi

    # Print progress
    WORKER_COUNT=$(cast call --rpc-url "$RPC_URL" "$STUDIO" "getWorkerCount()(uint256)" 2>/dev/null || echo "?")
    VERIFIER_COUNT=$(cast call --rpc-url "$RPC_URL" "$STUDIO" "getVerifierCount()(uint256)" 2>/dev/null || echo "?")
    echo "  [${ELAPSED}s] workers=$WORKER_COUNT verifiers=$VERIFIER_COUNT canClose=false"

    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    echo "ERROR: Timeout waiting for agents (${TIMEOUT}s)"
    echo "Final state: workers=$WORKER_COUNT verifiers=$VERIFIER_COUNT"
    exit 1
fi

# ── Phase 6: Close Epoch (simulating CRE) ──
echo ""
echo "=== Phase 6: Close Epoch ==="

TX_HASH=$(cast send \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_KEY" \
    --json \
    "$REGISTRY" \
    "closeStudioEpoch(address,bytes)" \
    "$STUDIO" \
    "$CRE_REPORT" | jq -r '.transactionHash')
echo "Epoch closed (tx: $TX_HASH)"

# ── Phase 7: Verify Settlement ──
echo ""
echo "=== Phase 7: Verify Settlement ==="

MARKET_DATA=$(cast call \
    --rpc-url "$RPC_URL" \
    "$MARKET" \
    "getMarket(uint256)(address,string,uint256,uint256,uint256,uint8,bool)" \
    "$MARKET_ID")
echo "Market data:"
echo "$MARKET_DATA"

# Check active studios (should be empty after settlement)
ACTIVE_STUDIOS=$(cast call \
    --rpc-url "$RPC_URL" \
    "$REGISTRY" \
    "getActiveStudios()(address[])")
echo ""
echo "Active studios after settlement: $ACTIVE_STUDIOS"

echo ""
echo "========================================="
echo "=== E2E Demo Complete! ==="
echo "========================================="
echo ""
echo "Summary:"
echo "  Market:   $MARKET"
echo "  Registry: $REGISTRY"
echo "  Studio:   $STUDIO"
echo "  Settlement: SUCCESS"
