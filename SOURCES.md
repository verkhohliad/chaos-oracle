# ChaosOracle - External Sources Analysis

This document catalogs and summarizes all external technologies, standards, and dependencies
referenced in the ChaosOracle README, based on primary-source research.

---

## 1. ChaosChain

- **Source:** [github.com/ChaosChain/chaoschain](https://github.com/ChaosChain/chaoschain)
- **Role in ChaosOracle:** Verification layer - workers research outcomes, verifiers audit, consensus + rewards

### Summary

ChaosChain is a blockchain-based accountability protocol for autonomous AI agents. It establishes
**Proof of Agency (PoA)** through cryptographic verification of agent actions, combining on-chain
smart contracts with off-chain evidence storage.

### Key Concepts

| Concept | Description |
|---------|-------------|
| **Studios** | On-chain collaborative environments (lightweight proxy contracts) handling work submission, escrow, and agent stakes. Business logic is delegated to reusable LogicModule templates. |
| **Decentralized Knowledge Graph (DKG)** | Structures work evidence as a causally-linked DAG. Agents coordinate via XMTP, store artifacts on Arweave/IPFS, and commit only cryptographic hashes on-chain. |
| **Gateway Service** | Orchestrates workflows between SDK, off-chain infrastructure, and smart contracts. Economically powerless - all protocol authority resides in on-chain contracts. |

### Five-Dimensional Agency Scoring

ChaosChain measures agency across five universal dimensions derived from DKG analysis:

1. **Initiative** - Original contributions, detected via root/early nodes
2. **Collaboration** - Building on others' work through reply edges
3. **Reasoning Depth** - Problem-solving complexity via path length analysis
4. **Compliance** - Policy adherence and regulatory checks
5. **Efficiency** - Work-to-cost ratios and resource management

### Consensus Mechanism

Uses **per-worker consensus** rather than aggregating all contributors equally. Multiple verifiers
independently score each agent across the five dimensions. During epoch closure, the system performs
robust aggregation (median, MAD trimming) to compute individual reputation vectors and reward
distributions.

### Relevance to ChaosOracle

ChaosOracle uses ChaosChain Studios as the settlement environment. The `PredictionSettlementLogic.sol`
contract is a ChaosChain LogicModule that defines prediction-market-specific scoring weights and
incentive structures. Workers research market outcomes, verifiers audit their work, and the
consensus mechanism determines the settlement result.

---

## 2. Chainlink CRE (Chainlink Runtime Environment)

- **Source:** [chain.link/chainlink-runtime-environment](https://chain.link/chainlink-runtime-environment)
- **Docs:** [docs.chain.link/cre](https://docs.chain.link/cre)
- **Role in ChaosOracle:** Orchestration - triggers studio creation and closeEpoch

### Summary

Chainlink CRE is an orchestration layer for building advanced smart contract workflows. Developers
build Workflows using the CRE SDK (Go/TypeScript), compile them into WASM binaries via the CRE CLI,
and deploy them to a Decentralized Oracle Network (DON). Each workflow is orchestrated by a Workflow
DON that monitors for triggers and coordinates execution across specialized Capability DONs.

### Key Features

- **Unified cross-domain orchestration** - Combine on-chain and off-chain operations in a single workflow
- **BFT consensus** - Every operation runs across multiple independent nodes with Byzantine Fault Tolerant consensus
- **Trigger types** - Cron schedules, log-based triggers, and custom event triggers
- **Simulation** - Workflows compile to WASM and can be simulated locally against live APIs/chains
- **Lifecycle management** - Deploy, activate, pause, update, and delete workflows via CLI

### Architecture

```
Workflow DON (monitors triggers, coordinates execution)
    |
    +-- Capability DON A (e.g., off-chain data fetching)
    +-- Capability DON B (e.g., on-chain writes)
    +-- ...
```

Each node performs tasks independently; results are cryptographically verified and aggregated via BFT.

### Relevance to ChaosOracle

ChaosOracle uses four CRE triggers:

| Trigger | Type | Purpose |
|---------|------|---------|
| 1 | Cron (hourly) | Check deadlines, create studios for ready markets |
| 2 | LogTrigger (`StudioScoresSubmitted`) | Check `canClose()`, close epoch when ready |
| 3 | Cron (every 5 min) | Backup check for closable studios |
| 4 | LogTrigger (`MarketRegistered`) | Monitoring/logging |

CRE is the only entity authorized to call `createStudioForMarket()` and `closeStudioEpoch()` on the
Registry, enforced via the `onlyCRE` modifier that verifies both the Chainlink forwarder address and
the specific workflow ID.

---

## 3. ERC-8004: Trustless Agents

- **Source:** [eips.ethereum.org/EIPS/eip-8004](https://eips.ethereum.org/EIPS/eip-8004)
- **Discussion:** [Ethereum Magicians thread](https://ethereum-magicians.org/t/erc-8004-trustless-agents/25098)
- **Status:** Peer review (created August 13, 2025)
- **Authors:** Marco De Rossi (MetaMask), Davide Crapis (Ethereum Foundation), Jordan Ellis (Google), Erik Reppel (Coinbase)
- **Role in ChaosOracle:** Identity - portable on-chain reputation for agents

### Summary

ERC-8004 is an Ethereum standard for autonomous AI agent identity, reputation, and validation. It
establishes lightweight on-chain registries that enable agents to discover each other, build
verifiable reputations, and collaborate securely without pre-existing trust relationships.

### Three Core Registries

| Registry | Purpose |
|----------|---------|
| **Identity Registry** | ERC-721-based on-chain handle resolving to an agent's registration file. Makes every agent compatible with existing wallet/marketplace infrastructure. |
| **Reputation Registry** | Structured, verifiable feedback. Agents use their on-chain `agentWallet` metadata as `clientAddress` for reputation aggregation. |
| **Validation Registry** | Framework for requesting and recording independent verification of agent work (for high-stakes scenarios). |

### Trust Models

Developers can choose from:
- Reputation systems using client feedback
- Validation via stake-secured re-execution
- Zero-knowledge machine learning (zkML) proofs
- Trusted execution environment (TEE) oracles

### Cross-Chain Compatibility

Aligns with CAIP-10 for cross-chain agent identity. Registries deployed as singletons per chain.
An agent registered on chain A can operate on other chains.

### Relevance to ChaosOracle

After studio settlement (`closeEpoch()`), agent reputation scores are published to ERC-8004.
Workers and verifiers build portable, on-chain reputation based on their settlement accuracy,
enabling a trust layer where better-performing agents can be preferred for future markets.

---

## 4. x402: Internet Native Payments

- **Source:** [github.com/coinbase/x402](https://github.com/coinbase/x402)
- **Role in ChaosOracle:** Payment protocol for agent-to-agent transactions

### Summary

x402 is an open-source payments standard built on HTTP status code 402 (Payment Required). It
enables internet-native transactions that are network, token, and currency agnostic, supporting
both crypto and fiat payment rails.

### Architecture

Three primary actors:

| Actor | Role |
|-------|------|
| **Client** | Entity requesting a paid resource |
| **Resource Server** | HTTP server providing the paid content |
| **Facilitator** | Service handling payment verification and blockchain settlement |

### Payment Flow

1. Client requests a resource
2. Server responds with HTTP 402 + payment requirements
3. Client constructs a payment payload using their chosen scheme/network
4. Facilitator verifies and settles the transaction on-chain
5. Resource server delivers the requested content

### Design Principles

- Permissionless access
- Backward compatibility with standard HTTP
- Trust-minimization (prevents unauthorized fund movement)
- Minimal integration effort ("1 line for the server, 1 function for the client")

### Relevance to ChaosOracle

x402 enables AI agents participating in ChaosOracle settlements to pay for services and data
they need during research (worker agents) or auditing (verifier agents). The ChaosChain SDK v0.4.0
integrates x402 v2.0 for cryptographic agent-to-agent USDC transactions.

---

## 5. ChaosChain SDK (Python)

- **Source:** [pypi.org/project/chaoschain-sdk](https://pypi.org/project/chaoschain-sdk/)
- **Version:** 0.4.0 (released January 30, 2026)
- **Requires:** Python >= 3.9
- **Role in ChaosOracle:** Agent development toolkit for workers and verifiers

### Summary

Production-ready Python SDK for building verifiable, monetizable AI agents on ChaosChain.

### Key Components

| Class | Purpose |
|-------|---------|
| `ChaosChainAgentSDK` | Main initialization - agent setup, network config, gateway connection |
| `X402PaymentManager` | Cryptocurrency transactions via x402 protocol |
| `X402PaywallServer` | Payment-gated HTTP endpoints for agent services |
| `WalletManager` | Blockchain wallet interactions |
| `GatewayClient` | Interface with the ChaosChain Gateway orchestration service |

### Design Pattern

Follows a **Gateway-first** architecture where DKG computation happens server-side rather than
locally. This enables crash-resilient workflows and simplifies the agent developer experience.

### Key Capabilities

- **ERC-8004 Agent Identity** - Register AI agents on Ethereum with unique on-chain identities
- **x402 Payments** - Cryptographic agent-to-agent transactions using USDC
- **Paywall Server** - HTTP 402-based monetization layer
- **Storage backends** - Optional integrations with Pinata, Arweave, IPFS, 0g-Storage, Ario

### Relevance to ChaosOracle

Both Worker and Verifier agents use this SDK to:
1. Register on-chain identity (`register_agent()`)
2. Join studios (`register_with_studio()`)
3. Submit work or scores via Gateway (`submit_work_via_gateway()`, `submit_score_via_gateway()`)
4. Manage staking and wallet operations

---

## 6. Supporting Infrastructure

### Arweave

- **Purpose:** Permanent storage for evidence payloads and reasoning chains
- **Usage:** Workers upload evidence packages; verifiers and users can fetch full AI reasoning
  from settlement proofs via `evidenceCID` references

### Base Sepolia

- **Purpose:** Primary testnet deployment target for ChaosOracle contracts
- **Type:** Ethereum L2 testnet (Coinbase's Base network)

### Foundry

- **Purpose:** Solidity development toolchain for contract compilation and deployment
- **Commands used:** `forge create` for deployment, `cast call` for verification

---

## Source Dependency Map

```
ChaosOracle
    |
    +-- Chainlink CRE ............. Orchestration (triggers, workflow execution)
    |       |
    |       +-- CRE SDK (TypeScript) .. Workflow definition
    |       +-- CRE CLI ............... Build, simulate, deploy
    |       +-- DON ................... Decentralized execution
    |
    +-- ChaosChain ................ Verification (consensus, rewards)
    |       |
    |       +-- Studios ............... On-chain collaboration
    |       +-- DKG ................... Evidence graph
    |       +-- Gateway ............... Off-chain orchestration
    |       +-- ChaosChain SDK (Python) Agent development
    |
    +-- ERC-8004 .................. Identity & Reputation
    |       |
    |       +-- Identity Registry ..... Agent NFT handles
    |       +-- Reputation Registry ... Feedback aggregation
    |       +-- Validation Registry ... Independent verification
    |
    +-- x402 ...................... Payments
    |       |
    |       +-- HTTP 402 flow ......... Payment negotiation
    |       +-- USDC settlement ....... On-chain payment
    |
    +-- Arweave ................... Evidence storage
    +-- Base Sepolia .............. Testnet deployment
```
