# ChaosOracle Framework — Technical Documentation

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
| **Chainlink CRE** | Orchestration - triggers studio creation & closeEpoch |
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
|   - Only CRE can call createStudioForMarket() and closeStudioEpoch() |
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
|   TRIGGER 2: LogTrigger on StudioScoresSubmitted                     |
|     -> Check canClose() -> If ready, call closeStudioEpoch()         |
|                                                                       |
|   TRIGGER 3: Cron (every 5 min) - Backup                            |
|     -> Check all studios -> Close any that are ready                 |
|                                                                       |
|   TRIGGER 4: LogTrigger on MarketRegistered                          |
|     -> Monitoring/logging only                                        |
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
|     - Submit outcome + evidenceCID (Arweave link to reasoning)       |
|                                                                       |
|   Verifiers:                                                          |
|     - Stake tokens to participate                                     |
|     - Audit worker submissions                                        |
|     - Submit scores [accuracy, evidence, diversity, reasoning]       |
|     - Scores trigger StudioScoresSubmitted event via Registry        |
|                                                                       |
|   closeEpoch() (only callable by CRE via Registry):                  |
|     - Calculate consensus outcome (weighted by verifier scores)      |
|     - Distribute rewards (correct workers win, wrong workers slashed)|
|     - Call predictionMarket.onSettlement()                            |
|     - Publish reputation to ERC-8004                                  |
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

function closeStudioEpoch(address studio, bytes calldata creReport)
    external onlyCRE(creReport) { ... }
```

### 2. Event Aggregation (Registry as Hub)

Studios emit events to Registry, CRE listens to single address:

```solidity
// PredictionSettlementLogic.sol (in Studio)
function submitScores(...) external {
    // ... scoring logic ...

    // Notify registry (CRE listens to Registry, not individual studios)
    registry.onScoresSubmitted(submissions.length, verifierScores.length);
}

// ChaosOracleRegistry.sol
function onScoresSubmitted(uint256 totalSubmissions, uint256 totalScores) external {
    require(isActiveStudio[msg.sender], "Unknown studio");

    // CRE workflow listens to this event
    emit StudioScoresSubmitted(msg.sender, studioToMarketKey[msg.sender], totalSubmissions, totalScores);
}
```

### 3. Settlement Authorization

```
PredictionMarket.setSettler()    <- Only CRE can call (via Registry)
PredictionMarket.onSettlement()  <- Only the authorized Studio can call
Studio.closeEpoch()              <- Only CRE can call (via Registry)
```

---

## Complete Flow

### Phase 1: Market Registration

The prediction market calls `registerForSettlement{value: reward}(marketId, question, options, deadline)` on the Registry. The Registry stores the pending market and emits `MarketRegistered`. CRE Trigger 4 logs it for monitoring.

### Phase 2: Studio Creation (CRE Trigger 1 — Every 5 min Cron)

CRE calls `getMarketsReadyForSettlement()` on the Registry. For each market past its deadline, CRE calls `createStudioForMarket(key, proof)`. The Registry creates a Studio (via StudioProxyFactory), funds it with the settlement reward, and calls `predictionMarket.setSettler()`. Emits `StudioCreated`.

### Phase 3: Worker Participation

Worker agents discover the studio, call `registerAsWorker{value: stake}()`, then research the market question (web search + LLM analysis). They submit their outcome + evidence CID via `submitWork(outcome, evidenceCID)`.

### Phase 4: Verifier Scoring

Verifier agents discover worker submissions, call `registerAsVerifier{value: stake}()`, fetch evidence from Arweave, audit it (LLM or heuristic), and submit scores via `submitScores(worker, [accuracy, evidenceQuality, sourceDiversity, reasoningDepth])`. Each score submission notifies the Registry via `onScoresSubmitted()`, which emits `StudioScoresSubmitted` for CRE.

### Phase 5: Settlement (CRE Trigger 2 — On Scores Submitted)

CRE checks `canClose()` on the studio. If enough workers and verifiers have participated, CRE calls `closeStudioEpoch(studio, proof)` via the Registry. The studio computes weighted consensus, distributes rewards, slashes wrong workers, and calls `predictionMarket.onSettlement(marketId, outcome, proofHash)`.

### Phase 6: User Claims

Users call `claimWinnings(marketId)` on the prediction market. The market checks the settled outcome and transfers winnings. Users can verify settlement by fetching evidence CIDs from Arweave to see the full AI reasoning chain.

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
function closeStudioEpoch(address studio, bytes calldata creReport) external;

// Studios call these to aggregate events
function onScoresSubmitted(uint256 totalSubmissions, uint256 totalScores) external;
function onStudioSettled(uint8 outcome, bytes32 proofHash) external;
```

#### PredictionSettlementLogic (Studio)

```solidity
// Agent registration
function registerAsWorker() external payable;
function registerAsVerifier() external payable;

// Worker submits research
function submitWork(uint8 outcome, string calldata evidenceCID) external;

// Verifier scores work
function submitScores(address worker, uint8[4] calldata scores) external;

// CRE closes epoch (via Registry)
function closeEpoch() external; // onlyCRE via Registry
```

#### IChaosOracleSettleable (Your Contract)

```solidity
interface IChaosOracleSettleable {
    // CRE sets which studio can settle this market
    function setSettler(uint256 marketId, address settler) external;

    // Studio calls this when consensus is reached
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
| 2 | LogTrigger | `StudioScoresSubmitted` | Check `canClose()` -> Close epoch |
| 3 | Cron | Every 5 min | Backup check all studios |
| 4 | LogTrigger | `MarketRegistered` | Monitoring/logging |

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
        // TRIGGER 2: Close epochs when ready
        handler(
            evmClient.logTrigger({ addresses: [config.registryAddress] }),
            onStudioScoresSubmitted
        ),
        // TRIGGER 3: Backup cron
        handler(
            cronCapability.trigger({ schedule: "*/5 * * * *" }),
            onCheckClosableStudios
        ),
        // TRIGGER 4: Monitor registrations
        handler(
            evmClient.logTrigger({ addresses: [config.registryAddress] }),
            onMarketRegistered
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
        address settler;      // Set by CRE
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
            settler: address(0),
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

    function setSettler(uint256 marketId, address settler) external override {
        require(msg.sender == chaosOracle.creForwarder(), "Only CRE");
        require(markets[marketId].settler == address(0), "Already set");
        markets[marketId].settler = settler;
    }

    function onSettlement(
        uint256 marketId, uint8 outcome, bytes32 proofHash
    ) external override {
        require(msg.sender == markets[marketId].settler, "Only settler");
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
| 6 | Edit `config.staging.json` -> set `registryAddress` to your Registry |
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
| 20 | `cd demo && ./create_market.sh` — creates market + registers for settlement |
| 21 | `./place_bet.sh` — place bets on both sides |
| 22 | Wait for market deadline to pass |
| 23 | CRE Trigger 1 fires -> creates ChaosChain Studio automatically |
| 24 | Worker agents discover studio -> research -> submit evidence |
| 25 | Verifier agents audit evidence -> submit scores |
| 26 | CRE Trigger 2/3 fires -> `closeEpoch()` -> consensus -> settlement |
| 27 | `./check_settlement.sh` — verify outcome |

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
