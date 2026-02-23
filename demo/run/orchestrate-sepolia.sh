#!/usr/bin/env bash
# ============================================================================
# ChaosOracle Sepolia Demo — Orchestration Script (runs in Docker)
#
# Creates a prediction market, places bets, triggers CRE workflows via
# cre-runner container, monitors worker/verifier activity, and settles.
#
# This runs inside a Foundry container with docker.sock mounted.
# CRE triggers are executed via `docker exec` into the cre-runner container.
#
# Usage:
#   docker compose up --build orchestrator   (from demo/run/)
# ============================================================================
set -euo pipefail

# ── Required env vars ──
: "${RPC_URL:?RPC_URL is required}"
: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY is required}"
: "${CHAOSORACLE_REGISTRY_ADDRESS:?CHAOSORACLE_REGISTRY_ADDRESS is required}"
: "${EXAMPLE_MARKET_ADDRESS:?EXAMPLE_MARKET_ADDRESS is required}"
: "${REWARDS_DISTRIBUTOR_ADDRESS:?REWARDS_DISTRIBUTOR_ADDRESS is required}"
: "${CRE_RUNNER_CONTAINER:?CRE_RUNNER_CONTAINER is required}"

RPC="$RPC_URL"
REGISTRY="$CHAOSORACLE_REGISTRY_ADDRESS"
MARKET="$EXAMPLE_MARKET_ADDRESS"
REWARDS_DIST="$REWARDS_DISTRIBUTOR_ADDRESS"
DEPLOYER_KEY="$DEPLOYER_PRIVATE_KEY"

DEPLOYER_ADDRESS=$(cast wallet address "$DEPLOYER_KEY")

# Optional agent keys for betting
WORKER_1_KEY="${WORKER_1_PRIVATE_KEY:-}"
WORKER_2_KEY="${WORKER_2_PRIVATE_KEY:-}"

# Timing
DEADLINE_OFFSET=120  # 2 mins

# ── Helpers ──
log_header() {
    echo ""
    echo "============================================"
    echo "  $1"
    echo "============================================"
    echo ""
}

log_kv() {
    printf "    %-24s %s\n" "$1:" "$2"
}

# Clean cast output: strip "[...]" suffix and quotes
clean_val() {
    echo "$1" | awk '{print $1}' | tr -d '"'
}

# ═══════════════════════════════════════════════════════════════════
# Phase 0: Initialization
# ═══════════════════════════════════════════════════════════════════
log_header "Phase 0: Initialization"

BLOCK_NUM=$(cast block-number --rpc-url "$RPC")
log_kv "Deployer" "$DEPLOYER_ADDRESS"
log_kv "Registry" "$REGISTRY"
log_kv "Market" "$MARKET"
log_kv "RewardsDistributor" "$REWARDS_DIST"
log_kv "CRE Runner" "$CRE_RUNNER_CONTAINER"
log_kv "Current block" "$BLOCK_NUM"
SCAN_FROM_BLOCK="$BLOCK_NUM"

# Verify CRE runner is available
if ! docker exec "$CRE_RUNNER_CONTAINER" echo "ok" > /dev/null 2>&1; then
    echo "ERROR: Cannot reach CRE runner container '$CRE_RUNNER_CONTAINER'"
    exit 1
fi
echo "    CRE runner container: OK"

# Patch CRE config with current addresses and fromBlock
SCAN_FROM_HEX=$(printf "0x%x" "$SCAN_FROM_BLOCK")
echo "    Patching CRE config (fromBlock=$SCAN_FROM_HEX)..."
docker exec "$CRE_RUNNER_CONTAINER" sh -c "
  cd /app/settlement-workflow && \
  jq --arg r '$REGISTRY' --arg rd '$REWARDS_DIST' --arg fb '$SCAN_FROM_HEX' --arg ds '$DEPLOYER_ADDRESS' \
    '.registryAddress = \$r | .rewardsDistributorAddress = \$rd | .fromBlock = \$fb | .defaultSignerAddress = \$ds' config.sepolia.json > /tmp/cfg.json && \
  mv /tmp/cfg.json config.sepolia.json
