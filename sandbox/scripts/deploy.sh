#!/usr/bin/env bash
# Deploy ChaosOracle contracts.
#
# Works with both local Anvil fork (sandbox) and real Sepolia.
# CRE_FORWARDER is set to the deployer address so we can call
# onlyCRE functions directly (simulating CRE triggers manually).
#
# Writes deployed addresses to /shared/addresses.json for other containers.

set -euo pipefail

RPC_URL="${RPC_URL:?RPC_URL is required (Sepolia RPC endpoint)}"
SHARED_DIR="${SHARED_DIR:-/shared}"

DEPLOYER_KEY="${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY is required}"

# ── Real ChaosChain addresses on Sepolia ──
CHAOS_CORE="0xF6a57f04736A52a38b273b0204d636506a780E67"
STUDIO_PROXY_FACTORY="0x230e76a105A9737Ea801BB7d0624D495506EE257"
CHAOSCHAIN_REGISTRY="0x7F38C1aFFB24F30500d9174ed565110411E42d50"
REWARDS_DISTRIBUTOR="0x0549772a3fF4F095C57AEFf655B3ed97B7925C19"

# CRE_FORWARDER = Chainlink Keystone Forwarder on Sepolia.
# CRE writeReport routes txs through this contract. On an Anvil Sepolia fork
# the real Forwarder already exists at the forked state, so CRE simulator
# uses it directly (no mock deployment).
DEPLOYER_ADDRESS=$(cast wallet address "$DEPLOYER_KEY")
CRE_FORWARDER="0x15fc6ae953e024d975e77382eeec56a9101f9f88"

echo "=== ChaosOracle Sandbox Deployer ==="
echo "RPC:       $RPC_URL"
echo "Deployer:  $DEPLOYER_ADDRESS"
echo "CRE Fwd:   $CRE_FORWARDER (Keystone Forwarder on Sepolia)"
echo ""

# ── Check RPC connectivity ──
echo "Checking RPC connectivity..."
BLOCK_NUM=$(cast block-number --rpc-url "$RPC_URL" 2>/dev/null || true)
if [ -z "$BLOCK_NUM" ]; then
    echo "ERROR: Cannot reach RPC at $RPC_URL"
    exit 1
fi
echo "RPC connected. Current block: $BLOCK_NUM"

# ── Clear EIP-7702 delegations from Anvil default accounts ──
# The well-known Anvil mnemonic addresses may have EIP-7702 delegations
# on real Sepolia.  OpenZeppelin v5 _safeMint() checks code.length > 0
# and reverts with ERC721InvalidReceiver if the delegate contract doesn't
# implement IERC721Receiver.  Clearing the code restores them as pure EOAs.
echo ""
echo "=== Clearing EIP-7702 delegations from agent accounts ==="

AGENT_KEYS=(
    "${DEPLOYER_PRIVATE_KEY:-}"
    "${WORKER1_KEY:-}"
    "${WORKER2_KEY:-}"
    "${WORKER3_KEY:-}"
    "${VERIFIER1_KEY:-}"
    "${VERIFIER2_KEY:-}"
    "${VERIFIER3_KEY:-}"
    "${GATEWAY_SIGNER_KEY:-}"
)

for KEY in "${AGENT_KEYS[@]}"; do
    if [ -z "$KEY" ]; then continue; fi
    ADDR=$(cast wallet address "$KEY" 2>/dev/null || continue)
    CODE=$(cast code "$ADDR" --rpc-url "$RPC_URL" 2>/dev/null || echo "0x")
    if [ "$CODE" != "0x" ] && [ -n "$CODE" ]; then
        echo "  Clearing code from $ADDR (${#CODE} chars)"
        cast rpc anvil_setCode "$ADDR" "0x" --rpc-url "$RPC_URL" 2>/dev/null || true
    fi
done
echo "Done."

# ── Skip if already deployed AND contracts still exist on-chain ──
if [ -f "$SHARED_DIR/addresses.json" ]; then
    CACHED_REGISTRY=$(jq -r '.registry' "$SHARED_DIR/addresses.json")
    CODE=$(cast code "$CACHED_REGISTRY" --rpc-url "$RPC_URL" 2>/dev/null || echo "0x")
    if [ "$CODE" != "0x" ] && [ -n "$CODE" ]; then
        echo "=== Contracts still live — skipping deployment ==="
        cat "$SHARED_DIR/addresses.json"
        exit 0
    fi
    echo "=== Stale addresses.json — redeploying ==="
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

# ── Authorize deployer on Keystone Forwarder ──
# The CRE simulator signs reports with the deployer key and sends them to the
# Keystone Forwarder. The Forwarder checks isForwarder(signer) and silently
# drops reports from unauthorized signers. We impersonate the Forwarder owner
# and call addForwarder(deployer) so CRE reports get relayed to the Registry.
echo ""
echo "=== Authorizing deployer on Keystone Forwarder ==="

