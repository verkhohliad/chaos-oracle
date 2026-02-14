#!/usr/bin/env bash
# Deploy ChaosOracle contracts on an anvil Sepolia fork.
#
# Key difference from production: CRE_FORWARDER is set to the deployer address
# so we can call onlyCRE functions directly (simulating CRE triggers manually).
#
# Writes deployed addresses to /shared/addresses.json for other containers.

set -euo pipefail

RPC_URL="${RPC_URL:-http://anvil:8545}"
SHARED_DIR="${SHARED_DIR:-/shared}"

# ── Anvil default accounts (mnemonic: test test test test test test test test test test test junk) ──
DEPLOYER_KEY="${DEPLOYER_PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

# ── Real ChaosChain addresses on Sepolia (available on the fork) ──
CHAOS_CORE="0xF6a57f04736A52a38b273b0204d636506a780E67"
STUDIO_PROXY_FACTORY="0x230e76a105A9737Ea801BB7d0624D495506EE257"
CHAOSCHAIN_REGISTRY="0x7F38C1aFFB24F30500d9174ed565110411E42d50"
REWARDS_DISTRIBUTOR="0x0549772a3fF4F095C57AEFf655B3ed97B7925C19"

# CRE_FORWARDER = deployer address (so deployer can call onlyCRE functions)
DEPLOYER_ADDRESS=$(cast wallet address "$DEPLOYER_KEY")
CRE_FORWARDER="$DEPLOYER_ADDRESS"

echo "=== ChaosOracle Demo Deployer ==="
echo "RPC:       $RPC_URL"
echo "Deployer:  $DEPLOYER_ADDRESS"
echo "CRE Fwd:   $CRE_FORWARDER (= deployer, for local testing)"
echo ""

# ── Wait for anvil ──
/app/scripts/wait-for-anvil.sh "$RPC_URL" 60

# ── Skip if already deployed AND contracts still exist on-chain ──
if [ -f "$SHARED_DIR/addresses.json" ]; then
    CACHED_REGISTRY=$(jq -r '.registry' "$SHARED_DIR/addresses.json")
    CODE=$(cast code "$CACHED_REGISTRY" --rpc-url "$RPC_URL" 2>/dev/null || echo "0x")
    if [ "$CODE" != "0x" ] && [ -n "$CODE" ]; then
        echo "=== Contracts still live — skipping deployment ==="
        cat "$SHARED_DIR/addresses.json"
        exit 0
    fi
    echo "=== Stale addresses.json (anvil restarted) — redeploying ==="
    rm -f "$SHARED_DIR/addresses.json"
fi

# ── Deploy PredictionSettlementLogic ──
echo "Deploying PredictionSettlementLogic..."
LOGIC_RESULT=$(forge create \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_KEY" \
    --json \
    --broadcast \
    src/PredictionSettlementLogic.sol:PredictionSettlementLogic)
LOGIC_MODULE=$(echo "$LOGIC_RESULT" | jq -r '.deployedTo')
if [ -z "$LOGIC_MODULE" ] || [ "$LOGIC_MODULE" = "null" ]; then
    echo "ERROR: Failed to deploy PredictionSettlementLogic"
    echo "forge output: $LOGIC_RESULT"
    exit 1
fi
echo "  PredictionSettlementLogic: $LOGIC_MODULE"

# ── Deploy ChaosOracleRegistry ──
echo "Deploying ChaosOracleRegistry..."
REGISTRY_RESULT=$(forge create \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_KEY" \
    --json \
    --broadcast \
    src/ChaosOracleRegistry.sol:ChaosOracleRegistry \
    --constructor-args \
        "$CHAOS_CORE" \
        "$LOGIC_MODULE" \
        "$CRE_FORWARDER" \
        "$STUDIO_PROXY_FACTORY" \
        "$CHAOSCHAIN_REGISTRY" \
        "$REWARDS_DISTRIBUTOR")
REGISTRY=$(echo "$REGISTRY_RESULT" | jq -r '.deployedTo')
if [ -z "$REGISTRY" ] || [ "$REGISTRY" = "null" ]; then
    echo "ERROR: Failed to deploy ChaosOracleRegistry"
    echo "forge output: $REGISTRY_RESULT"
    exit 1
fi
echo "  ChaosOracleRegistry: $REGISTRY"

# ── Deploy ExamplePredictionMarket ──
echo "Deploying ExamplePredictionMarket..."
MARKET_RESULT=$(forge create \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_KEY" \
    --json \
    --broadcast \
    src/example/ExamplePredictionMarket.sol:ExamplePredictionMarket \
    --constructor-args "$REGISTRY")
MARKET=$(echo "$MARKET_RESULT" | jq -r '.deployedTo')
if [ -z "$MARKET" ] || [ "$MARKET" = "null" ]; then
    echo "ERROR: Failed to deploy ExamplePredictionMarket"
    echo "forge output: $MARKET_RESULT"
    exit 1
fi
echo "  ExamplePredictionMarket: $MARKET"

# ── Write addresses for other containers ──
mkdir -p "$SHARED_DIR"
cat > "$SHARED_DIR/addresses.json" <<EOF
{
    "registry": "$REGISTRY",
    "logicModule": "$LOGIC_MODULE",
    "market": "$MARKET",
    "deployer": "$DEPLOYER_ADDRESS",
    "rpcUrl": "$RPC_URL"
}
EOF

echo ""
echo "=== Deployment Complete ==="
echo "Addresses written to $SHARED_DIR/addresses.json"
cat "$SHARED_DIR/addresses.json"