" 2>&1

# Verify config patch
CONFIG_REGISTRY=$(docker exec "$CRE_RUNNER_CONTAINER" sh -c \
    "jq -r '.registryAddress' /app/settlement-workflow/config.sepolia.json" 2>/dev/null)
log_kv "CRE config registry" "$CONFIG_REGISTRY"

# ═══════════════════════════════════════════════════════════════════
# Phase 1: Create Prediction Market
# ═══════════════════════════════════════════════════════════════════
log_header "Phase 1: Create Prediction Market"

#QUESTION="Will Bitcoin exceed \$100,000 by end of 2026?"
QUESTION="Will Elon Musk post something about DOGE coin in X on 15 Feb 2026?"
DEADLINE=$(($(date +%s) + DEADLINE_OFFSET))
CREATION_VALUE="0.01ether"

log_kv "Question" "$QUESTION"
log_kv "Deadline" "$(date -d @$DEADLINE 2>/dev/null || echo "$DEADLINE")"
log_kv "Value" "$CREATION_VALUE"

MARKET_TX=$(cast send --rpc-url "$RPC" --private-key "$DEPLOYER_KEY" \
    "$MARKET" \
    "createMarket(string,uint256)" \
    "$QUESTION" \
    "$DEADLINE" \
    --value "$CREATION_VALUE" \
    --json 2>&1 | jq -r '.transactionHash')

log_kv "Market tx" "$MARKET_TX"

# Get market ID
MARKET_ID_RAW=$(cast call --rpc-url "$RPC" "$MARKET" "nextMarketId()(uint256)")
MARKET_ID=$(( $(clean_val "$MARKET_ID_RAW") - 1 ))
log_kv "Market ID" "$MARKET_ID"

# ═══════════════════════════════════════════════════════════════════
# Phase 2: Place Bets
# ═══════════════════════════════════════════════════════════════════
log_header "Phase 2: Place Bets"

BET_AMOUNT="0.005ether"

if [ -n "$WORKER_1_KEY" ]; then
    BETTOR1_ADDR=$(cast wallet address "$WORKER_1_KEY")
    echo "    Bettor 1 ($BETTOR1_ADDR) bets YES ($BET_AMOUNT)..."
    cast send --rpc-url "$RPC" --private-key "$WORKER_1_KEY" \
        "$MARKET" "placeBet(uint256,uint8)" "$MARKET_ID" "0" \
        --value "$BET_AMOUNT" --json > /dev/null 2>&1 || echo "    (bet failed)"
fi

if [ -n "$WORKER_2_KEY" ]; then
    BETTOR2_ADDR=$(cast wallet address "$WORKER_2_KEY")
    echo "    Bettor 2 ($BETTOR2_ADDR) bets NO ($BET_AMOUNT)..."
    cast send --rpc-url "$RPC" --private-key "$WORKER_2_KEY" \
        "$MARKET" "placeBet(uint256,uint8)" "$MARKET_ID" "1" \
        --value "$BET_AMOUNT" --json > /dev/null 2>&1 || echo "    (bet failed)"
fi

echo "    Bets placed."

# ═══════════════════════════════════════════════════════════════════
# Phase 3: Wait for Deadline
# ═══════════════════════════════════════════════════════════════════
log_header "Phase 3: Waiting for Deadline"

NOW=$(date +%s)
WAIT=$((DEADLINE - NOW))
if [ "$WAIT" -gt 0 ]; then
    echo "    Waiting ${WAIT}s for deadline to pass..."
    sleep "$WAIT"
    # Extra buffer for block confirmations
    sleep 15
fi
echo "    Deadline passed."

# Verify market is ready for settlement
READY_KEYS=$(cast call --rpc-url "$RPC" "$REGISTRY" "getMarketsReadyForSettlement()(bytes32[])" 2>/dev/null || echo "[]")
echo "    Markets ready: $READY_KEYS"
MARKET_KEY=$(echo "$READY_KEYS" | sed 's/\[//;s/\]//' | tr ',' '\n' | head -1 | xargs)

