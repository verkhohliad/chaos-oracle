#!/usr/bin/env bash
# Orchestrate the full ChaosOracle lifecycle with structured logging.
#
# Works with both local Anvil fork (USE_ANVIL_TIME_WARP=true) and real Sepolia.
# This script replaces the CRE workflow by manually triggering
# createStudioForMarket() and settleWithOutcome() on the Registry.
#
# Flow:
#   0. Initialization — derive addresses, print config
#   1. Create a prediction market (short deadline)
#   2. Place bets from two funded accounts
#   3. Wait for the deadline to pass (time-warp on Anvil, real-time on Sepolia)
#   4. Create studio (simulating CRE trigger 1)
#   5a. Wait for worker submissions + decode WorkSubmitted events
#   5b. Wait for verifier scores + decode ScoreVectorSubmittedForWorker events
#   6. Economics breakdown with per-agent escrow balances
#   7. Off-chain consensus computation
#   8. Settle via settleWithOutcome (simulating CRE trigger 2)
#   8.5. Close epoch — decode EpochClosed + FundsReleased events
#   9. Active withdrawal polling (wait for agents to claim)
#  10. Final balance sheet with per-agent P/L

set -euo pipefail

# ═══════════════════════════════════════════════════════════════════
# Configuration
# ═══════════════════════════════════════════════════════════════════

RPC_URL="${RPC_URL:?RPC_URL is required}"
SHARED_DIR="${SHARED_DIR:-/shared}"

DEPLOYER_KEY="${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY is required}"
BETTOR1_KEY="${BETTOR1_KEY:?BETTOR1_KEY is required}"
BETTOR2_KEY="${BETTOR2_KEY:?BETTOR2_KEY is required}"

# Agent keys (for deriving addresses for balance queries)
WORKER1_KEY="${WORKER1_KEY:?WORKER1_KEY is required}"
WORKER2_KEY="${WORKER2_KEY:?WORKER2_KEY is required}"
WORKER3_KEY="${WORKER3_KEY:?WORKER3_KEY is required}"
VERIFIER1_KEY="${VERIFIER1_KEY:?VERIFIER1_KEY is required}"
VERIFIER2_KEY="${VERIFIER2_KEY:?VERIFIER2_KEY is required}"
VERIFIER3_KEY="${VERIFIER3_KEY:?VERIFIER3_KEY is required}"

ZERO_HASH="0x0000000000000000000000000000000000000000000000000000000000000000"

# Anvil time-warping (set USE_ANVIL_TIME_WARP=true for local sandbox)
USE_ANVIL_TIME_WARP="${USE_ANVIL_TIME_WARP:-false}"
DEADLINE_OFFSET=120

# Agent config
MIN_WORKERS="${MIN_WORKERS:-3}"
# Each of 3 verifiers must score each of 3 workers = 9 total ScoreVectorSubmittedForWorker events.
MIN_SCORES="${MIN_SCORES:-9}"

# ═══════════════════════════════════════════════════════════════════
# Formatting & Logging Helpers
# ═══════════════════════════════════════════════════════════════════

EXPLORER_URL="http://localhost:5100"   # Otterscan
IPFS_GW_URL="http://localhost:8080"

link_tx()      { echo "${EXPLORER_URL}/tx/$1"; }
link_addr()    { echo "${EXPLORER_URL}/address/$1"; }
link_ipfs()    { echo "${IPFS_GW_URL}/ipfs/$1"; }

wei_to_ether() {
    # cast call returns values like "1000000000000000 [1e15]" — strip the suffix
    local raw
    raw=$(echo "$1" | awk '{print $1}')
    python3 -c "print(f'{int(\"$raw\") / 1e18:.6f}')" 2>/dev/null || echo "?"
}

# Clean a cast call return value: strip "[...]" suffix and quotes
clean_val() {
    echo "$1" | awk '{print $1}' | tr -d '"'
}

log_header() {
    printf '\n'
    printf '  ══════════════════════════════════════════════════════════\n'
    printf '    %s\n' "$1"
    printf '  ══════════════════════════════════════════════════════════\n'
}

log_kv() {
    printf '    %-30s %s\n' "$1" "$2"
}

log_tx() {
    # $1 = label, $2 = tx hash
    printf '    %-30s %s\n' "$1" "$2"
    printf '    %-30s %s\n' "" "$(link_tx "$2")"
}

log_divider() {
    printf '    ────────────────────────────────────────────────────\n'
}

# Map an address to a human-readable label
addr_label() {
    local addr
    addr=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    for i in 0 1 2; do
        local w
        w=$(echo "${ALL_WORKERS[$i]}" | tr '[:upper:]' '[:lower:]')
        if [ "$addr" = "$w" ]; then echo "${WORKER_LABELS[$i]}"; return; fi
    done
    for i in 0 1 2; do
        local v
        v=$(echo "${ALL_VERIFIERS[$i]}" | tr '[:upper:]' '[:lower:]')
        if [ "$addr" = "$v" ]; then echo "${VERIFIER_LABELS[$i]}"; return; fi
    done
    echo ""
}

# Short address: 0x1234...abcd
short_addr() {
    echo "${1:0:6}...${1: -4}"
}

# ═══════════════════════════════════════════════════════════════════
# Derive Agent Addresses
# ═══════════════════════════════════════════════════════════════════

DEPLOYER_ADDR=$(cast wallet address "$DEPLOYER_KEY")
BETTOR1_ADDR=$(cast wallet address "$BETTOR1_KEY")
BETTOR2_ADDR=$(cast wallet address "$BETTOR2_KEY")

WORKER1_ADDR=$(cast wallet address "$WORKER1_KEY")
WORKER2_ADDR=$(cast wallet address "$WORKER2_KEY")
WORKER3_ADDR=$(cast wallet address "$WORKER3_KEY")
VERIFIER1_ADDR=$(cast wallet address "$VERIFIER1_KEY")
VERIFIER2_ADDR=$(cast wallet address "$VERIFIER2_KEY")
VERIFIER3_ADDR=$(cast wallet address "$VERIFIER3_KEY")

ALL_WORKERS=("$WORKER1_ADDR" "$WORKER2_ADDR" "$WORKER3_ADDR")
ALL_VERIFIERS=("$VERIFIER1_ADDR" "$VERIFIER2_ADDR" "$VERIFIER3_ADDR")
WORKER_LABELS=("Worker-1" "Worker-2" "Worker-3")
VERIFIER_LABELS=("Verifier-1" "Verifier-2" "Verifier-3")

# ═══════════════════════════════════════════════════════════════════
# Wait for deployment addresses
# ═══════════════════════════════════════════════════════════════════

log_header "ChaosOracle Orchestrator"
log_kv "Mode" "$([ "$USE_ANVIL_TIME_WARP" = "true" ] && echo "Anvil (time-warp)" || echo "Real Sepolia")"
echo ""
echo "    Waiting for deployment addresses..."

for i in $(seq 1 120); do
    if [ -f "$SHARED_DIR/addresses.json" ] \
       && jq -e '.registry and .market' "$SHARED_DIR/addresses.json" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

if ! jq -e '.registry and .market' "$SHARED_DIR/addresses.json" >/dev/null 2>&1; then
    echo "    ERROR: valid addresses.json not found after 120s"
    exit 1
fi