FORWARDER_OWNER=$(cast call --rpc-url "$RPC_URL" "$CRE_FORWARDER" "owner()(address)" 2>/dev/null || echo "")
echo "Forwarder owner: $FORWARDER_OWNER"

IS_AUTHORIZED=$(cast call --rpc-url "$RPC_URL" "$CRE_FORWARDER" "isForwarder(address)(bool)" "$DEPLOYER_ADDRESS" 2>/dev/null || echo "false")
echo "Deployer already authorized: $IS_AUTHORIZED"

if [ "$IS_AUTHORIZED" != "true" ] && [ -n "$FORWARDER_OWNER" ]; then
    echo "Impersonating Forwarder owner to add deployer..."
    cast rpc anvil_impersonateAccount "$FORWARDER_OWNER" --rpc-url "$RPC_URL" 2>/dev/null || true

    # Fund the owner for gas
    cast send --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" \
        --value 0.01ether --json "$FORWARDER_OWNER" > /dev/null 2>&1 || true

    ADD_TX=$(cast send --rpc-url "$RPC_URL" --from "$FORWARDER_OWNER" --unlocked --json \
        "$CRE_FORWARDER" "addForwarder(address)" "$DEPLOYER_ADDRESS" 2>&1 || echo "FAILED")

    if echo "$ADD_TX" | jq -e '.transactionHash' > /dev/null 2>&1; then
        IS_NOW=$(cast call --rpc-url "$RPC_URL" "$CRE_FORWARDER" "isForwarder(address)(bool)" "$DEPLOYER_ADDRESS")
        echo "Deployer authorized on Forwarder: $IS_NOW"
    else
        echo "WARNING: addForwarder failed: $ADD_TX"
    fi

    cast rpc anvil_stopImpersonatingAccount "$FORWARDER_OWNER" --rpc-url "$RPC_URL" 2>/dev/null || true
else
    echo "Deployer already authorized (or no Forwarder owner). Skipping."
fi

# ── Transfer RewardsDistributor ownership to gateway signer ──
# The gateway needs to be the RD owner to call registerWork(), registerValidator(),
# and closeEpoch() — all of which are onlyOwner.  On the Anvil fork the RD owner
# is the original Sepolia deployer, so we impersonate them to transfer ownership.
echo ""
echo "=== Transferring RewardsDistributor ownership to Gateway signer ==="

GATEWAY_SIGNER_KEY="${GATEWAY_SIGNER_KEY:-}"
if [ -n "$GATEWAY_SIGNER_KEY" ]; then
    GATEWAY_SIGNER_ADDR=$(cast wallet address "$GATEWAY_SIGNER_KEY")
else
    # Default: Anvil account 9
    GATEWAY_SIGNER_ADDR="0xa0Ee7A142d267C1f36714E4a8F75612F20a79720"
fi
echo "Gateway signer: $GATEWAY_SIGNER_ADDR"

RD_OWNER=$(cast call --rpc-url "$RPC_URL" "$REWARDS_DISTRIBUTOR" "owner()(address)" 2>/dev/null || echo "")
echo "Current RD owner: $RD_OWNER"

if [ -n "$RD_OWNER" ] && [ "$RD_OWNER" != "$GATEWAY_SIGNER_ADDR" ]; then
    echo "Impersonating RD owner to transfer ownership..."
    cast rpc anvil_impersonateAccount "$RD_OWNER" --rpc-url "$RPC_URL" 2>/dev/null || true

    # Fund the impersonated account for gas
    cast send --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" \
        --value 0.1ether --json "$RD_OWNER" > /dev/null 2>&1 || true

    # Transfer ownership to gateway signer
    TRANSFER_TX=$(cast send --rpc-url "$RPC_URL" --from "$RD_OWNER" --unlocked --json \
        "$REWARDS_DISTRIBUTOR" "transferOwnership(address)" "$GATEWAY_SIGNER_ADDR" 2>&1 || echo "FAILED")

    if echo "$TRANSFER_TX" | jq -e '.transactionHash' > /dev/null 2>&1; then
        NEW_OWNER=$(cast call --rpc-url "$RPC_URL" "$REWARDS_DISTRIBUTOR" "owner()(address)")
        echo "Ownership transferred! New RD owner: $NEW_OWNER"
    else
        echo "WARNING: Ownership transfer failed: $TRANSFER_TX"
        echo "  Gateway registerWork/registerValidator/closeEpoch calls may revert."
    fi

    cast rpc anvil_stopImpersonatingAccount "$RD_OWNER" --rpc-url "$RPC_URL" 2>/dev/null || true
else
    echo "RD already owned by gateway signer (or owner unknown). Skipping transfer."
fi

