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

## Quick Start — Local Demo

Run the full E2E lifecycle in Docker (9 containers: anvil fork + 3 workers + 3 verifiers + orchestrator):

```bash
# Prerequisites: Docker, Docker Compose, a Sepolia RPC URL (Alchemy/Infura free tier)

git clone https://github.com/AverTechnologies/chaos-oracle.git
cd chaos-oracle/demo
cp .env.example .env
# Edit .env — set SEPOLIA_RPC to your Sepolia URL

docker compose up --build
```

See [demo/README.md](./demo/README.md) for full instructions, expected output, and troubleshooting.

---

## Project Structure

```
contracts/       Solidity contracts (Registry, SettlementLogic, ExampleMarket)
agents/          Python worker & verifier agents
cre-workflow/    Chainlink CRE settlement workflow (TypeScript)
demo/            Docker Compose E2E demo
abis/            Contract ABIs (generated from forge build)
scripts/         Helper scripts (ABI export, etc.)
```

---

## For Developers

| I want to... | Start here |
|--------------|------------|
| **Run the demo** | [demo/README.md](./demo/README.md) |
| **Integrate my prediction market** | [docs.md — For Prediction Market Developers](./docs.md#for-prediction-market-developers) |
| **Build an AI agent** | [docs.md — For AI Agent Developers](./docs.md#for-ai-agent-developers) |
| **Understand the architecture** | [docs.md — Architecture](./docs.md#architecture) |
| **Deploy to Sepolia** | [docs.md — Deployment Guide](./docs.md#deployment-guide) |
| **Read the contracts** | [contracts/README.md](./contracts/README.md) |

---

## Deployed Contracts (Sepolia)

| Contract | Address |
|----------|---------|
| ChaosOracleRegistry | _coming soon_ |
| PredictionSettlementLogic | _coming soon_ |
| ExamplePredictionMarket | _coming soon_ |
| CRE Workflow ID | _coming soon_ |

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
| Smart Contracts | Solidity 0.8.19, Foundry |
| AI Agents | Python 3.12, web3.py, aiohttp, structlog |
| CRE Workflow | TypeScript, Chainlink CRE SDK |
| Evidence Storage | Arweave |
| Agent Identity | ERC-8004 |
| Agent Payments | x402 |
| Local Testing | Docker Compose, Anvil (Sepolia fork) |

---

## Tests

```bash
cd contracts
forge test --skip ForkIntegration.t.sol        # 67 unit + integration tests
forge test --match-contract ForkIntegrationTest --fork-url $SEPOLIA_RPC  # 1 fork test
```

68 tests across 5 suites — see [contracts/README.md](./contracts/README.md) for details.
