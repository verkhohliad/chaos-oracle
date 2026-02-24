# ChaosOracle Sepolia Demo

Production-ready demo of the ChaosOracle prediction market settlement system on Ethereum Sepolia.

## Architecture

```
                                    Chainlink CRE DON
                                   ┌─────────────────────┐
                                   │ Trigger 1: Cron 5m  │──→ createStudioForMarket()
                                   │ Trigger 2: LogTrig  │──→ settleWithOutcome()
                                   │ Trigger 3: Cron 3m  │──→ Gateway /close-epoch
                                   └─────────────────────┘
                                             │
┌────────────────┐     ┌─────────────────────┼───────────────────────┐
│ ExampleMarket  │     │        ChaosOracleRegistry                  │
│ (Prediction)   │◄────│  registerForSettlement() → StudioProxy      │
└────────────────┘     └─────────────────────────────────────────────┘
                                             │
           ┌─────────────────────────────────┼─────────────────────────┐
           │                                 │                         │
    ┌──────▼──────┐                  ┌───────▼───────┐          ┌──────▼──────┐
    │   Workers   │  evidence_bytes  │    Gateway    │  scores  │  Verifiers  │
    │  (Python)   │─────────────────►│  (Node.js)   │◄─────────│  (Python)   │
    └─────────────┘                  └───────────────┘          └─────────────┘
           │                           │         │                     │
           │ DKG nodes                 │ Arweave │ StudioProxy         │ DKG audit
           └──────────►XMTP◄──────────┘  upload  │ + RewardsDistributor│
                       Bridge                    │                     │
                                                 ▼
                                        ERC-8004 Reputation
```

**Backend services** (8 Docker containers):
- `postgres` — Gateway persistence
- `gateway` — ChaosChain Gateway (dual-signer routing)
- `worker-1`, `worker-2` — AI worker agents (gpt-4.1 + web_search)
- `verifier-1`, `verifier-2` — AI verifier agents (o4-mini)
- `cre-runner` — Chainlink CRE CLI + Bun runtime
- `orchestrator` — Drives the settlement lifecycle

**Companion tools** (run on host):
- [**Envio Indexer**](./indexer/README.md) — indexes on-chain events into GraphQL
- [**Next.js Frontend**](./frontend/README.md) — market explorer with DKG visualization

**Contracts** (deployed on Sepolia):
- ChaosChainRegistry, ChaosCore, RewardsDistributor
- ChaosOracleRegistry, PredictionSettlementLogic, ExamplePredictionMarket
- StudioProxyFactory, ERC-8004 registries (reused from ChaosChain team)

## Prerequisites

- **Sepolia ETH**: 0.5+ ETH in deployer wallet, 0.05 ETH in each agent wallet
- **API Keys**: OpenAI (`sk-...`), Alchemy/Infura Sepolia RPC
- **Tools**: `foundry` (forge, cast), `docker`, `docker compose`, CRE CLI
- **CRE CLI**: `cre workflow deploy` requires Chainlink CRE access
- **Node.js 22+** and **pnpm** (for indexer local dev)

## Setup

### 1. Deploy Contracts

```bash
cd demo/deploy
export DEPLOYER_PRIVATE_KEY=0x...
export SEPOLIA_RPC=https://eth-sepolia.g.alchemy.com/v2/...
export ETHERSCAN_API_KEY=...  # optional, for verification

./deploy-all.sh
# Outputs: addresses.sepolia.json
```

### 2. Deploy CRE Workflow

```bash
cd cre-workflow/settlement-workflow

# Edit config.sepolia.json with addresses from step 1
# Set registryAddress, rewardsDistributorAddress, fromBlock, gatewayUrl, defaultSignerAddress

cre workflow deploy . --target sepolia-settings
# Note the WORKFLOW_ID from output

# Authorize the workflow
cast send --rpc-url $SEPOLIA_RPC --private-key $DEPLOYER_PRIVATE_KEY \
    <CHAOSORACLE_REGISTRY> "setAuthorizedWorkflowId(bytes32)" <WORKFLOW_ID>
```

### 3. Configure Environment

```bash
cd demo/run
cp .env.example .env
# Fill in: SEPOLIA_RPC, DEPLOYER_PRIVATE_KEY, agent keys, OPENAI_API_KEY
# Fill in: contract addresses from addresses.sepolia.json
```

### 4. Start Backend Services

```bash
cd demo/run
docker compose up --build
```

This starts all 8 containers: postgres, gateway, 2 workers, 2 verifiers, cre-runner, orchestrator.

## Running the Demo

### Option A: CLI Orchestrator (automated)

Run the full settlement lifecycle end-to-end from the command line:

