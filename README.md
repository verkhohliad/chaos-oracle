# 🔮 ChaosOracle

**AI-Powered Prediction Market Settlement**

Built with [ChaosChain](https://github.com/ChaosChain/chaoschain) + [Chainlink CRE](https://chain.link/chainlink-runtime-environment) + [ERC-8004](https://eips.ethereum.org/EIPS/eip-8004) + [x402](https://github.com/coinbase/x402)

---

# [Full e2e demo video on X](https://x.com/verkhohliad_i/status/2026801063257346297)

# [Live Demo](https://chaos-oracle-nine.vercel.app/)

## What is ChaosOracle?

A plug-and-play settlement layer for prediction markets. Integrate ChaosOracle and let verified AI agents settle your markets — no custom oracle needed.

```
Your Market  --->  ChaosOracle Registry  --->  CRE Workflow  --->  ChaosChain Studio
 (register)         (track markets)          (orchestrate)      (workers + verifiers)
                                                                        |
                                                                   consensus
                                                                        |
                                                                   onSettlement()
                                                                        |
                                                                   Your Market resolved
```

**Workers** research outcomes, stake tokens, and submit evidence.
**Verifiers** audit worker submissions and submit quality scores.
**CRE** orchestrates the lifecycle — creates studios and triggers settlement.
**Your market** receives the consensus outcome via a callback.

---

## Quick Start — Local Sandbox

Run the full E2E lifecycle in Docker (14 containers: Anvil fork + Gateway + IPFS + Otterscan + PostgreSQL + cre-runner + 3 workers + 3 verifiers + deployer + orchestrator):

```bash
# Prerequisites: Docker, Docker Compose, a Sepolia RPC URL (Alchemy/Infura free tier)

git clone https://github.com/AverTechnologies/chaos-oracle.git
cd chaos-oracle
git submodule update --init --recursive
cd sandbox
cp .env.example .env
# Edit .env — set SEPOLIA_RPC and OPENAI_API_KEY

docker compose up --build
```

See [sandbox/README.md](./sandbox/README.md) for full instructions, expected output, and troubleshooting.

---

## Sepolia Demo

Run the full settlement lifecycle on Ethereum Sepolia with real CRE triggers, Arweave evidence storage, and on-chain consensus. Two ways to experience it:

**Option A — CLI Orchestrator** (automated end-to-end):
```bash
cd demo/run
cp .env.example .env   # set SEPOLIA_RPC, keys, OPENAI_API_KEY, contract addresses
docker compose up --build
./orchestrate-sepolia.sh
```

**Option B — Frontend Explorer** (interactive UI):
```bash
# 1. Start backend services
cd demo/run && docker compose up --build

# 2. Start indexer (in another terminal)
cd demo/indexer && pnpm install && pnpm codegen && pnpm dev

# 3. Start frontend (in another terminal)
cd demo/frontend && npm install && npm run dev
# Open http://localhost:3000
```

Browse markets, connect your wallet, place bets, watch live DKG settlement (worker submissions, verifier score matrix, consensus), inspect AI evidence from Arweave, and claim winnings — all in a Uniswap-style dark UI.

See [demo/README.md](./demo/README.md) for prerequisites, contract deployment, CRE workflow setup, and troubleshooting.

---

## Project Structure

```
contracts/        Solidity contracts (Registry, SettlementLogic, ExampleMarket)
agents/           Python worker & verifier agents
cre-workflow/     Chainlink CRE settlement workflow (TypeScript)
sandbox/          Full local sandbox (14 Docker services)
demo/run/         Sepolia demo — Docker Compose + orchestrator
demo/indexer/     Envio HyperIndex — GraphQL indexer for on-chain events
demo/frontend/    Next.js 15 explorer — market UI, betting, DKG visualization
demo/deploy/      Foundry deployment scripts
abis/             Contract ABIs (generated from forge build)
scripts/          Helper scripts (ABI export, etc.)
```

---

## For Developers

| I want to... | Start here |
|--------------|------------|
| **Run the sandbox** | [sandbox/README.md](./sandbox/README.md) |
| **Run the Sepolia demo** | [demo/README.md](./demo/README.md) |
| **Explore the frontend** | [demo/frontend/README.md](./demo/frontend/README.md) |
| **Set up the indexer** | [demo/indexer/README.md](./demo/indexer/README.md) |
| **Integrate my prediction market** | [docs.md — For Prediction Market Developers](./docs.md#for-prediction-market-developers) |
| **Build an AI agent** | [docs.md — For AI Agent Developers](./docs.md#for-ai-agent-developers) |
| **Understand the architecture** | [docs.md — Architecture](./docs.md#architecture) |
| **Deploy to Sepolia** | [docs.md — Deployment Guide](./docs.md#deployment-guide) |
| **Read the contracts** | [contracts/README.md](./contracts/README.md) |

---

## Deployed Contracts (Sepolia)

| Contract | Address |
|----------|---------|
| ChaosOracleRegistry | `0x4D067737D50bFeC0da87Cc782eA144Aeb24c05d5` |
| PredictionSettlementLogic | `0x689FD6DF59eeC5aB4729015cB238330a33a346c5` |
| ExamplePredictionMarket | `0x64A52A8ce57291cA701F18376f26E224F7E2AEcb` |
| CRE Workflow ID | _TBD after DON deployment_ |

## Frontend

Next.js 15 prediction market explorer.

- **Browse markets** — pool bars, status badges, countdowns
- **Connect wallet** — RainbowKit + wagmi v2 on Sepolia
- **Place bets** — Yes/No binary markets with ETH
- **Watch DKG settlement** — live worker submissions, verifier score matrix, consensus result
- **Inspect AI evidence** — Arweave-stored research with sources, confidence scores, reasoning
- **Claim winnings** — pro-rata payout after settlement

See [demo/frontend/README.md](./demo/frontend/README.md) for setup.

---

## Documentation

Full technical documentation — architecture diagrams, security model, complete flow, contract API, CRE workflow, integration guides, and deployment instructions:

**[docs.md](./docs.md)**

---

## Tech Stack

| Component | Technology |
|-----------|------------|
| Smart Contracts | Solidity 0.8.24, Foundry |
| AI Agents | Python 3.12, web3.py, aiohttp, structlog |
| CRE Workflow | TypeScript, Chainlink CRE SDK |
| Frontend | Next.js 15, React 19, Tailwind CSS v4, wagmi v2, RainbowKit |
| Indexer | Envio HyperIndex v2, GraphQL |
| Evidence Storage | IPFS (sandbox) / Arweave (production) |
| Agent Identity | ERC-8004 |
| Agent Payments | x402 |
| Local Testing | Docker Compose, Anvil (Sepolia fork) |

---

## Tests

```bash
cd contracts
forge test --skip ForkIntegration        # unit + integration tests
forge test --match-contract ForkIntegrationTest --fork-url $SEPOLIA_RPC -vvv  # fork tests
```

90 tests across 7 suites — see [contracts/README.md](./contracts/README.md) for details.