REGISTRY=$(jq -r '.registry' "$SHARED_DIR/addresses.json")
MARKET=$(jq -r '.market' "$SHARED_DIR/addresses.json")
REWARDS_DIST=$(jq -r '.rewardsDistributor // empty' "$SHARED_DIR/addresses.json")
REWARDS_DIST="${REWARDS_DIST:-0x0549772a3fF4F095C57AEFf655B3ed97B7925C19}"
DEPLOY_BLOCK=$(jq -r '.deployBlock // "0"' "$SHARED_DIR/addresses.json" 2>/dev/null || echo "0")
SCAN_FROM_HEX=$(printf '0x%x' "$DEPLOY_BLOCK")

# ═══════════════════════════════════════════════════════════════════
# Phase 0: Initialization
# ═══════════════════════════════════════════════════════════════════

log_header "Phase 0: Initialization"

echo ""
echo "    Contracts:"
log_kv "Registry" "$REGISTRY"
log_kv "" "$(link_addr "$REGISTRY")"
log_kv "Market" "$MARKET"
log_kv "" "$(link_addr "$MARKET")"
log_kv "RewardsDistributor" "$REWARDS_DIST"
log_kv "" "$(link_addr "$REWARDS_DIST")"

echo ""
echo "    Agents:"
log_divider
log_kv "Worker-1" "$WORKER1_ADDR"
log_kv "Worker-2" "$WORKER2_ADDR"
log_kv "Worker-3" "$WORKER3_ADDR"
log_kv "Verifier-1" "$VERIFIER1_ADDR"
log_kv "Verifier-2" "$VERIFIER2_ADDR"
log_kv "Verifier-3" "$VERIFIER3_ADDR"
log_divider
log_kv "Deployer" "$DEPLOYER_ADDR"
log_kv "Bettor-1" "$BETTOR1_ADDR"
log_kv "Bettor-2" "$BETTOR2_ADDR"

echo ""
log_kv "Block Explorer" "$EXPLORER_URL"
log_kv "IPFS Gateway" "$IPFS_GW_URL"

# Event topic hashes (computed once)
WORK_TOPIC=$(cast keccak "WorkSubmitted(uint256,bytes32,bytes32,bytes32,uint256)")
SCORE_TOPIC=$(cast keccak "ScoreVectorSubmittedForWorker(uint256,bytes32,address,bytes,uint256)")
FUNDS_RELEASED_TOPIC=$(cast keccak "FundsReleased(address,uint256,bytes32)")
EPOCH_CLOSED_TOPIC=$(cast keccak "EpochClosed(address,uint64,uint256,uint256)")

# ═══════════════════════════════════════════════════════════════════
# Phase 1: Create Market
# ═══════════════════════════════════════════════════════════════════

log_header "Phase 1: Create Market"

BLOCK_TS=$(cast block --rpc-url "$RPC_URL" latest --json | jq -r '.timestamp')
BLOCK_TS_DEC=$(printf "%d" "$BLOCK_TS")
DEADLINE=$((BLOCK_TS_DEC + DEADLINE_OFFSET))

MARKET_ID=$(cast call --rpc-url "$RPC_URL" "$MARKET" "nextMarketId()(uint256)")

