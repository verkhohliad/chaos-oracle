# ChaosOracle Demo

Local end-to-end testing of the full ChaosOracle settlement lifecycle.

---

## Quick Start

### Prerequisites

- **Docker** and **Docker Compose** (v2)
- A **Sepolia RPC URL** — free tier from [Alchemy](https://www.alchemy.com/) or [Infura](https://www.infura.io/)

### 1. Configure

```bash
cd demo
cp .env.example .env
```

Edit `.env` and set your Sepolia RPC URL:

```
SEPOLIA_RPC=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
```

All other values (private keys) are pre-filled with Anvil's default test accounts.

### 2. Run

```bash
docker compose up --build
```

### 3. Watch

The orchestrator will print each phase as it progresses:

```
=== Phase 1: Create Market ===
=== Phase 2: Place Bets ===
=== Phase 3: Warp Time Past Deadline ===
=== Phase 4: Create Studio ===
=== Phase 5: Waiting for Agents ===
  [0s] workers=0 verifiers=0 canClose=false
  [5s] workers=1 verifiers=0 canClose=false
  ...
  [60s] workers=3 verifiers=3 canClose=true
  Studio is ready to close!
=== Phase 6: Close Epoch ===
=== Phase 7: Verify Settlement ===

=========================================
=== E2E Demo Complete! ===
=========================================
```

### 4. Clean up

```bash
docker compose down -v    # remove containers + shared volume
```

To re-run without redeploying contracts (if anvil is still running):

```bash
docker compose up --build  # deployer skips if contracts are still live
```

---

## What's Happening

```
anvil (Sepolia fork, port 8545)
  +-- deployer (deploys 3 contracts, writes /shared/addresses.json)
        +-- orchestrator (creates market, warps time, triggers settlement)
        +-- worker-1  (researches, votes Yes)
        +-- worker-2  (researches, votes Yes)
        +-- worker-3  (forced to vote No via WORKER_FORCED_OUTCOME=1)
        +-- verifier-1 (audits + scores all workers)
        +-- verifier-2 (audits + scores all workers)
        +-- verifier-3 (audits + scores all workers)
```

1. **anvil** forks Sepolia — real ChaosChain contracts exist on the fork
2. **deployer** deploys ChaosOracleRegistry, PredictionSettlementLogic, ExamplePredictionMarket
3. **orchestrator** creates a market ("Will ETH reach $10,000?"), places bets, fast-forwards time, creates a ChaosChain studio
4. **Workers** discover the studio, register (stake 0.001 ETH), research the question, submit work
5. **Verifiers** discover worker submissions, register, fetch evidence, audit, submit quality scores
6. **orchestrator** detects `canClose=true`, closes the epoch — consensus outcome is computed, rewards distributed
7. Market is settled with the winning outcome (Yes wins, 2-1 majority)

---

## Troubleshooting

### "addresses.json not found after 120s"

The deployer failed. Check deployer logs:

```bash
docker compose logs deployer
```

Common cause: invalid `SEPOLIA_RPC` in `.env` (anvil can't fork).

### Workers/verifiers stuck at 0

Check agent logs:

```bash
docker compose logs worker-1
docker compose logs verifier-1
```

Common causes:
- Deployer wrote addresses but agents can't reach anvil (network issue)
- Registry address mismatch

### "Timeout waiting for agents"

Agents didn't complete within 180s. Check all agent logs. Likely cause: a verifier failed to score (check for revert errors).

### Fresh restart

```bash
docker compose down -v
docker compose up --build
```

The `-v` flag removes the shared volume, forcing a fresh deployment.

---

## Local Mode Details

### `CHAOSCHAIN_MODE=local`

In local mode, agents use `DirectSubmitter` instead of the ChaosChain Gateway:

- **No x402 payments** — calls contracts directly via web3
- **No ERC-8004 identity** — agent registration is a no-op
- **No chaoschain-sdk dependency** — only `web3`, `aiohttp`, `pydantic`, `structlog`
- All existing agent logic (polling, research, evidence building, auditing) works unchanged

### CRE Bypass

In production, only the Chainlink CRE forwarder can call `createStudioForMarket()` and `closeStudioEpoch()`. For local testing:

- Registry is deployed with `creForwarder = deployer address`
- `authorizedWorkflowId` stays `bytes32(0)` so the workflow ID check is skipped
- Deployer calls these functions directly with `creReport = abi.encode(bytes32(0))`

### Account Allocation

Uses Anvil's default deterministic accounts (10,000 ETH each):

| Account | Role | Outcome |
|---------|------|---------|
| 0 | Deployer + CRE simulator | — |
| 1 | Bettor | Yes |
| 2 | Bettor | No |
| 3 | Worker 1 | Yes |
| 4 | Worker 2 | Yes |
| 5 | Worker 3 | No (forced) |
| 6 | Verifier 1 | — |
| 7 | Verifier 2 | — |
| 8 | Verifier 3 | — |

---

## Standalone Demo Scripts

Shell scripts for manual interaction with contracts (on Sepolia or local fork):

| Script | Purpose | Usage |
|--------|---------|-------|
| `create_market.sh` | Create market + register for settlement | `./create_market.sh "Question?" <deadline_unix>` |
| `place_bet.sh` | Place a bet on a market | `./place_bet.sh <market_id> <0\|1> <eth_value>` |
| `check_settlement.sh` | Check market and studio state | `./check_settlement.sh <market_id>` |

---

## File Structure

```
demo/
  docker-compose.yml        # 9-service orchestration
  .env.example              # Anvil keys + Sepolia RPC template
  Dockerfile.foundry        # Foundry image for deployer/orchestrator
  Dockerfile.agents         # Python image for workers/verifiers
  requirements-local.txt    # Python deps (no chaoschain-sdk)
  scripts/
    deploy.sh               # Deploy contracts on anvil fork
    orchestrate.sh           # Drive full lifecycle (7 phases)
    wait-for-anvil.sh        # Health check utility
  create_market.sh           # Standalone: create market
  place_bet.sh               # Standalone: place bet
  check_settlement.sh        # Standalone: check state
  README.md
```
