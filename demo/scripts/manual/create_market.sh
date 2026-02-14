#!/usr/bin/env bash
# Create a prediction market on ExamplePredictionMarket
#
# Usage:
#   ./create_market.sh "Will ETH reach $10,000 by end of 2025?" 1735689600
#
# Args:
#   $1 - Question string
#   $2 - Deadline (unix timestamp)
#   $3 - ETH value to send (default: 0.1)
#
# Required env:
#   DEPLOYER_PRIVATE_KEY - Wallet private key
#   PREDICTION_MARKET    - ExamplePredictionMarket contract address
#   SEPOLIA_RPC          - RPC endpoint

set -euo pipefail

QUESTION="${1:?Usage: ./create_market.sh <question> <deadline> [eth_value]}"
DEADLINE="${2:?Usage: ./create_market.sh <question> <deadline> [eth_value]}"
ETH_VALUE="${3:-0.1}"

: "${DEPLOYER_PRIVATE_KEY:?Set DEPLOYER_PRIVATE_KEY}"
: "${PREDICTION_MARKET:?Set PREDICTION_MARKET}"
: "${SEPOLIA_RPC:?Set SEPOLIA_RPC}"

echo "=== ChaosOracle: Create Prediction Market ==="
echo "Question: $QUESTION"
echo "Deadline: $DEADLINE ($(date -r "$DEADLINE" 2>/dev/null || echo 'N/A'))"
echo "Value:    $ETH_VALUE ETH (10% goes to settlement reward)"
echo "Market:   $PREDICTION_MARKET"
echo ""

# Encode function call: createMarket(string,uint256)
cast send \
    --rpc-url "$SEPOLIA_RPC" \
    --private-key "$DEPLOYER_PRIVATE_KEY" \
    --value "${ETH_VALUE}ether" \
    "$PREDICTION_MARKET" \
    "createMarket(string,uint256)(uint256)" \
    "$QUESTION" \
    "$DEADLINE"

echo ""
echo "Market created! Check the transaction on Sepolia Etherscan."
echo "Next: Users can place bets with ./place_bet.sh"