if [ -z "$MARKET_KEY" ] || [ "${#MARKET_KEY}" -lt 66 ]; then
    echo "    WARNING: No ready markets found. Market may not have registered correctly."
    echo "    Continuing anyway..."
fi

# ═══════════════════════════════════════════════════════════════════
# Phase 4: Create Studio (CRE Trigger 0 — onCheckDeadlines)
# ═══════════════════════════════════════════════════════════════════
log_header "Phase 4: Create Studio (CRE Trigger 0)"

echo "    Running CRE trigger 0 (onCheckDeadlines) via cre-runner..."

docker exec "$CRE_RUNNER_CONTAINER" sh -c "
  cd /app && \
  cre workflow simulate ./settlement-workflow --target sepolia-settings --broadcast --non-interactive --trigger-index 0 --engine-logs 2>&1
" 2>&1 | tee /tmp/cre-trigger0.log
CRE_EXIT=${PIPESTATUS[0]}

if [ "$CRE_EXIT" -ne 0 ]; then
    echo "    WARNING: CRE trigger 0 failed (exit=$CRE_EXIT)"
    echo "    Check /tmp/cre-trigger0.log for details"
    echo "    Continuing to poll for studio creation..."
fi

# Wait for Sepolia confirmations
echo "    Waiting for block confirmations..."
sleep 30

# Read studio address
STUDIO=""
if [ -n "${MARKET_KEY:-}" ] && [ "${#MARKET_KEY}" -ge 66 ]; then
    STUDIO=$(cast call --rpc-url "$RPC" "$REGISTRY" "keyToStudio(bytes32)(address)" "$MARKET_KEY" 2>/dev/null || echo "")
fi

# Fallback: poll getActiveStudios
if [ -z "$STUDIO" ] || [ "$STUDIO" = "0x0000000000000000000000000000000000000000" ]; then
    echo "    Polling for studio creation..."
    for i in $(seq 1 30); do
        STUDIOS=$(cast call --rpc-url "$RPC" "$REGISTRY" "getActiveStudios()(address[])" 2>/dev/null || echo "[]")
        if [ "$STUDIOS" != "[]" ] && [ -n "$STUDIOS" ]; then
            STUDIO=$(echo "$STUDIOS" | tr -d '[]' | tr ',' '\n' | tail -1 | tr -d ' ')
            if [ -n "$STUDIO" ] && [ "$STUDIO" != "0x0000000000000000000000000000000000000000" ]; then
                break
            fi
        fi
        echo "    Polling... ($i/30)"
        sleep 10
    done
fi

if [ -z "$STUDIO" ] || [ "$STUDIO" = "0x0000000000000000000000000000000000000000" ]; then
    echo "    ERROR: No studio created after CRE trigger 0."
    exit 1
fi

log_kv "Studio" "$STUDIO"

# ═══════════════════════════════════════════════════════════════════
# Phase 5a: Monitor Worker Submissions
# ═══════════════════════════════════════════════════════════════════
log_header "Phase 5a: Monitoring Worker Submissions"

MIN_WORKERS=2
# NOTE: Uses eth_call (getEpochWork) instead of eth_getLogs (cast logs) because
# Alchemy free tier limits eth_getLogs to 10-block range, which breaks when
# polling over minutes. eth_call has no block range restriction.
WORK_HASHES=""
for i in $(seq 1 60); do
    WORK_HASHES=$(cast call --rpc-url "$RPC" "$REWARDS_DIST" \
        "getEpochWork(address,uint64)(bytes32[])" "$STUDIO" 1 2>/dev/null || echo "[]")

    # Count non-empty hex entries (each 0x... is one work hash)
    WORK_COUNT=0
    if [ "$WORK_HASHES" != "[]" ] && [ -n "$WORK_HASHES" ]; then
        WORK_COUNT=$(echo "$WORK_HASHES" | tr ',' '\n' | grep -c '0x' 2>/dev/null || echo "0")
    fi
    echo "    Workers submitted: $WORK_COUNT (need $MIN_WORKERS, poll $i/60)"

    if [ "$WORK_COUNT" -ge "$MIN_WORKERS" ]; then
        echo "    Sufficient worker submissions."
        break
    fi

    sleep 15