```bash
cd demo/run
./orchestrate-sepolia.sh
```

The orchestrator automatically:
1. Creates a prediction market with a 3-minute deadline
2. Places test bets (Yes + No)
3. Waits for deadline, then triggers CRE to create a studio
4. Monitors workers researching and submitting evidence to Arweave
5. Monitors verifiers auditing and scoring
6. Triggers epoch close via CRE + Gateway
7. Triggers settlement via CRE (score-weighted consensus)
8. Displays final results

Best for: quick verification, CI, headless runs.

### Option B: Frontend Explorer (interactive)

Experience the full settlement UX through a Uniswap-style web interface.

**1. Start the indexer** (indexes on-chain events into GraphQL):

```bash
cd demo/indexer
pnpm install
pnpm codegen
pnpm dev          # Starts indexer + local PostgreSQL on port 8080
```

Or use [Envio hosted service](https://docs.envio.dev/docs/HyperIndex/hosted-service) — see [indexer/README.md](./indexer/README.md).

**2. Start the frontend**:

```bash
cd demo/frontend
cp .env.local.example .env.local
# Set INDEXER_GRAPHQL_URL=http://localhost:8080/v1/graphql (or Envio hosted URL)
# Set NEXT_PUBLIC_MARKET_ADDRESS=<from addresses.sepolia.json>

npm install
npm run dev       # http://localhost:3000
```

**3. Explore**:

- **Browse markets** — pool bars showing Yes/No distribution, status badges, countdowns
- **Connect wallet** — RainbowKit modal, Sepolia network
- **Place bets** — select Yes or No, enter ETH amount, submit transaction
- **Watch live DKG settlement** — worker submissions appear in real-time, verifier score matrix fills in, consensus builds
- **Inspect AI evidence** — click through to Arweave-stored research: sources, confidence scores, reasoning chains, web search queries
- **Claim winnings** — after settlement, claim pro-rata share of the winning pool

Best for: demos, presentations, exploring the full settlement UX.

## Settlement Flow

1. **Market Registration**: `ExamplePredictionMarket.createMarket()` registers with `ChaosOracleRegistry`
2. **Studio Creation**: CRE cron trigger detects deadline passed, calls `createStudioForMarket()` via CRE report
3. **Worker Research**: Workers poll registry, research via OpenAI web_search, build evidence, submit via Gateway
4. **Verifier Audit**: Verifiers fetch evidence from Arweave, audit with OpenAI, submit scores via Gateway
5. **Epoch Close**: CRE cron trigger detects sufficient submissions, calls Gateway `/workflows/close-epoch`
6. **Settlement**: CRE log trigger detects `EpochClosed`, reads finalized scores, computes consensus, calls `settleWithOutcome()`
7. **Withdrawals**: Agents call `withdraw()` on StudioProxy to claim stakes + rewards

## Project Structure

| Directory | Purpose |
|-----------|---------|
| `demo/deploy/` | Foundry two-phase deployment scripts (`addresses.sepolia.json`) |
| `demo/run/` | Docker Compose (8 services) + `orchestrate-sepolia.sh` |
| `demo/indexer/` | Envio HyperIndex — 4 contracts, 11 events, 8 GraphQL entities ([README](./indexer/README.md)) |
| `demo/frontend/` | Next.js 15 explorer — Uniswap dark theme, wagmi, DKG panel ([README](./frontend/README.md)) |

## Troubleshooting

**CRE trigger not firing**: Check workflow is deployed and authorized (`setAuthorizedWorkflowId`). Verify the CRE Forwarder address matches.

**Gateway signer error**: Ensure all agent private keys are in `.env` as `SIGNER_PRIVATE_KEY_2` through `SIGNER_PRIVATE_KEY_5`. The Gateway uses dual-signer routing: agent keys for StudioProxy calls, deployer key for RewardsDistributor.

**Worker/verifier stuck**: Check OpenAI API key is valid. Check RPC URL connectivity. Review container logs: `docker compose logs worker-1`.

**Insufficient gas**: CRE `gasLimit` must be 6M+ for `deployStudioProxy()`. Check `config.sepolia.json`.

**Evidence fetch fails**: Arweave uploads may take 5-10 seconds to propagate. Verifiers retry on next poll cycle.

**Indexer won't start**: `envio start` / `pnpm dev` needs Docker Desktop running — it launches its own PostgreSQL + Hasura containers. Run `pnpm stop` first to clean up stale state.

**Frontend shows no data**: Ensure `INDEXER_GRAPHQL_URL` in `.env.local` points to a running indexer (local `http://localhost:8080/v1/graphql` or Envio hosted URL). The frontend proxies GraphQL requests through `/api/graphql`.
