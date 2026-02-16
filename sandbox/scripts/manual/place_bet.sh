#!/usr/bin/env bash
# Place a bet on a prediction market
#
# Usage:
#   ./place_bet.sh <market_id> <option> <eth_value>
#
# Args:
#   $1 - Market ID (uint256)
#   $2 - Option: 0 = Yes, 1 = No
#   $3 - ETH value to bet
#
# Required env:
#   DEPLOYER_PRIVATE_KEY - Wallet private key
#   PREDICTION_MARKET    - ExamplePredictionMarket contract address
#   SEPOLIA_RPC          - RPC endpoint

set -euo pipefail

MARKET_ID="${1:?Usage: ./place_bet.sh <market_id> <option> <eth_value>}"
OPTION="${2:?Usage: ./place_bet.sh <market_id> <option> <eth_value>}"
ETH_VALUE="${3:?Usage: ./place_bet.sh <market_id> <option> <eth_value>}"

: "${DEPLOYER_PRIVATE_KEY:?Set DEPLOYER_PRIVATE_KEY}"
: "${PREDICTION_MARKET:?Set PREDICTION_MARKET}"
: "${SEPOLIA_RPC:?Set SEPOLIA_RPC}"

OPTION_NAME="Yes"
if [ "$OPTION" = "1" ]; then
    OPTION_NAME="No"
fi

echo "=== ChaosOracle: Place Bet ==="
echo "Market ID: $MARKET_ID"
echo "Betting:   $ETH_VALUE ETH on $OPTION_NAME (option $OPTION)"
echo "Market:    $PREDICTION_MARKET"
echo ""

cast send \
    --rpc-url "$SEPOLIA_RPC" \
    --private-key "$DEPLOYER_PRIVATE_KEY" \
    --value "${ETH_VALUE}ether" \
    "$PREDICTION_MARKET" \
    "placeBet(uint256,uint8)" \
    "$MARKET_ID" \
    "$OPTION"

echo ""
echo "Bet placed! After the deadline, CRE will trigger settlement."
