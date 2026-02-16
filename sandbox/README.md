# 🔮 ChaosOracle Sandbox

Full self-contained local environment for the ChaosOracle prediction market settlement system. Runs 13 Docker services including a local Anvil fork, ChaosChain Gateway, IPFS node, Otterscan block explorer, and AI-powered worker/verifier agents.

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

The orchestrator prints structured logs for each phase:

```
═══ Phase 0: Initialization ═══
═══ Phase 1: Create Market ═══
═══ Phase 2: Place Bets ═══
═══ Phase 3: Wait for Deadline ═══
  Using Anvil time-warp to skip past deadline...
═══ Phase 4: Create Studio ═══
═══ Phase 5a: Worker Submissions ═══
  Per-worker evidence: outcome, confidence, reasoning, IPFS links
  Worker-3 marked as "FORCED OUTCOME" (bad answer for slashing test)
═══ Phase 5b: Verifier Scores ═══
  Score matrix grouped by worker (3 verifiers x 3 workers = 9 scores)
  Dimensions: accuracy, evidence_quality, source_diversity, reasoning_depth
═══ Phase 6: Economics Breakdown ═══
═══ Phase 7: Off-chain Consensus ═══
═══ Phase 8: Settle Studio ═══
═══ Phase 8.5: Close Epoch (RewardsDistributor) ═══
═══ Phase 9: Agent Withdrawals ═══
═══ Phase 10: Final Balance Sheet ═══
  Per-agent: outcome, stake, reward, net P/L, status (Rewarded/Slashed)
  Reward verification: sum check of rewards + remaining = initial escrow

═══ E2E Sandbox Complete! ═══
```

### 5. Explore

Open the **Otterscan block explorer** at [http://localhost:5100](http://localhost:5100) to browse transactions, contracts, and events on the local Anvil fork. All on-chain transaction links in the orchestrator logs point here.

### 6. Clean up

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
              +----------------+-------+--------+
              |                |       |        |
     +--------v------+  +-----v------+|  +-----v--------+
     |   Deployer    |  |  Gateway   ||  |  Otterscan   |
     | (forge create)|  | (ChaosChain||  | (Block Expl) |
     +-------+-------+  |  Node.js)  ||  |    :5100     |
             |           +-----+------+|  +--------------+
             |                 |       |
    +--------v---------+      | +-----v------+
    |   Orchestrator   |      | |    IPFS    |
    | (simulates CRE)  |      | |   (Kubo)   |
    +------------------+      | | :5001/8080 |
                               | +------------+
    +--------------------------+---------------------------+
    |              |              |              |          |
+---v---+  +------v--+  +-------v-+  +--------v+  +------v--+
|Worker1|  |Worker 2 |  |Worker 3 |  |Verifier1|  |Verifier2|  ...
| GPT-4 |  |  GPT-4  |  |GPT-4(No)|  |  GPT-4  |  |  GPT-4  |
+-------+  +---------+  +---------+  +---------+  +---------+
              All agents use Gateway + IPFS for evidence
```

### Services (13 total)

| Service | Image | Purpose | Port |
|---------|-------|---------|------|
| `anvil` | foundry | Sepolia fork (local chain) | 8545 |
| `postgres` | postgres:16 | Gateway database | 5432 |
| `ipfs` | ipfs/kubo | Evidence storage (IPFS API + gateway) | 5001, 8080 |
| `otterscan` | otterscan/otterscan | Block explorer UI | 5100 |
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
4. **Workers** discover the studio via the Gateway, register, research the question with GPT, submit work + evidence to IPFS
5. **Verifiers** discover worker submissions via the Gateway, fetch evidence from IPFS, audit each submission, submit quality scores (each verifier scores all 3 workers = 9 total scores)
6. **Orchestrator** computes consensus (majority outcome), calls `settleWithOutcome()` on the Registry, then calls `closeEpoch()` on RewardsDistributor to distribute rewards and slash wrong workers
7. **Agents** withdraw their stakes and rewards from the studio
8. **Orchestrator** prints a final balance sheet showing per-agent outcomes, rewards, slashing status, and a reward verification summary
9. **Otterscan** at [http://localhost:5100](http://localhost:5100) lets you browse all transactions, contracts, and events

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
3. Calls `closeEpoch()` on RewardsDistributor to distribute rewards and slash wrong workers
4. Waits for agents to withdraw, then prints a detailed balance sheet

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

## Web UIs

| Service | URL | Description |
|---------|-----|-------------|
| Otterscan | [http://localhost:5100](http://localhost:5100) | Block explorer — browse transactions, contracts, events |
| IPFS Gateway | [http://localhost:8080](http://localhost:8080) | View evidence packages: `http://localhost:8080/ipfs/<CID>` |

## File Structure

```
sandbox/
  docker-compose.yml        # 13-service orchestration
  .env.example              # Anvil keys + required env vars
  Dockerfile.foundry        # Foundry image for deployer/orchestrator
  Dockerfile.agents         # Python image for workers/verifiers
  Dockerfile.gateway        # ChaosChain Gateway (from submodule)
  scripts/
    deploy.sh               # Deploy contracts to Anvil fork
    orchestrate.sh           # Drive full lifecycle (12 phases)
  README.md
```
