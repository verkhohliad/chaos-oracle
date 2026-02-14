#!/usr/bin/env bash
# Check the settlement status of a prediction market
#
# Usage:
#   ./check_settlement.sh <market_id>
#
# Required env:
#   PREDICTION_MARKET    - ExamplePredictionMarket contract address
#   REGISTRY_ADDRESS     - ChaosOracleRegistry contract address
#   SEPOLIA_RPC          - RPC endpoint

set -euo pipefail

MARKET_ID="${1:?Usage: ./check_settlement.sh <market_id>}"

: "${PREDICTION_MARKET:?Set PREDICTION_MARKET}"
: "${REGISTRY_ADDRESS:?Set REGISTRY_ADDRESS}"
: "${SEPOLIA_RPC:?Set SEPOLIA_RPC}"

echo "=== ChaosOracle: Check Settlement Status ==="
echo ""

# Get market details
echo "--- Market Details ---"
RESULT=$(cast call \
    --rpc-url "$SEPOLIA_RPC" \
    "$PREDICTION_MARKET" \
    "getMarket(uint256)(address,string,uint256,uint256,uint256,uint8,bool)" \
    "$MARKET_ID" 2>&1) || true

echo "$RESULT"
echo ""

# Check active studios
echo "--- Active Studios ---"
STUDIOS=$(cast call \
    --rpc-url "$SEPOLIA_RPC" \
    "$REGISTRY_ADDRESS" \
    "getActiveStudios()(address[])" 2>&1) || true

echo "Active studios: $STUDIOS"
echo ""

# Check ready markets
echo "--- Markets Ready for Settlement ---"
READY=$(cast call \
    --rpc-url "$SEPOLIA_RPC" \
    "$REGISTRY_ADDRESS" \
    "getMarketsReadyForSettlement()(bytes32[])" 2>&1) || true

echo "Ready market keys: $READY"
echo ""

# If studio exists, check if it can close
if [ -n "$STUDIOS" ] && [ "$STUDIOS" != "[]" ]; then
    echo "--- Studio Close Status ---"
    # Extract first studio address (rough parsing)
    STUDIO=$(echo "$STUDIOS" | tr -d '[]' | tr ',' '\n' | head -1 | tr -d ' ')
    if [ -n "$STUDIO" ]; then
        CAN_CLOSE=$(cast call \
            --rpc-url "$SEPOLIA_RPC" \
            "$REGISTRY_ADDRESS" \
            "canCloseStudio(address)(bool)" \
            "$STUDIO" 2>&1) || true
        echo "Studio $STUDIO canClose: $CAN_CLOSE"
    fi
fi

echo ""
echo "=== Summary ==="
echo "Market:   $PREDICTION_MARKET"
echo "Registry: $REGISTRY_ADDRESS"
echo "Network:  Sepolia"
