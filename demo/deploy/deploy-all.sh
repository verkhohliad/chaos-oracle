#!/usr/bin/env bash
# ============================================================================
# ChaosOracle Sepolia Deployment — Foundry Scripts
#
# Two-phase deployment using forge script:
#   Phase 1: ChaosChain core (ChaosChainRegistry, RewardsDistributor, ChaosCore)
#   Phase 2: ChaosOracle (PredictionSettlementLogic, ChaosOracleRegistry,
#            ExamplePredictionMarket) + registerLogicModule on ChaosCore
#
# Broadcast and verification are SEPARATE steps:
#   - Broadcast must succeed (pipeline dies if it fails)
#   - Verification is non-blocking (retryable separately)
#   - Addresses are read from forge's broadcast JSON, not vm.writeJson
#
# Flags:
#   --skip-phase1   Skip ChaosChain deployment (use existing broadcast JSON)
#
# Prerequisites:
#   - DEPLOYER_PRIVATE_KEY with Sepolia ETH
#   - SEPOLIA_RPC (Alchemy/Infura endpoint)
#   - ETHERSCAN_API_KEY (optional, for contract verification)
#   - foundry (forge, cast) installed
#   - jq installed
#
# Usage:
#   cd demo/deploy && ./deploy-all.sh
#   cd demo/deploy && ./deploy-all.sh --skip-phase1   # resume after Phase 1
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHAOSCHAIN_CONTRACTS="$ROOT_DIR/external/chaoschain/packages/contracts"
CHAOSORACLE_CONTRACTS="$ROOT_DIR/contracts"

# ── Parse flags ──
SKIP_PHASE1=false
for arg in "$@"; do
    case $arg in
        --skip-phase1) SKIP_PHASE1=true ;;
    esac
done

# ── Required env vars ──
: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY is required}"
: "${SEPOLIA_RPC:?SEPOLIA_RPC is required}"
ETHERSCAN_API_KEY="${ETHERSCAN_API_KEY:-}"
CHAIN_ID=11155111

DEPLOYER_ADDRESS=$(cast wallet address "$DEPLOYER_PRIVATE_KEY")

echo "============================================"
echo "  ChaosOracle Sepolia Deployment"
echo "============================================"
echo "Deployer:  $DEPLOYER_ADDRESS"
echo "RPC:       $SEPOLIA_RPC"
if [ "$SKIP_PHASE1" = true ]; then
    echo "Mode:      --skip-phase1 (resume from Phase 2)"
fi
echo ""

# Check connectivity
BLOCK_NUM=$(cast block-number --rpc-url "$SEPOLIA_RPC" 2>/dev/null || true)
if [ -z "$BLOCK_NUM" ]; then
    echo "ERROR: Cannot reach RPC at $SEPOLIA_RPC"
    exit 1
fi
echo "RPC connected. Current block: $BLOCK_NUM"