done

# ═══════════════════════════════════════════════════════════════════
# Phase 5b: Monitor Verifier Scores
# ═══════════════════════════════════════════════════════════════════
log_header "Phase 5b: Monitoring Verifier Scores"

# 2 workers x 2 verifiers = 4 score submissions minimum
MIN_SCORES=4
# NOTE: Uses eth_call (getWorkValidators) instead of eth_getLogs because
# Alchemy free tier limits eth_getLogs to 10-block range.
for i in $(seq 1 60); do
    TOTAL_SCORES=0
    if [ "$WORK_HASHES" != "[]" ] && [ -n "$WORK_HASHES" ]; then
        for HASH in $(echo "$WORK_HASHES" | tr -d '[]' | tr ',' '\n' | tr -d ' '); do
            if [ -z "$HASH" ]; then continue; fi
            VALIDATORS=$(cast call --rpc-url "$RPC" "$REWARDS_DIST" \
                "getWorkValidators(bytes32)(address[])" "$HASH" 2>/dev/null || echo "[]")
            V_COUNT=0
            if [ "$VALIDATORS" != "[]" ] && [ -n "$VALIDATORS" ]; then
                V_COUNT=$(echo "$VALIDATORS" | tr ',' '\n' | grep -c '0x' 2>/dev/null || echo "0")
            fi
            TOTAL_SCORES=$((TOTAL_SCORES + V_COUNT))
        done
    fi
    SCORE_COUNT=$TOTAL_SCORES
    echo "    Score submissions: $SCORE_COUNT (need $MIN_SCORES, poll $i/60)"

    if [ "$SCORE_COUNT" -ge "$MIN_SCORES" ]; then
        echo "    Sufficient score submissions."
        break
    fi

    sleep 15
done

# ═══════════════════════════════════════════════════════════════════
# Phase 6: Close Epoch
# ═══════════════════════════════════════════════════════════════════
log_header "Phase 6: Close Epoch"

# Try CRE trigger 2 (onReadyToClose) — checks readiness and closes epoch via Gateway
echo "    Running CRE trigger 2 (onReadyToClose) via cre-runner..."

docker exec "$CRE_RUNNER_CONTAINER" sh -c "
  cd /app && \
  cre workflow simulate ./settlement-workflow --target sepolia-settings --broadcast --non-interactive --trigger-index 2 --engine-logs 2>&1
" 2>&1 | tee /tmp/cre-trigger2.log
CRE_EXIT2=${PIPESTATUS[0]}

if [ "$CRE_EXIT2" -ne 0 ]; then
    echo "    CRE trigger 2 failed. Attempting manual epoch close..."
    cast send --rpc-url "$RPC" --private-key "$DEPLOYER_KEY" \
        "$REWARDS_DIST" \
        "closeEpoch(address,uint64)" "$STUDIO" "1" \
        --json 2>/dev/null | jq -r '.transactionHash' || echo "    (manual closeEpoch also failed)"
fi

# Wait for EpochClosed event
echo "    Waiting for EpochClosed event..."
EPOCH_CLOSED_TX_HASH=""
EPOCH_CLOSED_LOG_INDEX="0"

