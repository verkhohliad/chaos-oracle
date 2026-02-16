# ChaosOracle Sandbox

Full self-contained local environment for the ChaosOracle prediction market settlement system. Runs 12 Docker services including a local Anvil fork, ChaosChain Gateway, IPFS node, and AI-powered worker/verifier agents.

---

## Quick Start

### Prerequisites

- **Docker** and **Docker Compose** (v2)
- A **Sepolia RPC URL** (for Anvil to fork from) --- free tier from [Alchemy](https://www.alchemy.com/) or [Infura](https://www.infura.io/)
- An **OpenAI API key** for the AI agents

### 1. Configure

```bash
cd sandbox
cp .env.example .env
```

Edit `.env` and set:

```
SEPOLIA_RPC=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
OPENAI_API_KEY=sk-...
```

All other values (private keys) are pre-filled with Anvil's default test accounts.

### 2. Initialize submodules

```bash
# From repo root
git submodule update --init --recursive
```

### 3. Run

```bash
docker compose up --build
```

### 4. Watch

The orchestrator prints each phase as it progresses:

```
=== Phase 1: Create Market ===
=== Phase 2: Place Bets ===
=== Phase 3: Waiting for Deadline to Pass ===
  Using Anvil time-warp to skip past deadline...
=== Phase 4: Create Studio ===
=== Phase 5: Waiting for Agents ===
=== Phase 6: Economics Breakdown ===
=== Phase 7: Off-chain Consensus Computation ===
=== Phase 8: Settle Studio ===
=== Phase 9: Wait for Agent Withdrawals ===
=== Phase 10: Verify Settlement ===

=== E2E Sandbox Complete! ===
```

### 5. Clean up

```bash
docker compose down -v    # remove containers + volumes
```

---

## Architecture

```
                      +------------------+
                      |     Anvil        |  (Sepolia fork, :8545)
                      |  ChaosChain      |
                      |  contracts live  |
                      +--------+---------+
                               |
              +----------------+----------------+
              |                |                |
     +--------v------+  +-----v------+  +------v------+
     |   Deployer    |  |  Gateway   |  |    IPFS     |
     | (forge create)|  | (ChaosChain|  |   (Kubo)    |
     +-------+-------+  |  Node.js)  |  |  :5001/8080 |
             |           +-----+------+  +-------------+
             |                 |
    +--------v---------+      |
    |   Orchestrator   |      |
    | (simulates CRE)  |      |
    +------------------+      |
                               |
    +--------------------------+---------------------------+
    |              |              |              |          |
+---v---+  +------v--+  +-------v-+  +--------v+  +------v--+
|Worker1|  |Worker 2 |  |Worker 3 |  |Verifier1|  |Verifier2|  ...
| GPT-4 |  |  GPT-4  |  |GPT-4(No)|  |  GPT-4  |  |  GPT-4  |
+-------+  +---------+  +---------+  +---------+  +---------+
              All agents use Gateway + IPFS for evidence
```

### Services (12 total)

| Service | Image | Purpose | Port |
|---------|-------|---------|------|
| `anvil` | foundry | Sepolia fork (local chain) | 8545 |
| `postgres` | postgres:15 | Gateway database | 5432 |
| `ipfs` | ipfs/kubo | Evidence storage | 5001, 8080 |
| `gateway` | Built from submodule | ChaosChain Gateway API | 3000 |
| `deployer` | foundry | One-shot contract deployment | --- |
| `orchestrator` | foundry | Drives lifecycle (simulates CRE) | --- |
| `worker-{1,2,3}` | python:3.12 | AI research + work submission | --- |
| `verifier-{1,2,3}` | python:3.12 | AI audit + score submission | --- |

---

## How It Works

1. **Anvil** forks Sepolia --- real ChaosChain contracts (ChaosCore, StudioProxyFactory, RewardsDistributor) exist on the fork
2. **Deployer** deploys ChaosOracleRegistry, PredictionSettlementLogic, ExamplePredictionMarket
3. **Orchestrator** creates a market, places bets, time-warps past the deadline, creates a ChaosChain studio
4. **Workers** discover the studio via the Gateway, register, research the question with GPT, submit work with evidence to IPFS
5. **Verifiers** discover worker submissions via the Gateway, audit evidence, submit quality scores
6. **Orchestrator** computes consensus (majority outcome), calls `settleWithOutcome()` on the Registry
7. Market is settled, winners can claim payouts

---

## CRE Workflow

### Production (Chainlink DON)

In production, the Chainlink CRE (Compute Runtime Environment) runs on a Decentralized Oracle Network:

- **Trigger 1** (cron): Polls `getMarketsReadyForSettlement()`, calls `createStudioForMarket()` when deadline passes
- **Trigger 2** (log): Watches for `canCloseStudio()`, reads events from StudioProxy, fetches evidence from Arweave, computes score-weighted consensus, calls `settleWithOutcome()`

### Sandbox (Orchestrator)

CRE workflows **cannot** run locally with live triggers (only `cre workflow simulate .` works for testing). The orchestrator script mimics both CRE triggers:

1. Calls `createStudioForMarket()` directly (with `creForwarder = deployer`)
2. Polls `canCloseStudio()`, computes consensus, calls `settleWithOutcome()`

To test CRE workflow logic independently:

```bash
cd cre-workflow && cre workflow simulate .
```

---

## Account Allocation

Uses Anvil's default deterministic HD wallet accounts (10,000 ETH each):

| Account | Role | Key |
|---------|------|-----|
| 0 | Deployer + CRE simulator | `0xac09...ff80` |
| 1 | Bettor 1 (Yes) | `0x59c6...690d` |
| 2 | Bettor 2 (No) | `0x5de4...365a` |
| 3 | Worker 1 | `0x7c85...07a6` |
| 4 | Worker 2 | `0x47e1...926a` |
| 5 | Worker 3 (forced No) | `0x8b3a...ffba` |
| 6 | Verifier 1 | `0x92db...564e` |
| 7 | Verifier 2 | `0x4bbb...4356` |
| 8 | Verifier 3 | `0xdbda...d997` |
| 9 | Gateway signer | `0x2a87...09c6` |

---

## Troubleshooting

### "addresses.json not found after 120s"

The deployer failed. Check deployer logs:

```bash
docker compose logs deployer
```

Common cause: invalid `SEPOLIA_RPC` in `.env` (Anvil can't fork).

### Gateway won't start

Check gateway and postgres logs:

```bash
docker compose logs gateway
docker compose logs postgres
```

Common cause: PostgreSQL not ready (healthcheck should handle this), or missing `GATEWAY_SIGNER_KEY`.

### Workers/verifiers stuck

Check agent logs:

```bash
docker compose logs worker-1
docker compose logs verifier-1
```

Common causes:
- Gateway not reachable (check `CHAOSCHAIN_GATEWAY_URL=http://gateway:3000`)
- Missing `OPENAI_API_KEY`
- Registry address mismatch

### Fresh restart

```bash
docker compose down -v
docker compose up --build
```

The `-v` flag removes all volumes (shared, postgres data, IPFS data), forcing a clean start.

---

## File Structure

```
sandbox/
  docker-compose.yml        # 12-service orchestration
  .env.example              # Anvil keys + required env vars
  Dockerfile.foundry        # Foundry image for deployer/orchestrator
  Dockerfile.agents         # Python image for workers/verifiers
  Dockerfile.gateway        # ChaosChain Gateway (from submodule)
  scripts/
    deploy.sh               # Deploy contracts to Anvil fork
    orchestrate.sh           # Drive full lifecycle (10 phases)
  README.md
```