# Check deployer balance
BALANCE=$(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$SEPOLIA_RPC" --ether 2>/dev/null || echo "0")
echo "Deployer balance: $BALANCE ETH"
echo ""

# ── Existing Sepolia contracts (reuse, do not redeploy) ──
export STUDIO_PROXY_FACTORY="0x230e76a105A9737Ea801BB7d0624D495506EE257"
export IDENTITY_REGISTRY="0x8004A818BFB912233c491871b3d84c89A494BD9e"
export REPUTATION_REGISTRY="0x8004B663056A597Dffe9eCcC1965A193B7388713"
export VALIDATION_REGISTRY="0x8004CB39f29c09145F24Ad9dDe2A108C1A2cdfC5"
export CRE_FORWARDER="0x15fc6ae953e024d975e77382eeec56a9101f9f88"

ADDRESSES_FILE="$SCRIPT_DIR/addresses.sepolia.json"

# Helper: extract address from forge broadcast JSON
extract_address() {
    local broadcast_file="$1"
    local contract_name="$2"
    jq -r ".transactions[] | select(.contractName==\"$contract_name\" and .transactionType==\"CREATE\") | .contractAddress" "$broadcast_file" | head -1
}

# ===========================================================================
# PHASE 1: Deploy ChaosChain core contracts
# ===========================================================================
PHASE1_BROADCAST="$CHAOSCHAIN_CONTRACTS/broadcast/DeployChaosOracleCore.s.sol/$CHAIN_ID/run-latest.json"

if [ "$SKIP_PHASE1" = true ]; then
    echo "============================================"
    echo "  Phase 1: SKIPPED (--skip-phase1)"
    echo "============================================"
    if [ ! -f "$PHASE1_BROADCAST" ]; then
        echo "ERROR: --skip-phase1 specified but no broadcast JSON found at:"
        echo "  $PHASE1_BROADCAST"
        echo "Run without --skip-phase1 first."
        exit 1
    fi
    echo "Reading addresses from existing broadcast..."
else
    echo "============================================"
    echo "  Phase 1: ChaosChain Core Contracts"
    echo "============================================"
    echo ""

    cd "$CHAOSCHAIN_CONTRACTS"
    forge script script/DeployChaosOracleCore.s.sol \
        --rpc-url "$SEPOLIA_RPC" \
        --broadcast \
        --skip DeployFactoryCore \
        -vvv

    echo ""
    echo "Phase 1 broadcast complete."
fi

# Extract Phase 1 addresses from broadcast JSON
if [ ! -f "$PHASE1_BROADCAST" ]; then
    echo "ERROR: Broadcast JSON not found at $PHASE1_BROADCAST"
    exit 1
fi

export CHAOSCHAIN_REGISTRY=$(extract_address "$PHASE1_BROADCAST" "ChaosChainRegistry")
export REWARDS_DISTRIBUTOR=$(extract_address "$PHASE1_BROADCAST" "RewardsDistributor")
export CHAOS_CORE=$(extract_address "$PHASE1_BROADCAST" "ChaosCore")

if [ -z "$CHAOSCHAIN_REGISTRY" ] || [ -z "$REWARDS_DISTRIBUTOR" ] || [ -z "$CHAOS_CORE" ]; then
    echo "ERROR: Failed to extract addresses from Phase 1 broadcast"
    echo "  ChaosChainRegistry: ${CHAOSCHAIN_REGISTRY:-MISSING}"
    echo "  RewardsDistributor: ${REWARDS_DISTRIBUTOR:-MISSING}"
    echo "  ChaosCore:          ${CHAOS_CORE:-MISSING}"
    exit 1
fi

echo ""
echo "Phase 1 addresses:"
echo "  ChaosChainRegistry: $CHAOSCHAIN_REGISTRY"
echo "  RewardsDistributor: $REWARDS_DISTRIBUTOR"
echo "  ChaosCore:          $CHAOS_CORE"
echo ""

# ===========================================================================
# PHASE 2: Deploy ChaosOracle contracts + register logic module
# ===========================================================================
echo "============================================"
echo "  Phase 2: ChaosOracle Contracts"
echo "============================================"
echo ""

cd "$CHAOSORACLE_CONTRACTS"
forge script script/DeployAll.s.sol \
    --rpc-url "$SEPOLIA_RPC" \
    --broadcast \
    -vvv

echo ""
echo "Phase 2 broadcast complete."

# Extract Phase 2 addresses from broadcast JSON
PHASE2_BROADCAST="$CHAOSORACLE_CONTRACTS/broadcast/DeployAll.s.sol/$CHAIN_ID/run-latest.json"

if [ ! -f "$PHASE2_BROADCAST" ]; then
    echo "ERROR: Phase 2 broadcast JSON not found at $PHASE2_BROADCAST"
    exit 1
fi

ORACLE_REGISTRY=$(extract_address "$PHASE2_BROADCAST" "ChaosOracleRegistry")
LOGIC_MODULE=$(extract_address "$PHASE2_BROADCAST" "PredictionSettlementLogic")
MARKET=$(extract_address "$PHASE2_BROADCAST" "ExamplePredictionMarket")

echo ""
echo "Phase 2 addresses:"
echo "  PredictionSettlementLogic: $LOGIC_MODULE"
echo "  ChaosOracleRegistry:      $ORACLE_REGISTRY"
echo "  ExamplePredictionMarket:   $MARKET"
echo ""

# ===========================================================================
# Write combined addresses file
# ===========================================================================
DEPLOY_BLOCK=$(cast block-number --rpc-url "$SEPOLIA_RPC" 2>/dev/null || echo "0")

cat > "$ADDRESSES_FILE" <<EOF
{
    "network": "sepolia",
    "chainId": $CHAIN_ID,
    "deployBlock": $DEPLOY_BLOCK,
    "deployer": "$DEPLOYER_ADDRESS",
    "chaoschain": {
        "chaosChainRegistry": "$CHAOSCHAIN_REGISTRY",
        "chaosCore": "$CHAOS_CORE",
        "rewardsDistributor": "$REWARDS_DISTRIBUTOR",
        "studioProxyFactory": "$STUDIO_PROXY_FACTORY",
        "identityRegistry": "$IDENTITY_REGISTRY",
        "reputationRegistry": "$REPUTATION_REGISTRY",
        "validationRegistry": "$VALIDATION_REGISTRY"
    },
    "chaosoracle": {
        "chaosOracleRegistry": "$ORACLE_REGISTRY",
        "predictionSettlementLogic": "$LOGIC_MODULE",
        "examplePredictionMarket": "$MARKET",
        "creForwarder": "$CRE_FORWARDER"
    }
}
EOF

echo "============================================"
echo "  Deployment Complete"
echo "============================================"
echo ""
echo "Addresses written to: $ADDRESSES_FILE"
echo ""
cat "$ADDRESSES_FILE"
echo ""

# ===========================================================================
# Etherscan verification (non-blocking)
# ===========================================================================
if [ -n "$ETHERSCAN_API_KEY" ]; then
    echo "============================================"
    echo "  Etherscan Verification (non-blocking)"
    echo "============================================"
    echo ""

    echo "Verifying Phase 1 contracts..."
    cd "$CHAOSCHAIN_CONTRACTS"
    forge script script/DeployChaosOracleCore.s.sol \
        --rpc-url "$SEPOLIA_RPC" \
        --verify --resume \
        --skip DeployFactoryCore \
        --etherscan-api-key "$ETHERSCAN_API_KEY" \
        2>&1 || echo "WARNING: Phase 1 verification incomplete. Retry with: forge verify-contract"
    echo ""

    echo "Verifying Phase 2 contracts..."
    cd "$CHAOSORACLE_CONTRACTS"
    forge script script/DeployAll.s.sol \
        --rpc-url "$SEPOLIA_RPC" \
        --verify --resume \
        --etherscan-api-key "$ETHERSCAN_API_KEY" \
        2>&1 || echo "WARNING: Phase 2 verification incomplete. Retry with: forge verify-contract"
    echo ""
fi

echo "============================================"
echo "  Next Steps"
echo "============================================"
echo ""
echo "  1. Deploy CRE workflow:"
echo "     cd cre-workflow/settlement-workflow && cre workflow deploy . --target sepolia-settings"
echo ""
echo "  2. Set workflow ID:"
echo "     cd $CHAOSORACLE_CONTRACTS && \\"
echo "       REGISTRY=$ORACLE_REGISTRY CRE_WORKFLOW_ID=<WORKFLOW_ID> \\"
echo "       forge script script/PostDeploy.s.sol --sig 'setWorkflowId()' --rpc-url \$SEPOLIA_RPC --broadcast"
echo ""
echo "  3. Start services:"
echo "     cd demo/run && docker compose -f docker-compose.sepolia.yml up --build"
echo ""
echo "  4. Run demo:"
echo "     cd demo/run && ./orchestrate-sepolia.sh"