# NOTE: Uses a sliding 10-block window for eth_getLogs because
# Alchemy free tier limits queries to 10-block range.
for i in $(seq 1 30); do
    CURRENT_BLOCK=$(cast block-number --rpc-url "$RPC" 2>/dev/null || echo "0")
    WINDOW_FROM=$((CURRENT_BLOCK - 10))
    if [ "$WINDOW_FROM" -lt 0 ]; then WINDOW_FROM=0; fi
    EPOCH_EVENTS=$(cast logs --rpc-url "$RPC" \
        --from-block "$WINDOW_FROM" \
        --address "$REWARDS_DIST" \
        "EpochClosed(address,uint64,uint256,uint256)" --json 2>/dev/null || echo "[]")

    if [ "$EPOCH_EVENTS" != "[]" ] && echo "$EPOCH_EVENTS" | jq -e '.[0]' > /dev/null 2>&1; then
        EPOCH_CLOSED_TX_HASH=$(echo "$EPOCH_EVENTS" | jq -r '.[0].transactionHash')
        EPOCH_CLOSED_LOG_INDEX=$(echo "$EPOCH_EVENTS" | jq -r '.[0].logIndex' | python3 -c "import sys; print(int(sys.stdin.read().strip(), 16))" 2>/dev/null || echo "0")
        log_kv "EpochClosed tx" "$EPOCH_CLOSED_TX_HASH"
        log_kv "EpochClosed logIndex" "$EPOCH_CLOSED_LOG_INDEX"
        break
    fi

    echo "    Waiting for EpochClosed... ($i/30)"
    sleep 10
done

if [ -z "$EPOCH_CLOSED_TX_HASH" ]; then
    echo "    ERROR: No EpochClosed event detected after 5 minutes."
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════
# Phase 7: Settle Market (CRE Trigger 1 — onEpochClosed)
# ═══════════════════════════════════════════════════════════════════
log_header "Phase 7: Settle Market (CRE Trigger 1)"

echo "    Running CRE trigger 1 (onEpochClosed) to read finalized scores and settle..."
log_kv "EpochClosed tx" "$EPOCH_CLOSED_TX_HASH"

docker exec "$CRE_RUNNER_CONTAINER" sh -c "
  cd /app && \
  cre workflow simulate ./settlement-workflow --target sepolia-settings --broadcast --non-interactive --trigger-index 1 --evm-tx-hash $EPOCH_CLOSED_TX_HASH --evm-event-index $EPOCH_CLOSED_LOG_INDEX --engine-logs 2>&1
" 2>&1 | tee /tmp/cre-trigger1.log
CRE_EXIT1=${PIPESTATUS[0]}

if [ "$CRE_EXIT1" -ne 0 ]; then
    echo "    WARNING: CRE trigger 1 failed (exit=$CRE_EXIT1)"
    echo "    Check /tmp/cre-trigger1.log for details"
fi

# Wait for settlement confirmation
sleep 15

# ═══════════════════════════════════════════════════════════════════
# Phase 8: Results
# ═══════════════════════════════════════════════════════════════════
log_header "Phase 8: Results"

log_kv "Studio" "$STUDIO"
log_kv "Market ID" "$MARKET_ID"

# Check settlement state
IS_SETTLED=$(cast call --rpc-url "$RPC" "$MARKET" \
    "markets(uint256)(string,string[],uint256,bool,uint256,uint256,bool,uint256,bytes32)" "$MARKET_ID" 2>/dev/null || echo "unknown")
echo ""
echo "    Market state:"
echo "    $IS_SETTLED"

# Check canCloseStudio (false = settled)
CAN_CLOSE=$(cast call --rpc-url "$RPC" "$REGISTRY" "canCloseStudio(address)(bool)" "$STUDIO" 2>/dev/null || echo "unknown")
log_kv "canCloseStudio" "$CAN_CLOSE (false = settled)"

echo ""
log_header "Demo Complete!"

echo "    Next steps:"
echo "      - Claim winnings: cast send --rpc-url \$SEPOLIA_RPC --private-key <key> $MARKET 'claimWinnings(uint256)' $MARKET_ID"
echo "      - Check reputation: cast call --rpc-url \$SEPOLIA_RPC 0x8004B8FD1A363aa02fDC07635C0c5F94f6Af5B7E 'getReputation(address,string)(int128,uint8)' <agent> 'prediction-settlement'"
echo ""