# ── Patch RewardsDistributor: remove onlyOwner for sandbox ──
# In production the gateway signer is the RD owner. In our sandbox, multiple
# agents share one gateway and each signs as themselves. Rather than modifying
# gateway code, we patch the RD bytecode to make registerWork(),
# registerValidator(), closeEpoch(), and setConsensusParameters() callable
# by anyone.  This is Anvil-only — never do this on a real network.
#
# How it works:
#   OpenZeppelin Ownable compiles _checkOwner() as a shared internal subroutine.
#   The subroutine loads the owner from storage slot 0, compares with msg.sender,
#   and reverts with OwnableUnauthorizedAccount(address) if they differ.
#   We find the unique OwnableUnauthorizedAccount selector (0x118cdaa7) in the
#   bytecode, trace back to the _checkOwner entry point, and replace the first
#   instruction after the JUMPDEST with a JUMP (0x56) that immediately returns
#   to the caller — effectively making _checkOwner() a no-op.
echo ""
echo "=== Patching RewardsDistributor (removing onlyOwner for sandbox) ==="

RD_CODE=$(cast code "$REWARDS_DISTRIBUTOR" --rpc-url "$RPC_URL" 2>/dev/null || echo "0x")

if [ "$RD_CODE" = "0x" ] || [ -z "$RD_CODE" ]; then
    echo "WARNING: No code at RewardsDistributor ($REWARDS_DISTRIBUTOR). Skipping patch."
else
    # Find the OwnableUnauthorizedAccount(address) error selector in hex
    # Selector: 0x118cdaa7 — appears exactly once in the revert block
    ERROR_SEL="118cdaa7"

    # The _checkOwner pattern (hex): PUSH0 SLOAD <addr-mask> AND CALLER SUB PUSH2 <dest> JUMPI JUMP
    # Specifically: 5f54 6001600160a01b03 16 33 03 61XXXX 57 56
    # We look for the PUSH0+SLOAD (5f54) that precedes the error selector
    CHECK_PATTERN="5f546001600160a01b031633"

    # Use python3 (available in the foundry image) to do the hex patching
    PATCHED=$(python3 -c "
import sys
bc = '$RD_CODE'[2:]  # strip 0x prefix
pattern = '$CHECK_PATTERN'
error = '$ERROR_SEL'

# Verify the error selector exists
if error not in bc:
    print('ERROR: OwnableUnauthorizedAccount selector not found in bytecode', file=sys.stderr)
    sys.exit(1)

# Find the _checkOwner pattern
pos = bc.find(pattern)
if pos < 0:
    print('ERROR: _checkOwner pattern not found in bytecode', file=sys.stderr)
    sys.exit(1)

# Replace the first byte of the check (PUSH0 at pos) with JUMP (0x56)
# This makes _checkOwner() immediately return to the caller
patched = bc[:pos] + '56' + bc[pos+2:]
print('0x' + patched)
" 2>&1)

    if echo "$PATCHED" | grep -q "^0x"; then
        cast rpc anvil_setCode "$REWARDS_DISTRIBUTOR" "$PATCHED" --rpc-url "$RPC_URL" 2>/dev/null
        echo "RewardsDistributor bytecode patched at $REWARDS_DISTRIBUTOR"
        echo "  _checkOwner() has been no-op'd (all onlyOwner functions are now open)"

        # Verify: try calling registerWork from the deployer (not the original owner)
        VERIFY_TX=$(cast send --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" --json \
            "$REWARDS_DISTRIBUTOR" \
            "registerWork(address,uint64,bytes32)" \
            "0x0000000000000000000000000000000000000001" 0 \
            "0x0000000000000000000000000000000000000000000000000000000000000000" \
            2>&1 || echo "FAILED")
        if echo "$VERIFY_TX" | jq -e '.status == "0x1"' > /dev/null 2>&1; then
            echo "  Verified: registerWork() callable by non-owner ✓"
        else
            echo "  WARNING: Verification failed — registerWork may still require owner"
        fi
    else
        echo "WARNING: Bytecode patching failed: $PATCHED"
        echo "  registerWork/registerValidator/closeEpoch may revert with OwnableUnauthorizedAccount."
    fi
fi

# ── Write addresses for other containers ──
# Record the current block number so event queries can use it as the starting
# point — avoids hitting Sepolia RPC free-tier eth_getLogs range limits when
# querying from block 0 on an Anvil fork.
DEPLOY_BLOCK=$(cast block-number --rpc-url "$RPC_URL" 2>/dev/null || echo "0")

mkdir -p "$SHARED_DIR"
cat > "$SHARED_DIR/addresses.json" <<EOF
{
    "registry": "$REGISTRY",
    "logicModule": "$LOGIC_MODULE",
    "market": "$MARKET",
    "deployer": "$DEPLOYER_ADDRESS",
    "gatewaySigner": "$GATEWAY_SIGNER_ADDR",
    "rewardsDistributor": "$REWARDS_DISTRIBUTOR",
    "rpcUrl": "$RPC_URL",
    "deployBlock": $DEPLOY_BLOCK
}
EOF

echo ""
echo "=== Deployment Complete ==="
echo "Addresses written to $SHARED_DIR/addresses.json"
cat "$SHARED_DIR/addresses.json"
