# ChaosOracle Demo

Local end-to-end testing of the full ChaosOracle settlement lifecycle.

## Two Testing Modes

### 1. Foundry Fork Test (fast, single command)

Runs the full lifecycle in a single Solidity test against a Sepolia fork with **real ChaosChain contracts** (StudioProxyFactory, ChaosCore, etc.).

```bash
cd contracts
source .env  # needs SEPOLIA_RPC
forge test --match-contract ForkIntegrationTest --fork-url $SEPOLIA_RPC -vvv
```

This validates that our PredictionSettlementLogic storage layout is compatible with the real StudioProxy deployed by ChaosChain's factory.

### 2. Docker Compose E2E (full system, 9 containers)

Spins up anvil (Sepolia fork) + 3 workers + 3 verifiers + orchestrator in Docker. Uses the **real agent code** from `agents/` with `CHAOSCHAIN_MODE=local` to bypass the ChaosChain Gateway. The orchestrator manually triggers `createStudioForMarket()` and `closeStudioEpoch()` instead of CRE.

```bash
cd demo
cp .env.example .env
# Edit .env — set SEPOLIA_RPC to your Alchemy/Infura Sepolia URL

docker compose up --build

# for fresh start - docker compose down -v (clean addresses)
```

## Docker Compose Architecture

```
anvil (Sepolia fork, port 8545)
  └── deployer (deploys 3 contracts, writes addresses)
        ├── orchestrator (creates market, warps time, triggers settlement)
        ├── worker-1 (real agent, votes Yes)
        ├── worker-2 (real agent, votes Yes)
        ├── worker-3 (real agent, votes No via WORKER_FORCED_OUTCOME=1)
        ├── verifier-1 (real agent, scores all workers)
        ├── verifier-2 (real agent, scores all workers)
        └── verifier-3 (real agent, scores all workers)
```

### What Happens

1. **anvil** forks Sepolia (real ChaosChain contracts exist on the fork)
2. **deployer** deploys ChaosOracleRegistry, PredictionSettlementLogic, ExamplePredictionMarket
   - Sets `creForwarder` to the deployer address (CRE bypass for local testing)
3. **orchestrator** creates a market, places bets, fast-forwards time, creates a studio
4. **Workers** (real agent code from `agents/`) detect the studio, research (placeholder LLM), submit work via DirectSubmitter
5. **Verifiers** (real agent code from `agents/`) detect submissions, audit (heuristic fallback), score each worker via DirectSubmitter
6. **orchestrator** detects `canClose=true`, closes the epoch
7. Market is settled with the consensus outcome (Yes wins, 2-1 majority)

### Local Mode (`CHAOSCHAIN_MODE=local`)

In local mode, agents use `DirectSubmitter` instead of the ChaosChain Gateway:
- **No x402 payments** — calls contracts directly via web3
- **No ERC-8004 identity** — `auto_register()` is a no-op
- **No chaoschain-sdk dependency** — only `web3`, `aiohttp`, `pydantic`, `structlog`
- All existing agent logic (polling, research, evidence building, auditing) works unchanged

### Account Allocation

Uses anvil's default deterministic accounts (10,000 ETH each):

| Account | Role | Outcome |
|---------|------|---------|
| 0 | Deployer + CRE | — |
| 1 | Bettor | Yes |
| 2 | Bettor | No |
| 3 | Worker 1 | Yes |
| 4 | Worker 2 | Yes |
| 5 | Worker 3 | No |
| 6 | Verifier 1 | — |
| 7 | Verifier 2 | — |
| 8 | Verifier 3 | — |

### CRE Bypass

In production, only the Chainlink CRE forwarder can call `createStudioForMarket()` and `closeStudioEpoch()`. For local testing:

- Registry is deployed with `creForwarder = deployer address`
- `authorizedWorkflowId` is never set (stays `bytes32(0)`) so the workflow ID check is skipped
- Deployer calls these functions directly with `creReport = abi.encode(bytes32(0))`

## Standalone Demo Scripts

Shell scripts for manual interaction with contracts (on Sepolia or local fork):

| Script | Purpose |
|--------|---------|
| `create_market.sh` | Create market + register for settlement |
| `place_bet.sh` | Place a bet on a market |
| `check_settlement.sh` | Check market and studio state |

## File Structure

```
demo/
├── docker-compose.yml        # 9-service orchestration
├── .env.example               # Anvil keys + Sepolia RPC
├── Dockerfile.foundry         # Foundry image for deployer/orchestrator
├── Dockerfile.agents          # Python image — builds from agents/ with local deps
├── requirements-local.txt     # web3 + deps (no chaoschain-sdk)
├── scripts/
│   ├── deploy.sh              # Deploy contracts on anvil fork
│   ├── orchestrate.sh         # Drive full lifecycle (simulate CRE)
│   └── wait-for-anvil.sh      # Health check utility
├── create_market.sh           # Standalone: create market
├── place_bet.sh               # Standalone: place bet
├── check_settlement.sh        # Standalone: check state
└── README.md
```
