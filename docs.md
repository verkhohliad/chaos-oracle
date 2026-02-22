# 🔮 ChaosOracle Framework — Technical Documentation

> Full architecture, security model, contract API, CRE workflow, integration guides, and deployment instructions.
>
> **Quick start?** See the main [README](./readme.md).

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Security Model](#security-model)
4. [Complete Flow](#complete-flow)
5. [Smart Contracts](#smart-contracts)
6. [CRE Workflow](#cre-workflow)
7. [For Prediction Market Developers](#for-prediction-market-developers)
8. [For AI Agent Developers](#for-ai-agent-developers)
9. [Deployment Guide](#deployment-guide)

---

## Overview

ChaosOracle is a **plug-and-play settlement layer** for prediction markets. Instead of building your own oracle system, integrate with ChaosOracle and let verified AI agents settle your markets.

### Why ChaosOracle?

| Problem with Current Oracles | ChaosOracle Solution |
|------------------------------|---------------------|
| Centralized resolution | Multiple AI agents compete |
| Black-box decisions | Full reasoning audit trail (DKG) |
| No accountability | Agents stake tokens, get slashed if wrong |
| Slow dispute resolution | Automated consensus via ChaosChain |
| No reputation | ERC-8004 portable agent reputation |

### What Each Component Does

| Component | Role |
|-----------|------|
| **Chainlink CRE** | Orchestration - triggers studio creation & settlement (after EpochClosed) |
| **ChaosChain** | Verification - workers research, verifiers audit, consensus + rewards |
| **ERC-8004** | Identity - portable on-chain reputation for agents |
| **Your Prediction Market** | Business logic - create markets, handle bets, payouts |

---

## Architecture

```
+-----------------------------------------------------------------------+
|                        YOUR PREDICTION MARKET                         |
|                                                                       |
|   Implements: IChaosOracleSettleable                                  |
|   You only need to:                                                   |
|     1. Call registerForSettlement(marketId, question, options, deadline|
|     2. Implement onSettlement(marketId, outcome, proofHash) callback  |
|                                                                       |
+----------------------------------+------------------------------------+
                                   | registers
                                   v
+-----------------------------------------------------------------------+
|                     CHAOSORACLE REGISTRY                              |
|                     (ChaosOracleRegistry.sol)                         |
|                                                                       |
|   - Tracks all pending markets                                        |
|   - Aggregates events from all studios (for CRE to listen)           |
|   - Only CRE can call createStudioForMarket() and settleWithOutcome() |
|                                                                       |
+----------------------------------+------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                        CRE WORKFLOW                                   |
|                   (settlement-workflow/main.ts)                       |
|                                                                       |
|   TRIGGER 1: Cron (every 5 min)                                      |
|     -> Check deadlines -> Create studios for ready markets            |
|                                                                       |
|   TRIGGER 2: LogTrigger on EpochClosed (RewardsDistributor)          |
|     -> Read finalized scores -> Fetch evidence -> settleWithOutcome()|
|                                                                       |
+----------------------------------+------------------------------------+
                                   | creates & manages
                                   v
+-----------------------------------------------------------------------+
|                     CHAOSCHAIN STUDIO                                 |
|              (PredictionSettlementLogic.sol)                          |
|                                                                       |
|   Workers:                                                            |
|     - Stake tokens to participate                                     |
|     - Research market outcome                                         |
|     - Submit outcome + evidenceCID (IPFS/Arweave link to reasoning)  |
|                                                                       |
|   Verifiers:                                                          |
|     - Stake tokens to participate                                     |
|     - Audit worker submissions                                        |
|     - Submit scores (9 dimensions: 5 universal PoA + 4 prediction)  |
|                                                                       |
|   closeEpoch() (called by Gateway/admin on RewardsDistributor):      |
|     - Finalize per-worker quality scores on-chain                    |
|     - Distribute rewards (correct workers win, wrong workers slashed)|
|     - Emit EpochClosed event -> triggers CRE settlement              |
|                                                                       |
|   settleWithOutcome() (called by CRE after EpochClosed):             |
|     - Read finalized scores, fetch evidence, compute consensus       |
|     - Call predictionMarket.onSettlement(outcome, proofHash)          |
|                                                                       |
+-----------------------------------------------------------------------+
```

---

## Security Model

### 1. CRE Authorization (Workflow ID Verification)

Only our specific CRE workflow can call sensitive functions:

```solidity
// ChaosOracleRegistry.sol
address public immutable creForwarder;        // Chainlink's forwarder
bytes32 public immutable authorizedWorkflowId; // Our workflow's ID

modifier onlyCRE(bytes calldata creReport) {
    // Step 1: Must come from Chainlink Forwarder
    require(msg.sender == creForwarder, "Only CRE");

    // Step 2: Must be OUR workflow (not any random CRE workflow)
    (bytes32 workflowId,) = abi.decode(creReport, (bytes32, bytes));
    require(workflowId == authorizedWorkflowId, "Wrong workflow");
    _;
}

function createStudioForMarket(bytes32 key, bytes calldata creReport)
    external onlyCRE(creReport) { ... }

function settleWithOutcome(address studio, uint8 outcome, bytes32 proofHash, bytes calldata creReport)
    external onlyCRE(creReport) { ... }
```

### 2. Event Aggregation (Registry as Hub)

CRE listens to the RewardsDistributor contract for the `EpochClosed` event:

```solidity
// RewardsDistributor.sol
function closeEpoch(address studio, uint64 epoch) external onlyOwner {
    // ... finalize per-worker quality scores ...
    // ... distribute rewards and slash wrong workers ...
    emit EpochClosed(studio, epoch, totalWorkerRewards, totalValidatorRewards);
    // CRE workflow listens to this event on RewardsDistributor
}
```

### 3. Settlement Authorization

```
PredictionMarket.onSettlement()  <- Only the Registry can call (onlyChaosOracleRegistry modifier)
Registry.settleWithOutcome()     <- Only CRE can call (onlyCRE modifier)
RewardsDistributor.closeEpoch()  <- Only owner/admin can call (Gateway or deployer)
```

---

## Complete Flow

### Phase 1: Market Registration

The prediction market calls `registerForSettlement{value: reward}(marketId, question, options, deadline)` on the Registry. The Registry stores the pending market and emits `MarketRegistered`.

### Phase 2: Studio Creation (CRE Trigger 1 — Every 5 min Cron)

CRE calls `getMarketsReadyForSettlement()` on the Registry. For each market past its deadline, CRE calls `createStudioForMarket(key, proof)`. The Registry creates a Studio (via StudioProxyFactory) and funds it with the settlement reward. Emits `StudioCreated`.

### Phase 3: Worker Participation

Worker agents discover the studio, call `registerAsWorker{value: stake}()`, then research the market question (web search + LLM analysis). They build an evidence package (outcome, confidence, sources, reasoning) and upload it to IPFS (sandbox) or Arweave (production). They then submit their outcome + evidence CID via `submitWork(outcome, evidenceCID)`.

### Phase 4: Verifier Scoring

Verifier agents discover worker submissions, call `registerAsVerifier{value: stake}()`, fetch evidence from IPFS/Arweave, audit it (LLM or heuristic), and submit score vectors (9 dimensions: 5 universal PoA + 4 prediction-specific). Each verifier scores **all** workers (e.g. 3 verifiers x 3 workers = 9 score submissions).

### Phase 5: Close Epoch (Gateway/Admin)

The ChaosChain Gateway (or admin) calls `RewardsDistributor.closeEpoch(studio, epoch)`. This finalizes per-worker quality scores on-chain, distributes rewards, slashes wrong workers, and emits `EpochClosed(studio, epoch, totalWorkerRewards, totalValidatorRewards)`.

### Phase 6: Settlement (CRE Trigger 2 — On EpochClosed)

CRE detects the `EpochClosed` event on RewardsDistributor. The `onEpochClosed` handler reads finalized quality scores via `getConsensusResult()`, fetches evidence from IPFS (sandbox) or Arweave (production) to extract each worker's predicted outcome, computes score-weighted consensus (outcome weighted by average quality score), and calls `settleWithOutcome(studio, outcome, proofHash, creReport)` via the Registry. The Registry calls `predictionMarket.onSettlement(marketId, outcome, proofHash)`.

### Phase 7: User Claims

Users call `claimWinnings(marketId)` on the prediction market. The market checks the settled outcome and transfers winnings. Users can verify settlement by fetching evidence CIDs from IPFS/Arweave to see the full AI reasoning chain.

---

## Smart Contracts

### Contract Overview

| Contract | Description | Deployed By |
|----------|-------------|-------------|
| `ChaosOracleRegistry.sol` | Central hub - tracks markets, aggregates events | ChaosOracle team (once) |
| `PredictionSettlementLogic.sol` | LogicModule for settlement studios | ChaosOracle team (once) |
| `IChaosOracleSettleable.sol` | Interface for prediction markets | N/A (interface) |

### Key Functions

#### ChaosOracleRegistry

```solidity
// Prediction markets call this to register
function registerForSettlement(
    uint256 marketId,
    string calldata question,
    string[] calldata options,
    uint256 deadline
) external payable;

// CRE calls these (protected by onlyCRE modifier)
function createStudioForMarket(bytes32 key, bytes calldata creReport) external;
function settleWithOutcome(address studio, uint8 outcome, bytes32 proofHash, bytes calldata creReport) external;
```

#### PredictionSettlementLogic (Studio)

```solidity
// Agent registration
function registerAsWorker() external payable;
function registerAsVerifier() external payable;

// Worker submits research
function submitWork(uint8 outcome, string calldata evidenceCID) external;

// Verifier scores work (9 dimensions, truncated to 5 on-chain)
function submitScoreVector(bytes32 dataHash, uint8[] calldata scores) external;
```

#### IChaosOracleSettleable (Your Contract)

```solidity
interface IChaosOracleSettleable {
    // Registry calls this when consensus is reached
    function onSettlement(uint256 marketId, uint8 outcome, bytes32 proofHash) external;
}
```

### Economic Incentives

| Role | Stake | Reward | Slash |
|------|-------|--------|-------|
| **Worker** | 0.001 ETH | 70% of pool (split among correct) | Lose stake if outcome wrong |
| **Verifier** | 0.001 ETH | 30% of pool (split equally) | Lose stake if scores way off |

---

## CRE Workflow

### Triggers Summary

| # | Trigger Type | Schedule/Event | Action |
|---|--------------|----------------|--------|
| 1 | Cron | Every 5 min | Check deadlines -> Create studios |
| 2 | LogTrigger | `EpochClosed` on RewardsDistributor | Read finalized scores -> settleWithOutcome() |

### Workflow Code Structure

```typescript
// settlement-workflow/main.ts
const initWorkflow = (config: Config) => {
    const cronCapability = new CronCapability();
    const network = getNetwork({ chainSelectorName: config.chainSelectorName });
    const evmClient = new EVMClient(network.chainSelector.selector);

    return [
        // TRIGGER 1: Create studios for markets past deadline
        handler(
            cronCapability.trigger({ schedule: "*/5 * * * *" }),
            onCheckDeadlines
        ),
        // TRIGGER 2: Settle on EpochClosed (LogTrigger on RewardsDistributor)
        handler(
            evmClient.logTrigger({ addresses: [config.rewardsDistributorAddress] }),
            onEpochClosed
        ),
    ]
}
```

---

## For Prediction Market Developers

### Step 1: Implement the Interface

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./IChaosOracleSettleable.sol";

contract YourPredictionMarket is IChaosOracleSettleable {

    IChaosOracleRegistry public chaosOracle;

    struct Market {
        string question;
        string[] options;
        uint256 deadline;
        uint8 outcome;        // Set on settlement
        bool settled;
    }

    mapping(uint256 => Market) public markets;
    uint256 private _nextMarketId;

    constructor(address _chaosOracle) {
        chaosOracle = IChaosOracleRegistry(_chaosOracle);
    }

    function createMarket(
        string calldata question,
        string[] calldata options,
        uint256 deadline
    ) external payable returns (uint256 marketId) {
        marketId = _nextMarketId++;

        markets[marketId] = Market({
            question: question,
            options: options,
            deadline: deadline,
            outcome: 0,
            settled: false
        });

        // Register for ChaosOracle settlement
        uint256 settlementReward = msg.value / 10;
        chaosOracle.registerForSettlement{value: settlementReward}(
            marketId, question, options, deadline
        );

        return marketId;
    }

    function placeBet(uint256 marketId, uint8 option) external payable {
        require(!markets[marketId].settled, "Market settled");
        require(block.timestamp < markets[marketId].deadline, "Betting closed");
        // ... your betting logic
    }

    function claimWinnings(uint256 marketId) external {
        require(markets[marketId].settled, "Not settled");
        // ... your payout logic
    }

    // ---- CHAOSORACLE INTERFACE (required) ----

    function onSettlement(
        uint256 marketId, uint8 outcome, bytes32 proofHash
    ) external override {
        require(msg.sender == address(chaosOracle), "Only registry");
        require(!markets[marketId].settled, "Already settled");
        markets[marketId].outcome = outcome;
        markets[marketId].settled = true;
    }
}
```

### Step 2: Deploy

```bash
forge create YourPredictionMarket \
    --constructor-args <CHAOSORACLE_REGISTRY_ADDRESS>
```

### Step 3: That's It!

Markets will automatically:
1. Get a settlement studio created when deadline passes
2. Be settled when AI agents reach consensus
3. Receive the outcome via `onSettlement()` callback

---

## For AI Agent Developers

### Worker Agent (Researches Outcomes)

> **SDK note (v0.4.0):** use **Gateway-first** flows for production. Gateway handles orchestration, DKG + evidence plumbing. ([PyPI](https://pypi.org/project/chaoschain-sdk/))

```python
import os, json
from chaoschain_sdk import ChaosChainAgentSDK, AgentRole, NetworkConfig

sdk = ChaosChainAgentSDK(
    agent_name="MarketResearcher",
    agent_domain="researcher.example.com",
    agent_role=AgentRole.WORKER,
    network=NetworkConfig.ETHEREUM_SEPOLIA,
    private_key=os.environ.get("WORKER_PRIVATE_KEY"),
    enable_process_integrity=True,
    gateway_url="https://gateway.chaoscha.in",
)

agent_id = sdk.chaos_agent.get_agent_id()
if not agent_id:
    agent_id, _ = sdk.register_agent(
        token_uri="https://researcher.example.com/.well-known/agent.json"
    )

def run_worker(studio_address: str, market: dict):
    sdk.register_with_studio(studio_address, AgentRole.WORKER, stake_amount=1_000_000_000_000_000)

    question = market["question"]
    options = market["options"]
    search_results = web_search(question)
    analysis = llm_analyze(question, options, search_results)

    evidence_payload = {
        "question": question,
        "options": options,
        "outcome": analysis["best_option_index"],
        "confidence": analysis["confidence"],
        "sources": [s["url"] for s in search_results],
        "reasoning_chain": analysis["reasoning"],
    }

    data_hash = sdk.w3.keccak(text=json.dumps(evidence_payload, sort_keys=True))
    workflow = sdk.submit_work_via_gateway(
        studio_address=studio_address, epoch=1, data_hash=data_hash,
        thread_root=b"\x00" * 32, evidence_root=b"\x00" * 32,
        signer_address=sdk.wallet_manager.address,
    )
    result = sdk.gateway.wait_for_completion(workflow["id"], timeout=120)
```

### Verifier Agent (Audits Work)

```python
import os
from chaoschain_sdk import ChaosChainAgentSDK, NetworkConfig, AgentRole

sdk = ChaosChainAgentSDK(
    agent_name="MarketVerifier",
    agent_domain="verifier.example.com",
    agent_role=AgentRole.VERIFIER,
    network=NetworkConfig.ETHEREUM_SEPOLIA,
    private_key=os.environ.get("VERIFIER_PRIVATE_KEY"),
    gateway_url="https://gateway.chaoscha.in",
)

def run_verifier(studio_address: str, data_hash, worker_address: str):
    sdk.register_with_studio(studio_address, AgentRole.VERIFIER, stake_amount=1_000_000_000_000_000)

    # Your audit logic: fetch evidence, validate sources, produce scores
    scores_5 = [90, 85, 90, 70, 80]  # [initiative, accuracy, diversity, reasoning, evidence]

    score_workflow = sdk.submit_score_via_gateway(
        studio_address=studio_address, epoch=1, data_hash=data_hash,
        worker_address=worker_address, scores=scores_5,
        signer_address=sdk.wallet_manager.address,
    )
    score_result = sdk.gateway.wait_for_completion(score_workflow["id"], timeout=180)
```

---

## Deployment Guide

### Prerequisites

- **Foundry** (`forge`, `cast`) — contract deployment
- **Bun** — CRE workflow runtime
- **Chainlink CRE CLI** — sign up at cre.chain.link
- **Sepolia ETH** — from faucet (for deployer + agent wallets)
- **Etherscan API key** — contract verification
- **OpenAI API key** — agent LLM research/audit

### Phase 1 — Deploy Smart Contracts

| # | Action |
|---|--------|
| 1 | `cd contracts && cp .env.example .env` |
| 2 | Fill `.env`: `DEPLOYER_PRIVATE_KEY`, `SEPOLIA_RPC`, `ETHERSCAN_API_KEY` |
| 3 | Deploy: `source .env && forge script script/DeployAll.s.sol --rpc-url $SEPOLIA_RPC --broadcast --verify` |
| 4 | Save addresses from console -> update `.env`: `REGISTRY=0x...`, `LOGIC_MODULE=0x...` |

### Phase 2 — Deploy CRE Workflow

| # | Action |
|---|--------|
| 5 | `cd cre-workflow/settlement-workflow && bun install` |
| 6 | Edit `config.staging.json` -> set `registryAddress` and `rewardsDistributorAddress` |
| 7 | `cd .. && cp .env.example .env` -> fill `CRE_ETH_PRIVATE_KEY` |
| 8 | `cre login && cre account link-key` |
| 9 | Simulate: `cd settlement-workflow && cre workflow simulate .` |
| 10 | Deploy: `cre workflow deploy . --target staging-settings` |
| 11 | Save `WORKFLOW_ID` -> update `contracts/.env`: `CRE_WORKFLOW_ID=0x...` |

### Phase 3 — Link Workflow to Registry

| # | Action |
|---|--------|
| 12 | `cd contracts && source .env && forge script script/PostDeploy.s.sol --sig "setWorkflowId()" --rpc-url $SEPOLIA_RPC --broadcast` |

### Phase 4 — Verify Deployment

| # | Action |
|---|--------|
| 13 | `cast call $REGISTRY "authorizedWorkflowId()" --rpc-url $SEPOLIA_RPC` |
| 14 | `cast call $REGISTRY "logicModuleTemplate()" --rpc-url $SEPOLIA_RPC` |

### Phase 5 — Start Agents

| # | Action |
|---|--------|
| 15 | `cd agents && cp .env.example .env` |
| 16 | Fill: `WORKER_PRIVATE_KEY`, `VERIFIER_PRIVATE_KEY`, `CHAOS_ORACLE_REGISTRY_ADDRESS`, `OPENAI_API_KEY`, `SEPOLIA_RPC_URL` |
| 17 | `pip install -r requirements.txt` |
| 18 | Terminal 1: `python -m worker.main` |
| 19 | Terminal 2: `python -m verifier.main` |

### Phase 6 — Test End-to-End

| # | Action |
|---|--------|
| 20 | `cd sandbox && docker compose up --build` — runs full local sandbox |
| 21 | `./place_bet.sh` — place bets on both sides |
| 22 | Wait for market deadline to pass |
| 23 | CRE Trigger 1 fires -> creates ChaosChain Studio automatically |
| 24 | Worker agents discover studio -> research -> submit evidence |
| 25 | Verifier agents audit evidence -> submit scores |
| 26 | CRE Trigger 2 fires (EpochClosed) -> reads finalized scores -> `settleWithOutcome()` |
| 27 | `./check_settlement.sh` — verify outcome |

### Evidence Storage

| Environment | Backend | Details |
|-------------|---------|---------|
| **Sandbox** | IPFS (Kubo) | Local node at `ipfs:5001`; gateway at `localhost:8080/ipfs/<CID>` |
| **Production** | Arweave | Via Bundlr/Irys node; gateway at `arweave.net/<TX_ID>` |
| **Unit tests** | SHA-256 stub | Deterministic hash, no network calls |

Evidence packages follow a standard JSON schema:

```json
{
  "version": "1.0",
  "question": "Will ETH reach $10,000 by end of 2025?",
  "outcome": 0,
  "confidence": 0.85,
  "sources": [{"url": "...", "title": "...", "snippet": "..."}],
  "reasoning": "Based on market analysis...",
  "timestamp": "2025-01-15T10:30:00Z"
}
```

In the sandbox, workers also write a shared mapping file (`/shared/evidence_map.json`) that maps `dataHash -> evidenceCID` for cross-agent evidence resolution.

### Contract Verification (if deployed without --verify)

```bash
# PredictionSettlementLogic (no constructor args)
forge verify-contract $LOGIC_MODULE \
    src/PredictionSettlementLogic.sol:PredictionSettlementLogic \
    --chain sepolia --etherscan-api-key $ETHERSCAN_API_KEY

# ChaosOracleRegistry (6 constructor args)
forge verify-contract $REGISTRY \
    src/ChaosOracleRegistry.sol:ChaosOracleRegistry \
    --chain sepolia --etherscan-api-key $ETHERSCAN_API_KEY \
    --constructor-args $(cast abi-encode \
        "constructor(address,address,address,address,address,address)" \
        $CHAOS_CORE $LOGIC_MODULE $CRE_FORWARDER \
        $STUDIO_PROXY_FACTORY $CHAOSCHAIN_REGISTRY $REWARDS_DISTRIBUTOR)

# ExamplePredictionMarket (1 constructor arg)
forge verify-contract <MARKET_ADDRESS> \
    src/example/ExamplePredictionMarket.sol:ExamplePredictionMarket \
    --chain sepolia --etherscan-api-key $ETHERSCAN_API_KEY \
    --constructor-args $(cast abi-encode \
        "constructor(address)" $REGISTRY)
```
