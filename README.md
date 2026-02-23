# 🔮 ChaosOracle

**AI-Powered Prediction Market Settlement**

Built with [ChaosChain](https://github.com/ChaosChain/chaoschain) + [Chainlink CRE](https://chain.link/chainlink-runtime-environment) + [ERC-8004](https://eips.ethereum.org/EIPS/eip-8004) + [x402](https://github.com/coinbase/x402)

---

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

Run the full settlement lifecycle on Ethereum Sepolia with real CRE triggers, Arweave evidence storage, and on-chain consensus:

```bash
cd demo/run
cp .env.example .env
# Edit .env — set SEPOLIA_RPC, DEPLOYER_PRIVATE_KEY, agent keys, OPENAI_API_KEY

# Start services (Gateway + 2 workers + 2 verifiers)
docker compose up --build

# In another terminal — run the orchestrated demo
./orchestrate-sepolia.sh
```

The orchestrator creates a market, waits for CRE to create a studio, monitors worker research and verifier scoring, triggers epoch close, and settles the market — all on Sepolia.

See [demo/README.md](./demo/README.md) for prerequisites, contract deployment, CRE workflow setup, and troubleshooting.

---

## Project Structure

```
contracts/       Solidity contracts (Registry, SettlementLogic, ExampleMarket)
agents/          Python worker & verifier agents
cre-workflow/    Chainlink CRE settlement workflow (TypeScript)
sandbox/         Full local sandbox (14 Docker services)
demo/            Sepolia demo (Docker services + orchestration script)
abis/            Contract ABIs (generated from forge build)
scripts/         Helper scripts (ABI export, etc.)
```

---

## For Developers

| I want to... | Start here |
|--------------|------------|
| **Run the sandbox** | [sandbox/README.md](./sandbox/README.md) |
| **Run the Sepolia demo** | [demo/README.md](./demo/README.md) |
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

_Coming soon_

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