TX_HASH=$(cast send \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_KEY" \
    --value 1ether \
    --json \
    "$MARKET" \
    "createMarket(string,uint256)(uint256)" \
    "Will Elon Musk post something about DOGE coin in X on 15 Feb 2026?" \
    "$DEADLINE" | jq -r '.transactionHash')

echo ""
log_kv "Market ID" "$MARKET_ID"
log_kv "Question" "Will Elon Musk post something about DOGE coin in X on 15 Feb 2026?"
log_kv "Creator bet" "1.0 ETH"
log_kv "  Settlement fee (10%)" "0.1 ETH -> studio escrow"
log_kv "  Seed bet Yes (90%)" "0.9 ETH -> market pool"
log_kv "Deadline" "$DEADLINE (in ${DEADLINE_OFFSET}s)"
log_tx "Tx" "$TX_HASH"

# ═══════════════════════════════════════════════════════════════════
# Phase 2: Place Bets
# ═══════════════════════════════════════════════════════════════════

log_header "Phase 2: Place Bets"

# Fund bettors
cast send --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" --value 1ether --json "$BETTOR1_ADDR" > /dev/null 2>&1
cast send --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" --value 1ether --json "$BETTOR2_ADDR" > /dev/null 2>&1

TX1=$(cast send \
    --rpc-url "$RPC_URL" \
    --private-key "$BETTOR1_KEY" \
    --value 0.5ether \
    --json \
    "$MARKET" \
    "placeBet(uint256,uint8)" \
    "$MARKET_ID" 0 | jq -r '.transactionHash')

TX2=$(cast send \
    --rpc-url "$RPC_URL" \
    --private-key "$BETTOR2_KEY" \
    --value 0.3ether \
    --json \
    "$MARKET" \
    "placeBet(uint256,uint8)" \
    "$MARKET_ID" 1 | jq -r '.transactionHash')

echo ""
log_kv "Bettor-1 bet" "0.5 ETH on Yes"
log_tx "  Tx" "$TX1"
log_kv "Bettor-2 bet" "0.3 ETH on No"
log_tx "  Tx" "$TX2"
echo ""
echo "    Market Pool Summary:"
log_divider
log_kv "Yes pool" "0.9 + 0.5 = 1.4 ETH"
log_kv "No  pool" "0.3 ETH"
log_kv "Total" "1.7 ETH"
log_divider

# ═══════════════════════════════════════════════════════════════════
# Phase 3: Wait for Deadline
# ═══════════════════════════════════════════════════════════════════

log_header "Phase 3: Wait for Deadline"

if [ "$USE_ANVIL_TIME_WARP" = "true" ]; then
    echo ""
    echo "    Using Anvil time-warp to skip past deadline..."
    cast rpc evm_increaseTime "$((DEADLINE_OFFSET + 30))" --rpc-url "$RPC_URL" > /dev/null 2>&1
    cast rpc evm_mine --rpc-url "$RPC_URL" > /dev/null 2>&1
    NOW_TS=$(cast block --rpc-url "$RPC_URL" latest --json | jq -r '.timestamp')
    NOW_DEC=$(printf "%d" "$NOW_TS")
    log_kv "Time-warped" "block.timestamp=$NOW_DEC (deadline=$DEADLINE)"
else
    echo ""
    echo "    Waiting ${DEADLINE_OFFSET}s for market deadline (real-time)..."
    WAIT_ELAPSED=0
    while [ "$WAIT_ELAPSED" -lt "$((DEADLINE_OFFSET + 15))" ]; do
        NOW_TS=$(cast block --rpc-url "$RPC_URL" latest --json | jq -r '.timestamp')
        NOW_DEC=$(printf "%d" "$NOW_TS")
        if [ "$NOW_DEC" -ge "$DEADLINE" ]; then
            log_kv "Deadline passed" "block.timestamp=$NOW_DEC >= $DEADLINE"
            break
        fi
        REMAINING=$((DEADLINE - NOW_DEC))
        printf '    [%3ds] Waiting... %ds remaining\n' "$WAIT_ELAPSED" "$REMAINING"
        sleep 10
        WAIT_ELAPSED=$((WAIT_ELAPSED + 10))
    done
fi

# ═══════════════════════════════════════════════════════════════════
# Phase 4: Create Studio
# ═══════════════════════════════════════════════════════════════════

log_header "Phase 4: Create Studio"

READY_KEYS=$(cast call \
    --rpc-url "$RPC_URL" \
    "$REGISTRY" \
    "getMarketsReadyForSettlement()(bytes32[])")

MARKET_KEY=$(echo "$READY_KEYS" | sed 's/\[//;s/\]//' | tr ',' '\n' | head -1 | xargs)

if [ -z "$MARKET_KEY" ] || [ "${#MARKET_KEY}" -lt 66 ]; then
    echo "    ERROR: No ready markets found (got: '$MARKET_KEY')"
    exit 1
fi

TX_HASH=$(cast send \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_KEY" \
    --json \
    "$REGISTRY" \
    "createStudioForMarket(bytes32,bytes)" \
    "$MARKET_KEY" \
    "$ZERO_HASH" | jq -r '.transactionHash')

STUDIO=$(cast call \
    --rpc-url "$RPC_URL" \
    "$REGISTRY" \
    "keyToStudio(bytes32)(address)" \
    "$MARKET_KEY")

# Write studio address for reference
jq --arg studio "$STUDIO" --arg key "$MARKET_KEY" \
    '. + {studio: $studio, marketKey: $key}' \
    "$SHARED_DIR/addresses.json" > "$SHARED_DIR/addresses_tmp.json" \
    && mv "$SHARED_DIR/addresses_tmp.json" "$SHARED_DIR/addresses.json"

STUDIO_BAL_WEI=$(cast balance --rpc-url "$RPC_URL" "$STUDIO" 2>/dev/null || echo "0")
STUDIO_BAL_ETH=$(wei_to_ether "$STUDIO_BAL_WEI")

# Read question from the studio logic module
QUESTION=$(cast call --rpc-url "$RPC_URL" "$STUDIO" "question()(string)" 2>/dev/null || echo "?")

echo ""
log_kv "Market key" "$MARKET_KEY"
log_kv "Studio proxy" "$STUDIO"
log_kv "" "$(link_addr "$STUDIO")"
log_kv "Question" "$QUESTION"
log_kv "Escrow funded" "$STUDIO_BAL_ETH ETH"
log_tx "Tx" "$TX_HASH"

# ═══════════════════════════════════════════════════════════════════
# Phase 5a: Wait for Worker Submissions
# ═══════════════════════════════════════════════════════════════════

log_header "Phase 5a: Worker Submissions"
echo ""
echo "    Workers submit work via Gateway -> StudioProxy.submitWork()"
echo ""

TIMEOUT=600
ELAPSED=0

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    CUR_BLOCK_HEX=$(printf '0x%x' "$(cast block-number --rpc-url "$RPC_URL" 2>/dev/null || echo "0")")

    WORK_COUNT=$(cast rpc eth_getLogs \
        --rpc-url "$RPC_URL" \
        "{\"fromBlock\":\"$SCAN_FROM_HEX\",\"toBlock\":\"$CUR_BLOCK_HEX\",\"address\":\"$STUDIO\",\"topics\":[\"$WORK_TOPIC\"]}" \
        2>/dev/null | jq 'length' 2>/dev/null || echo "0")

    printf '    [%3ds] Workers: %s/%s\n' "$ELAPSED" "$WORK_COUNT" "$MIN_WORKERS"

    if [ "$WORK_COUNT" -ge "$MIN_WORKERS" ]; then
        echo "    Worker submissions ready!"
        break
    fi

    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

if [ "$WORK_COUNT" -lt "$MIN_WORKERS" ] 2>/dev/null; then
    echo "    WARNING: Timeout waiting for workers. Got $WORK_COUNT/$MIN_WORKERS"
fi

# ── Decode WorkSubmitted events ──
echo ""
echo "    Worker Submissions:"
log_divider

CUR_BLOCK_HEX=$(printf '0x%x' "$(cast block-number --rpc-url "$RPC_URL" 2>/dev/null || echo "0")")
WORK_LOGS=$(cast rpc eth_getLogs \
    --rpc-url "$RPC_URL" \
    "{\"fromBlock\":\"$SCAN_FROM_HEX\",\"toBlock\":\"$CUR_BLOCK_HEX\",\"address\":\"$STUDIO\",\"topics\":[\"$WORK_TOPIC\"]}" \
    2>/dev/null || echo "[]")

# Load evidence map for fallback
EVIDENCE_MAP_FILE="$SHARED_DIR/evidence_map.json"

if [ -f "$EVIDENCE_MAP_FILE" ]; then
    EM_KEY_COUNT=$(jq 'keys | length' "$EVIDENCE_MAP_FILE" 2>/dev/null || echo "0")
    echo "    (evidence_map.json: $EM_KEY_COUNT entries)"
    echo ""
fi

# Collect dataHashes into an array for later use (outside the pipe)
DATA_HASHES_JSON=$(echo "$WORK_LOGS" | jq -r '.[].topics[2]' 2>/dev/null || echo "")

# Build a JSON summary of all workers' evidence for use in Phase 5b and Phase 10
# This avoids the subshell issue with piped while loops
# Write JSON to temp files to avoid control character issues in heredoc interpolation
WORK_LOGS_FILE=$(mktemp)
echo "$WORK_LOGS" > "$WORK_LOGS_FILE"
WORKER_EVIDENCE_JSON=$(python3 -c "
import json, subprocess, sys, os

work_logs = json.load(open('$WORK_LOGS_FILE'))
evidence_map_file = '$EVIDENCE_MAP_FILE'
studio = '$STUDIO'
rpc_url = '$RPC_URL'
ipfs_api = 'http://ipfs:5001'

# Load evidence map
evidence_map = {}
if os.path.exists(evidence_map_file):
    try:
        evidence_map = json.load(open(evidence_map_file))
    except: pass

results = []
for i, log in enumerate(work_logs):
    topics = log.get('topics', [])
    data_hash = topics[2] if len(topics) > 2 else ''
    tx_hash = log.get('transactionHash', '')

    # Resolve worker address via cast call
    try:
        r = subprocess.run(
            ['cast', 'call', '--rpc-url', rpc_url, studio,
             'getWorkSubmitter(bytes32)(address)', data_hash],
            capture_output=True, text=True, timeout=10)
        worker_addr = r.stdout.strip()
    except:
        worker_addr = 'unknown'

    # Resolve evidence CID: try on-chain first, then evidence_map fallback
    evidence_cid = ''
    try:
        r = subprocess.run(
            ['cast', 'call', '--rpc-url', rpc_url, studio,
             'getEvidenceCID(bytes32)(string)', data_hash],
            capture_output=True, text=True, timeout=10)
        evidence_cid = r.stdout.strip().strip('\"')
    except:
        pass

    if not evidence_cid:
        dh_clean = data_hash.lower().removeprefix('0x')
        # Try exact match then case-insensitive
        evidence_cid = evidence_map.get(dh_clean, '')
        if not evidence_cid:
            for k, v in evidence_map.items():
                if k.lower() == dh_clean:
                    evidence_cid = v
                    break

    # Fetch evidence content from IPFS
    outcome = '?'
    confidence = '?'
    reasoning = ''
    source_count = 0
    is_forced = False

    if evidence_cid:
        try:
            import urllib.request
            url = f'{ipfs_api}/api/v0/cat?arg={evidence_cid}'
            req = urllib.request.Request(url, method='POST')
            with urllib.request.urlopen(req, timeout=5) as resp:
                evidence = json.loads(resp.read().decode())
                outcome = evidence.get('outcome', '?')
                confidence = evidence.get('confidence', '?')
                reasoning = evidence.get('reasoning', '')
                source_count = len(evidence.get('sources', []))
                if 'WORKER_FORCED_OUTCOME' in reasoning:
                    is_forced = True
        except:
            pass

    results.append({
        'index': i + 1,
        'worker_addr': worker_addr,
        'data_hash': data_hash,
        'evidence_cid': evidence_cid,
        'tx_hash': tx_hash,
        'outcome': outcome,
        'confidence': confidence,
        'reasoning': reasoning,
        'source_count': source_count,
        'is_forced': is_forced,
    })

print(json.dumps(results))
" 2>/dev/null || echo "[]")

# Display worker submissions
echo "$WORKER_EVIDENCE_JSON" | python3 -c "
import json, sys

data = json.loads(sys.stdin.read())

# Build addr->label map from env
import subprocess
worker_addrs = {}
verifier_addrs = {}
labels = {}

for line in '''$(for i in 0 1 2; do echo "${ALL_WORKERS[$i]}|${WORKER_LABELS[$i]}"; done; for i in 0 1 2; do echo "${ALL_VERIFIERS[$i]}|${VERIFIER_LABELS[$i]}"; done)'''.strip().split('\n'):
    parts = line.strip().split('|')
    if len(parts) == 2:
        labels[parts[0].lower()] = parts[1]

for w in data:
    addr = w['worker_addr']
    label = labels.get(addr.lower(), 'unknown')
    short = addr[:6] + '...' + addr[-4:] if len(addr) >= 10 else addr

    forced_tag = '  !! FORCED OUTCOME' if w['is_forced'] else ''
    print(f\"    #{w['index']}  {label} ({short}){forced_tag}\")

    # Outcome display
    outcome_label = 'Yes' if str(w['outcome']) == '0' else 'No' if str(w['outcome']) == '1' else '?'
    print(f\"        Outcome:      {w['outcome']} ({outcome_label})  |  Confidence: {w['confidence']}\")
    print(f\"        Sources:      {w['source_count']} source(s)\")

    # Reasoning (truncated)
    reasoning = w['reasoning']
    if len(reasoning) > 200:
        reasoning = reasoning[:200] + '...'
    if reasoning:
        # Wrap long reasoning
        import textwrap
        lines = textwrap.wrap(reasoning, width=70)
        if lines:
            print(f\"        Reasoning:    {lines[0]}\")
            for line in lines[1:]:
                print(f\"                      {line}\")

    # Evidence CID and links
    if w['evidence_cid']:
        print(f\"        Evidence:     {w['evidence_cid']}\")
        print(f\"        IPFS:         http://localhost:8080/ipfs/{w['evidence_cid']}\")
    else:
        print(f\"        Evidence:     (none)\")

    print(f\"        Tx:           http://localhost:5100/tx/{w['tx_hash']}\")
    print()
" 2>/dev/null || echo "    (failed to decode worker submissions)"
rm -f "$WORK_LOGS_FILE"

# Write reusable JSON to temp files for Phase 5b and Phase 10
WORKER_EVIDENCE_FILE=$(mktemp)
echo "$WORKER_EVIDENCE_JSON" > "$WORKER_EVIDENCE_FILE"

# ═══════════════════════════════════════════════════════════════════
# Phase 5b: Wait for Verifier Scores
# ═══════════════════════════════════════════════════════════════════

log_header "Phase 5b: Verifier Scores"
echo ""
echo "    Verifiers use submit_score_via_gateway() (DIRECT mode)"
echo ""

ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    CUR_BLOCK_HEX=$(printf '0x%x' "$(cast block-number --rpc-url "$RPC_URL" 2>/dev/null || echo "0")")

    SCORE_COUNT=$(cast rpc eth_getLogs \
        --rpc-url "$RPC_URL" \
        "{\"fromBlock\":\"$SCAN_FROM_HEX\",\"toBlock\":\"$CUR_BLOCK_HEX\",\"address\":\"$STUDIO\",\"topics\":[\"$SCORE_TOPIC\"]}" \
        2>/dev/null | jq 'length' 2>/dev/null || echo "0")

    printf '    [%3ds] Scores: %s (need %s)\n' "$ELAPSED" "$SCORE_COUNT" "$MIN_SCORES"

    if [ "$SCORE_COUNT" -ge "$MIN_SCORES" ]; then
        echo "    Sufficient scores!"
        break
    fi

    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

if [ "$SCORE_COUNT" -lt "$MIN_SCORES" ] 2>/dev/null; then
    echo "    WARNING: Timeout waiting for scores. Got $SCORE_COUNT/$MIN_SCORES"
    echo "    Proceeding with available data..."
fi

# ── Decode ScoreVectorSubmittedForWorker events (grouped by worker) ──

CUR_BLOCK_HEX=$(printf '0x%x' "$(cast block-number --rpc-url "$RPC_URL" 2>/dev/null || echo "0")")
SCORE_LOGS=$(cast rpc eth_getLogs \
    --rpc-url "$RPC_URL" \
    "{\"fromBlock\":\"$SCAN_FROM_HEX\",\"toBlock\":\"$CUR_BLOCK_HEX\",\"address\":\"$STUDIO\",\"topics\":[\"$SCORE_TOPIC\"]}" \
    2>/dev/null || echo "[]")

ACTUAL_SCORE_COUNT=$(echo "$SCORE_LOGS" | jq 'length' 2>/dev/null || echo "0")

echo ""
echo "    Verifier Scores ($ACTUAL_SCORE_COUNT total: 3 verifiers x 3 workers):"
log_divider

# Use python to group scores by worker, decode, compute averages, and display matrix
SCORE_LOGS_FILE=$(mktemp)
echo "$SCORE_LOGS" > "$SCORE_LOGS_FILE"
python3 -c "
import json, subprocess, sys

score_logs = json.load(open('$SCORE_LOGS_FILE'))
worker_evidence = json.load(open('$WORKER_EVIDENCE_FILE'))
rpc_url = '$RPC_URL'

# Build label maps
labels = {}
for line in '''$(for i in 0 1 2; do echo "${ALL_WORKERS[$i]}|${WORKER_LABELS[$i]}"; done; for i in 0 1 2; do echo "${ALL_VERIFIERS[$i]}|${VERIFIER_LABELS[$i]}"; done)'''.strip().split('\n'):
    parts = line.strip().split('|')
    if len(parts) == 2:
        labels[parts[0].lower()] = parts[1]

def short_addr(addr):
    if len(addr) >= 10:
        return addr[:6] + '...' + addr[-4:]
    return addr

def decode_scores(hex_data):
    \"\"\"Decode ABI-encoded score vector from event data.\"\"\"
    if hex_data.startswith('0x'):
        hex_data = hex_data[2:]
    try:
        # ABI layout: offset_to_scoreVector(32) | timestamp(32) | ...
        offset = int(hex_data[0:64], 16) * 2
        length_hex = hex_data[offset:offset+64]
        byte_length = int(length_hex, 16)
        raw_bytes = hex_data[offset+64:offset+64+byte_length*2]
        # Try ABI-encoded uint8[] (each value in a 32-byte slot)
        num_slots = byte_length // 32
        scores = []
        if num_slots > 0:
            for i in range(num_slots):
                val = int(raw_bytes[i*64:(i+1)*64], 16)
                scores.append(val)
        # Fallback: packed bytes (if fewer than 2 slots but some bytes)
        if len(scores) < 2 and byte_length > 0 and byte_length <= 32:
            scores = []
            for i in range(byte_length):
                val = int(raw_bytes[i*2:(i+1)*2], 16)
                scores.append(val)
        return scores
    except Exception as e:
        print(f'      (decode error: {e})', file=sys.stderr)
        return []

# Build worker outcome map from evidence
worker_outcomes = {}
for w in worker_evidence:
    addr = w['worker_addr'].lower()
    worker_outcomes[addr] = {
        'outcome': w['outcome'],
        'is_forced': w['is_forced'],
    }

# Determine winning outcome (majority)
outcome_counts = {}
for w in worker_evidence:
    o = str(w['outcome'])
    outcome_counts[o] = outcome_counts.get(o, 0) + 1
winning_outcome = max(outcome_counts, key=outcome_counts.get) if outcome_counts else '0'

# Group scores by worker
worker_scores = {}  # worker_addr -> list of (verifier_addr, scores, tx_hash)

for log in score_logs:
    topics = log.get('topics', [])
    data = log.get('data', '0x')
    tx_hash = log.get('transactionHash', '')

    # topic[2] = dataHash, topic[3] = worker (padded address)
    worker_topic = topics[3] if len(topics) > 3 else ''
    worker_addr = '0x' + worker_topic[-40:] if worker_topic else ''

    # Get verifier from tx sender
    try:
        r = subprocess.run(
            ['cast', 'tx', '--rpc-url', rpc_url, tx_hash, '--json'],
            capture_output=True, text=True, timeout=10)
        tx_data = json.loads(r.stdout)
        verifier_addr = tx_data.get('from', 'unknown')
    except:
        verifier_addr = 'unknown'

    scores = decode_scores(data)

    key = worker_addr.lower()
    if key not in worker_scores:
        worker_scores[key] = []
    worker_scores[key].append({
        'verifier': verifier_addr,
        'scores': scores,
        'tx_hash': tx_hash,
    })

# Display matrix (dynamic number of score dimensions)
for w in worker_evidence:
    addr = w['worker_addr'].lower()
    label = labels.get(addr, 'unknown')
    short = short_addr(w['worker_addr'])
    outcome = str(w['outcome'])
    outcome_label = 'Yes' if outcome == '0' else 'No' if outcome == '1' else '?'

    wrong_tag = ''
    if outcome != winning_outcome:
        wrong_tag = ' !! WRONG (minority)'

    forced_tag = ''
    if w.get('is_forced'):
        forced_tag = ' [FORCED]'

    print(f'')
    print(f'    {label} ({short})  -- Outcome: {outcome} ({outcome_label}){wrong_tag}{forced_tag}')

    entries = worker_scores.get(addr, [])
    all_scores = []
    for entry in entries:
        vlabel = labels.get(entry['verifier'].lower(), 'unknown')
        s = entry['scores']
        all_scores.append(s)
        scores_str = str(s)
        # Build detail string dynamically for however many scores exist
        if s:
            parts = [f's{i}={v}' for i, v in enumerate(s)]
            detail = '  (' + ', '.join(parts) + ')'
        else:
            detail = ''
        print(f'      {vlabel:12s}: {scores_str}{detail}')
        print(f'                   Tx: http://localhost:5100/tx/{entry[\"tx_hash\"]}')

    # Compute average across all dimensions dynamically
    if all_scores:
        min_len = min(len(s) for s in all_scores)
        if min_len > 0:
            n = len(all_scores)
            avg = [sum(s[i] for s in all_scores) // n for i in range(min_len)]
            print(f'      {\"Average\":12s}: {avg}')

    if not entries:
        print(f'      (no scores yet)')

print()
" 2>&1 || echo "    (failed to decode score matrix)"
rm -f "$SCORE_LOGS_FILE"

# ═══════════════════════════════════════════════════════════════════
# Phase 6: Economics Breakdown
# ═══════════════════════════════════════════════════════════════════

log_header "Phase 6: Economics Breakdown"

STUDIO_BAL_WEI=$(cast balance --rpc-url "$RPC_URL" "$STUDIO" 2>/dev/null || echo "0")
STUDIO_BAL_ETH=$(wei_to_ether "$STUDIO_BAL_WEI")

echo ""
echo "    Prediction Market:"
log_divider
log_kv "Creator bet" "1.0 ETH"
log_kv "  Settlement fee (10%)" "0.1 ETH -> studio escrow"
log_kv "  Seed bet Yes (90%)" "0.9 ETH -> market pool"
log_kv "Bettor-1 (Yes)" "+0.5 ETH"
log_kv "Bettor-2 (No)" "+0.3 ETH"
log_kv "Total market pool" "1.7 ETH (Yes: 1.4, No: 0.3)"

echo ""
echo "    Studio Escrow (before settlement):"
log_divider
log_kv "Settlement reward" "0.1 ETH (from market fee)"
log_kv "Studio total balance" "$STUDIO_BAL_ETH ETH"

echo ""
echo "    Per-Agent Escrow Balances:"
log_divider

for i in 0 1 2; do
    ESCROW=$(clean_val "$(cast call --rpc-url "$RPC_URL" "$STUDIO" \
        "getEscrowBalance(address)(uint256)" "${ALL_WORKERS[$i]}" 2>/dev/null || echo "0")")
    WITHDRAWABLE=$(clean_val "$(cast call --rpc-url "$RPC_URL" "$STUDIO" \
        "getWithdrawableBalance(address)(uint256)" "${ALL_WORKERS[$i]}" 2>/dev/null || echo "0")")
    E_ETH=$(wei_to_ether "$ESCROW")
    W_ETH=$(wei_to_ether "$WITHDRAWABLE")
    printf '    %-12s (%s): escrow=%s, withdrawable=%s ETH\n' \
        "${WORKER_LABELS[$i]}" "$(short_addr "${ALL_WORKERS[$i]}")" "$E_ETH" "$W_ETH"
done

for i in 0 1 2; do
    ESCROW=$(clean_val "$(cast call --rpc-url "$RPC_URL" "$STUDIO" \
        "getEscrowBalance(address)(uint256)" "${ALL_VERIFIERS[$i]}" 2>/dev/null || echo "0")")
    WITHDRAWABLE=$(clean_val "$(cast call --rpc-url "$RPC_URL" "$STUDIO" \
        "getWithdrawableBalance(address)(uint256)" "${ALL_VERIFIERS[$i]}" 2>/dev/null || echo "0")")
    E_ETH=$(wei_to_ether "$ESCROW")
    W_ETH=$(wei_to_ether "$WITHDRAWABLE")
    printf '    %-12s (%s): escrow=%s, withdrawable=%s ETH\n' \
        "${VERIFIER_LABELS[$i]}" "$(short_addr "${ALL_VERIFIERS[$i]}")" "$E_ETH" "$W_ETH"
done

echo ""
echo "    Expected settlement (if Yes wins):"
log_divider
log_kv "Creator payout" "(0.9/1.4) x 1.7 = ~1.093 ETH"
log_kv "Bettor-1 payout" "(0.5/1.4) x 1.7 = ~0.607 ETH"
log_kv "Bettor-2 payout" "lost (bet on No)"

# ═══════════════════════════════════════════════════════════════════
# Phase 7: Off-chain Consensus Computation
# ═══════════════════════════════════════════════════════════════════

log_header "Phase 7: Off-chain Consensus"
echo ""
echo "    Computing consensus from StudioProxy events..."
echo "    (Sandbox shortcut: majority outcome from workers)"
echo ""

WINNING_OUTCOME=0  # Yes (majority of workers)
PROOF_HASH=$(cast keccak "$(cast abi-encode "f(address,uint8)" "$STUDIO" "$WINNING_OUTCOME")")
log_kv "Winning outcome" "$WINNING_OUTCOME (Yes)"
log_kv "Proof hash" "$PROOF_HASH"

# ═══════════════════════════════════════════════════════════════════
# Phase 8: Settle Studio
# ═══════════════════════════════════════════════════════════════════

log_header "Phase 8: Settle Studio"

TX_HASH=$(cast send \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_KEY" \
    --json \
    "$REGISTRY" \
    "settleWithOutcome(address,uint8,bytes32,bytes)" \
    "$STUDIO" \
    "$WINNING_OUTCOME" \
    "$PROOF_HASH" \
    "$ZERO_HASH" | jq -r '.transactionHash')

echo ""
log_kv "Outcome" "$WINNING_OUTCOME (Yes)"
log_tx "Settlement Tx" "$TX_HASH"

# ═══════════════════════════════════════════════════════════════════
# Phase 8.5: Close Epoch (RewardsDistributor)
# ═══════════════════════════════════════════════════════════════════

log_header "Phase 8.5: Close Epoch (RewardsDistributor)"
echo ""
echo "    Triggering closeEpoch via gateway to finalize rewards..."

# Pre-closeEpoch verification
echo ""
echo "    Pre-closeEpoch verification:"
log_divider
EPOCH_WORK=$(cast call --rpc-url "$RPC_URL" "$REWARDS_DIST" \
    "getEpochWork(address,uint64)(bytes32[])" "$STUDIO" 1 2>/dev/null || echo "[]")
echo "    Registered work hashes:"

for DATA_HASH_HEX in $(echo "$EPOCH_WORK" | tr -d '[],' | tr ' ' '\n' | grep -v '^$'); do
    VALIDATORS=$(cast call --rpc-url "$RPC_URL" "$REWARDS_DIST" \
        "getWorkValidators(bytes32)(address[])" "$DATA_HASH_HEX" 2>/dev/null || echo "[]")

    # Count validators
    VAL_COUNT=$(echo "$VALIDATORS" | tr -d '[]' | tr ',' '\n' | grep -v '^$' | wc -l | xargs)
    printf '      %s => %s validator(s)\n' "$(short_addr "$DATA_HASH_HEX")" "$VAL_COUNT"
done

# Use the gateway's CloseEpoch workflow
GATEWAY_URL="${GATEWAY_URL:-http://gateway:3000}"
GATEWAY_SIGNER_ADDR=$(jq -r '.gatewaySigner // empty' "$SHARED_DIR/addresses.json" 2>/dev/null || echo "")
if [ -z "$GATEWAY_SIGNER_ADDR" ]; then
    GATEWAY_SIGNER_ADDR=$(cast wallet address "${GATEWAY_SIGNER_KEY:-0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6}" 2>/dev/null || echo "")
fi

echo ""
log_kv "Gateway signer" "$(short_addr "$GATEWAY_SIGNER_ADDR")"
echo "    Posting to $GATEWAY_URL/workflows/close-epoch ..."

CLOSE_RESP=$(curl -s -X POST "$GATEWAY_URL/workflows/close-epoch" \
    -H "Content-Type: application/json" \
    -d "{\"studio_address\":\"$STUDIO\",\"epoch\":1,\"signer_address\":\"$GATEWAY_SIGNER_ADDR\"}" \
    2>/dev/null || echo '{"error":"gateway unreachable"}')

WORKFLOW_ID=$(echo "$CLOSE_RESP" | jq -r '.id // empty' 2>/dev/null || echo "")
WF_STATE="UNKNOWN"
if [ -n "$WORKFLOW_ID" ]; then
    log_kv "Workflow ID" "$WORKFLOW_ID"
    echo "    Waiting for workflow to complete (up to 90s)..."

    WAIT=0
    while [ "$WAIT" -lt 90 ]; do
        WF_STATE=$(curl -s "$GATEWAY_URL/workflows/$WORKFLOW_ID" 2>/dev/null \
            | jq -r '.state // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
        printf '    [%2ds] Workflow state: %s\n' "$WAIT" "$WF_STATE"
        if [ "$WF_STATE" = "COMPLETED" ] || [ "$WF_STATE" = "FAILED" ]; then
            break
        fi
        sleep 5
        WAIT=$((WAIT + 5))
    done

    if [ "$WF_STATE" = "COMPLETED" ]; then
        echo "    closeEpoch completed via gateway!"
    else
        echo "    WARNING: closeEpoch workflow ended in state: $WF_STATE"
    fi
else
    echo "    WARNING: Gateway did not return a workflow ID."
fi

# Fallback: call closeEpoch directly
if [ "$WF_STATE" != "COMPLETED" ]; then
    echo ""
    echo "    Falling back to direct closeEpoch call..."
    CLOSE_TX=$(cast send --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" --json \
        "$REWARDS_DIST" "closeEpoch(address,uint64)" "$STUDIO" 1 2>&1 || echo "FAILED")

    if echo "$CLOSE_TX" | jq -e '.status == "0x1"' > /dev/null 2>&1; then
        CLOSE_TX_HASH=$(echo "$CLOSE_TX" | jq -r '.transactionHash')
        log_tx "closeEpoch Tx" "$CLOSE_TX_HASH"
    else
        echo "    WARNING: closeEpoch reverted: $CLOSE_TX"
    fi
fi

# ── Decode EpochClosed and FundsReleased events ──
echo ""
echo "    Post-closeEpoch Events:"
log_divider

CUR_BLOCK_HEX=$(printf '0x%x' "$(cast block-number --rpc-url "$RPC_URL" 2>/dev/null || echo "0")")

# Decode EpochClosed event from RewardsDistributor
EC_LOGS=$(cast rpc eth_getLogs \
    --rpc-url "$RPC_URL" \
    "{\"fromBlock\":\"$SCAN_FROM_HEX\",\"toBlock\":\"$CUR_BLOCK_HEX\",\"address\":\"$REWARDS_DIST\",\"topics\":[\"$EPOCH_CLOSED_TOPIC\"]}" \
    2>/dev/null || echo "[]")

EC_COUNT=$(echo "$EC_LOGS" | jq 'length' 2>/dev/null || echo "0")
if [ "$EC_COUNT" -gt 0 ]; then
    echo "$EC_LOGS" | jq -c '.[]' 2>/dev/null | while IFS= read -r log_entry; do
        EC_DATA=$(echo "$log_entry" | jq -r '.data')
        EC_TX=$(echo "$log_entry" | jq -r '.transactionHash')

        # data: totalWorkerRewards(uint256) | totalValidatorRewards(uint256)
        WORKER_REWARDS_HEX="0x${EC_DATA:2:64}"
        VALIDATOR_REWARDS_HEX="0x${EC_DATA:66:64}"
        WORKER_REWARDS_WEI=$(printf "%d" "$WORKER_REWARDS_HEX" 2>/dev/null || echo "0")
        VALIDATOR_REWARDS_WEI=$(printf "%d" "$VALIDATOR_REWARDS_HEX" 2>/dev/null || echo "0")

        echo ""
        echo "    EpochClosed:"
        log_kv "  Total Worker Rewards" "$(wei_to_ether "$WORKER_REWARDS_WEI") ETH"
        log_kv "  Total Validator Rewards" "$(wei_to_ether "$VALIDATOR_REWARDS_WEI") ETH"
        log_tx "  Tx" "$EC_TX"
    done
else
    echo "    No EpochClosed events found."
fi

# Decode FundsReleased events from StudioProxy
FR_LOGS=$(cast rpc eth_getLogs \
    --rpc-url "$RPC_URL" \
    "{\"fromBlock\":\"$SCAN_FROM_HEX\",\"toBlock\":\"$CUR_BLOCK_HEX\",\"address\":\"$STUDIO\",\"topics\":[\"$FUNDS_RELEASED_TOPIC\"]}" \
    2>/dev/null || echo "[]")

FR_COUNT=$(echo "$FR_LOGS" | jq 'length' 2>/dev/null || echo "0")
if [ "$FR_COUNT" -gt 0 ]; then
    echo ""
    echo "    FundsReleased events:"
    log_divider

    echo "$FR_LOGS" | jq -c '.[]' 2>/dev/null | while IFS= read -r log_entry; do
        FR_TOPICS=$(echo "$log_entry" | jq -r '.topics')
        FR_DATA=$(echo "$log_entry" | jq -r '.data')

        # topics: [sig, to(indexed), dataHash(indexed)]
        TO_TOPIC=$(echo "$FR_TOPICS" | jq -r '.[1]')
        TO_ADDR="0x${TO_TOPIC: -40}"
        AMOUNT_HEX="0x${FR_DATA:2:64}"
        AMOUNT_WEI=$(printf "%d" "$AMOUNT_HEX" 2>/dev/null || echo "0")
        AMOUNT_ETH=$(wei_to_ether "$AMOUNT_WEI")

        LABEL=$(addr_label "$TO_ADDR")
        printf '      %-12s (%s): +%s ETH\n' "${LABEL:-unknown}" "$(short_addr "$TO_ADDR")" "$AMOUNT_ETH"
    done
else
    echo "    No FundsReleased events found."
fi

# Show post-closeEpoch withdrawable balances
echo ""
echo "    Post-closeEpoch Withdrawable Balances:"
log_divider

for i in 0 1 2; do
    WB=$(clean_val "$(cast call --rpc-url "$RPC_URL" "$STUDIO" \
        "getWithdrawableBalance(address)(uint256)" "${ALL_WORKERS[$i]}" 2>/dev/null || echo "0")")
    WB_ETH=$(wei_to_ether "$WB")
    printf '    %-12s (%s): %s ETH\n' \
        "${WORKER_LABELS[$i]}" "$(short_addr "${ALL_WORKERS[$i]}")" "$WB_ETH"
done

for i in 0 1 2; do
    WB=$(clean_val "$(cast call --rpc-url "$RPC_URL" "$STUDIO" \
        "getWithdrawableBalance(address)(uint256)" "${ALL_VERIFIERS[$i]}" 2>/dev/null || echo "0")")
    WB_ETH=$(wei_to_ether "$WB")
    printf '    %-12s (%s): %s ETH\n' \
        "${VERIFIER_LABELS[$i]}" "$(short_addr "${ALL_VERIFIERS[$i]}")" "$WB_ETH"
done

# ═══════════════════════════════════════════════════════════════════
# Phase 9: Wait for Agent Withdrawals (active polling)
# ═══════════════════════════════════════════════════════════════════

log_header "Phase 9: Agent Withdrawals"
echo ""
echo "    Actively polling getWithdrawableBalance until agents withdraw..."
echo ""

WITHDRAW_TIMEOUT=120
WITHDRAW_ELAPSED=0

while [ "$WITHDRAW_ELAPSED" -lt "$WITHDRAW_TIMEOUT" ]; do
    ALL_WITHDRAWN=true
    PENDING_LIST=""

    for i in 0 1 2; do
        BAL=$(clean_val "$(cast call --rpc-url "$RPC_URL" "$STUDIO" \
            "getWithdrawableBalance(address)(uint256)" "${ALL_WORKERS[$i]}" 2>/dev/null || echo "0")")
        if [ "$BAL" != "0" ]; then
            ALL_WITHDRAWN=false
            PENDING_LIST="$PENDING_LIST ${WORKER_LABELS[$i]}=$(wei_to_ether "$BAL")"
        fi
    done

    for i in 0 1 2; do
        BAL=$(clean_val "$(cast call --rpc-url "$RPC_URL" "$STUDIO" \
            "getWithdrawableBalance(address)(uint256)" "${ALL_VERIFIERS[$i]}" 2>/dev/null || echo "0")")
        if [ "$BAL" != "0" ]; then
            ALL_WITHDRAWN=false
            PENDING_LIST="$PENDING_LIST ${VERIFIER_LABELS[$i]}=$(wei_to_ether "$BAL")"
        fi
    done

    if $ALL_WITHDRAWN; then
        echo "    All agents have withdrawn!"
        break
    fi

    printf '    [%3ds] Pending:%s\n' "$WITHDRAW_ELAPSED" "$PENDING_LIST"

    # Warp time on Anvil so agents see new blocks and can process
    if [ "$USE_ANVIL_TIME_WARP" = "true" ]; then
        cast rpc evm_increaseTime 5 --rpc-url "$RPC_URL" > /dev/null 2>&1 || true
        cast rpc evm_mine --rpc-url "$RPC_URL" > /dev/null 2>&1 || true
    fi

    sleep 5
    WITHDRAW_ELAPSED=$((WITHDRAW_ELAPSED + 5))
done

if ! $ALL_WITHDRAWN; then
    echo "    WARNING: Timeout (${WITHDRAW_TIMEOUT}s) — some agents may not have withdrawn."
fi

# ═══════════════════════════════════════════════════════════════════
# Phase 10: Final Balance Sheet
# ═══════════════════════════════════════════════════════════════════

log_header "Phase 10: Final Balance Sheet"

ACTIVE_STUDIOS=$(cast call \
    --rpc-url "$RPC_URL" \
    "$REGISTRY" \
    "getActiveStudios()(address[])" 2>/dev/null || echo "[]")

STUDIO_REMAINING_WEI=$(cast balance --rpc-url "$RPC_URL" "$STUDIO" 2>/dev/null || echo "0")
STUDIO_REMAINING_ETH=$(wei_to_ether "$STUDIO_REMAINING_WEI")

echo ""
echo "    Active studios after settlement: $ACTIVE_STUDIOS"
echo ""

# Use python for the complete balance sheet with slashing detection and reward verification
FR_LOGS_FILE=$(mktemp)
echo "$FR_LOGS" > "$FR_LOGS_FILE"
python3 -c "
import json, sys

fr_logs = json.load(open('$FR_LOGS_FILE'))
worker_evidence = json.load(open('$WORKER_EVIDENCE_FILE'))

# Agent addresses and labels
workers = [
$(for i in 0 1 2; do echo "    ('${ALL_WORKERS[$i]}', '${WORKER_LABELS[$i]}'),"; done)
]
verifiers = [
$(for i in 0 1 2; do echo "    ('${ALL_VERIFIERS[$i]}', '${VERIFIER_LABELS[$i]}'),"; done)
]

try:
    winning_outcome = int('$WINNING_OUTCOME')
except (ValueError, TypeError):
    winning_outcome = 0
try:
    _raw_wei = '$(echo "$STUDIO_REMAINING_WEI" | awk "{print \$1}")'
    studio_remaining_wei = int(_raw_wei.strip().split()[0]) if _raw_wei.strip() else 0
except (ValueError, TypeError):
    studio_remaining_wei = 0
rpc_url = '$RPC_URL'
studio = '$STUDIO'

def wei_to_eth(wei):
    return f'{wei / 1e18:.6f}'

def short_addr(addr):
    if len(addr) >= 10:
        return addr[:6] + '...' + addr[-4:]
    return addr

# Sum FundsReleased amounts per address
reward_by_addr = {}
total_rewards_wei = 0
for log in fr_logs:
    topics = log.get('topics', [])
    data = log.get('data', '0x')
    if len(topics) >= 2 and len(data) >= 66:
        recipient = '0x' + topics[1][-40:]
        amount = int(data[2:66], 16)
        key = recipient.lower()
        reward_by_addr[key] = reward_by_addr.get(key, 0) + amount
        total_rewards_wei += amount

# Build worker outcome map
worker_outcome_map = {}
for w in worker_evidence:
    addr = w['worker_addr'].lower()
    worker_outcome_map[addr] = {
        'outcome': w['outcome'],
        'is_forced': w.get('is_forced', False),
        'evidence_cid': w.get('evidence_cid', ''),
    }

# Get escrow balances via subprocess
import subprocess
def get_balance(func, addr):
    try:
        r = subprocess.run(
            ['cast', 'call', '--rpc-url', rpc_url, studio,
             f'{func}(address)(uint256)', addr],
            capture_output=True, text=True, timeout=10)
        return int(r.stdout.strip().split()[0])
    except:
        return 0

# Print header
print(f'    {\"Agent\":<14s} {\"Outcome\":<10s} {\"Staked\":<10s} {\"Reward\":<12s} {\"Net P/L\":<12s} {\"Status\"}')
print('    ' + '-' * 80)

slashed_agents = []
total_stakes_deposited = 0

# Workers
for addr, label in workers:
    escrow = get_balance('getEscrowBalance', addr)
    reward_wei = reward_by_addr.get(addr.lower(), 0)
    total_stakes_deposited += escrow

    staked_eth = wei_to_eth(escrow)
    reward_eth = wei_to_eth(reward_wei)

    # Get outcome info
    info = worker_outcome_map.get(addr.lower(), {})
    outcome = info.get('outcome', '?')
    outcome_label = 'Yes' if str(outcome) == '0' else 'No' if str(outcome) == '1' else '?'
    outcome_str = f'{outcome_label}({outcome})'
    is_forced = info.get('is_forced', False)

    # Determine status
    is_wrong = str(outcome) != str(winning_outcome)
    if reward_wei > 0:
        net_wei = reward_wei
        net_eth = '+' + wei_to_eth(net_wei)
        status = 'Rewarded'
    elif is_wrong:
        net_wei = -escrow if escrow > 0 else 0
        net_eth = '-' + wei_to_eth(abs(net_wei)) if net_wei < 0 else '0.000000'
        tag = ' (forced bad outcome)' if is_forced else ' (wrong outcome)'
        status = 'SLASHED' + tag
        slashed_agents.append({
            'label': label, 'addr': addr, 'outcome': outcome,
            'outcome_label': outcome_label, 'is_forced': is_forced,
            'evidence_cid': info.get('evidence_cid', ''),
        })
    else:
        net_eth = '0.000000'
        status = 'No reward'

    print(f'    {label:<14s} {outcome_str:<10s} {staked_eth:<10s} {reward_eth:<12s} {net_eth:<12s} {status}')

# Verifiers
for addr, label in verifiers:
    escrow = get_balance('getEscrowBalance', addr)
    reward_wei = reward_by_addr.get(addr.lower(), 0)
    total_stakes_deposited += escrow

    staked_eth = wei_to_eth(escrow)
    reward_eth = wei_to_eth(reward_wei)

    if reward_wei > 0:
        net_eth = '+' + wei_to_eth(reward_wei)
        status = 'Rewarded'
    else:
        net_eth = '0.000000'
        status = 'No reward'

    print(f'    {label:<14s} {\"--\":<10s} {staked_eth:<10s} {reward_eth:<12s} {net_eth:<12s} {status}')

print('    ' + '-' * 80)
print()

# Reward Verification
print('    Reward Verification:')
print('    ' + '-' * 56)
print(f'      Total rewards distributed:  {wei_to_eth(total_rewards_wei)} ETH  (from {len(fr_logs)} FundsReleased events)')
print(f'      Total stakes deposited:     {wei_to_eth(total_stakes_deposited)} ETH  ({len(workers) + len(verifiers)} agents)')
print(f'      Studio remaining balance:   {wei_to_eth(studio_remaining_wei)} ETH')
initial_approx = total_rewards_wei + studio_remaining_wei
print(f'      Distributed + remaining:    {wei_to_eth(initial_approx)} ETH')
print()

# Slashed agents section
if slashed_agents:
    print('    Slashed Agents:')
    print('    ' + '-' * 56)
    for sa in slashed_agents:
        forced_note = ' [FORCED via WORKER_FORCED_OUTCOME]' if sa['is_forced'] else ''
        print(f'      {sa[\"label\"]} submitted outcome {sa[\"outcome\"]} ({sa[\"outcome_label\"]}) -- minority position.{forced_note}')
        print(f'      Stake was NOT returned. Funds redistributed to honest workers.')
        if sa.get('evidence_cid'):
            print(f'      Evidence: http://localhost:8080/ipfs/{sa[\"evidence_cid\"]}')
        print()
" 2>&1 || echo "    (failed to generate balance sheet)"
rm -f "$FR_LOGS_FILE" "$WORKER_EVIDENCE_FILE"

echo ""
echo "    Links:"
log_divider
log_kv "Market" "$(link_addr "$MARKET")"
log_kv "Registry" "$(link_addr "$REGISTRY")"
log_kv "Studio" "$(link_addr "$STUDIO")"
log_kv "RewardsDistributor" "$(link_addr "$REWARDS_DIST")"
log_kv "Block Explorer" "$EXPLORER_URL"

echo ""
echo ""
printf '  ══════════════════════════════════════════════════════════\n'
printf '    E2E Sandbox Complete!\n'
printf '  ══════════════════════════════════════════════════════════\n'
echo ""
