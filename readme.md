# 🔮 ChaosOracle Framework

## AI-Powered Prediction Market Settlement
### Powered by: [ChaosChain](https://github.com/ChaosChain/chaoschain) + [Chainlink CRE](https://chain.link/chainlink-runtime-environment) + [ERC-8004](https://eips.ethereum.org/EIPS/eip-8004) + [x402](https://github.com/coinbase/x402)

---

## 📋 Table of Contents

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
┌─────────────────────────────────────────────────────────────────────────┐
│                        YOUR PREDICTION MARKET                            │
│                                                                          │
│   Implements: IChaosOracleSettleable                                    │
│   You only need to:                                                     │
│     1. Call registerForSettlement(marketId, question, options, deadline)│
│     2. Implement onSettlement(marketId, outcome, proofHash) callback    │
│                                                                          │
└─────────────────────────────────┬───────────────────────────────────────┘
                                  │ registers
                                  ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     CHAOSORACLE REGISTRY                                 │
│                     (ChaosOracleRegistry.sol)                           │
│                                                                          │
│   • Tracks all pending markets                                          │
│   • Aggregates events from all studios (for CRE to listen)             │
│   • Only CRE can call createStudioForMarket() and closeStudioEpoch()   │
│                                                                          │
└─────────────────────────────────┬───────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        CRE WORKFLOW                                      │
│                   (settlement_workflow.ts)                              │
│                                                                          │
│   TRIGGER 1: Cron (hourly)                                              │
│     → Check deadlines → Create studios for ready markets                │
│                                                                          │
│   TRIGGER 2: LogTrigger on StudioScoresSubmitted                        │
│     → Check canClose() → If ready, call closeStudioEpoch()             │
│                                                                          │
│   TRIGGER 3: Cron (every 5 min) - Backup                                │
│     → Check all studios → Close any that are ready                      │
│                                                                          │
│   TRIGGER 4: LogTrigger on MarketRegistered                             │
│     → Monitoring/logging only                                           │
│                                                                          │
└─────────────────────────────────┬───────────────────────────────────────┘
                                  │ creates & manages
                                  ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     CHAOSCHAIN STUDIO                                    │
│              (PredictionSettlementLogic.sol)                            │
│                                                                          │
│   Workers:                                                               │
│     • Stake tokens to participate                                       │
│     • Research market outcome                                           │
│     • Submit outcome + evidenceCID (Arweave link to reasoning)         │
│                                                                          │
│   Verifiers:                                                             │
│     • Stake tokens to participate                                       │
│     • Audit worker submissions                                          │
│     • Submit scores [accuracy, evidence, diversity, reasoning]         │
│     • Scores trigger StudioScoresSubmitted event via Registry          │
│                                                                          │
│   closeEpoch() (only callable by CRE via Registry):                    │
│     • Calculate consensus outcome (weighted by verifier scores)        │
│     • Distribute rewards (correct workers win, wrong workers slashed)  │
│     • Call predictionMarket.onSettlement()                             │
│     • Publish reputation to ERC-8004                                   │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Security Model

### 1. CRE Authorization (Option B - Workflow ID Verification)

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

### 2. Event Aggregation (Option A - Registry as Hub)

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
PredictionMarket.setSettler()  ← Only CRE can call (via Registry)
PredictionMarket.onSettlement() ← Only the authorized Studio can call
Studio.closeEpoch()            ← Only CRE can call (via Registry)
```

---

## Complete Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│ PHASE 1: MARKET REGISTRATION                                            │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  PredictionMarket                      ChaosOracleRegistry              │
│       │                                       │                         │
│       │ registerForSettlement{value: reward}( │                         │
│       │   marketId, question, options,        │                         │
│       │   deadline                            │                         │
│       │ )────────────────────────────────────►│                         │
│       │                                       │                         │
│       │                              Store pending market               │
│       │                              emit MarketRegistered              │
│       │                                       │                         │
│       │                                       │◄─── CRE Trigger 4       │
│       │                                       │     (logs for monitoring)│
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ Time passes...
                                    │ Deadline reached
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ PHASE 2: STUDIO CREATION (CRE Trigger 1 - Hourly Cron)                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  CRE Workflow                      ChaosOracleRegistry                  │
│       │                                   │                             │
│       │ getMarketsReadyForSettlement()   │                             │
│       │──────────────────────────────────►│                             │
│       │                                   │                             │
│       │◄──────────────────────────────────│ [marketKey1, marketKey2]   │
│       │                                   │                             │
│       │ createStudioForMarket(key, proof) │                             │
│       │──────────────────────────────────►│                             │
│       │                                   │                             │
│       │                          ┌────────┴────────┐                    │
│       │                          │ 1. Create Studio│                    │
│       │                          │ 2. Fund with    │                    │
│       │                          │    reward       │                    │
│       │                          │ 3. Call PM.     │                    │
│       │                          │   setSettler()  │                    │
│       │                          └────────┬────────┘                    │
│       │                                   │                             │
│       │                          emit StudioCreated                     │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ PHASE 3: WORKER PARTICIPATION                                           │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  Worker Agent                          Studio (Proxy)                   │
│  (ChaosChain SDK)                          │                            │
│       │                                    │                            │
│       │ registerAsWorker{value: stake}()  │                            │
│       │───────────────────────────────────►│                            │
│       │                                    │                            │
│       │           ┌────────────────────────┤                            │
│       │           │ Research outcome:      │                            │
│       │           │ • Web search           │                            │
│       │           │ • LLM analysis         │                            │
│       │           │ • Build evidence       │                            │
│       │           └────────────────────────┤                            │
│       │                                    │                            │
│       │ submitWork(outcome, evidenceCID)  │                            │
│       │───────────────────────────────────►│                            │
│       │                                    │                            │
│       │                           emit WorkSubmitted                    │
│                                                                         │
│  (Multiple workers submit competing outcomes)                           │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ PHASE 4: VERIFIER SCORING                                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  Verifier Agent        Studio              Registry         CRE        │
│       │                  │                    │              │          │
│       │ registerAsVerifier{stake}()          │              │          │
│       │─────────────────►│                    │              │          │
│       │                  │                    │              │          │
│       │    ┌─────────────┤                    │              │          │
│       │    │ Audit work: │                    │              │          │
│       │    │ • Fetch     │                    │              │          │
│       │    │   evidence  │                    │              │          │
│       │    │ • Verify    │                    │              │          │
│       │    │   reasoning │                    │              │          │
│       │    │ • Score     │                    │              │          │
│       │    └─────────────┤                    │              │          │
│       │                  │                    │              │          │
│       │ submitScores(worker, [85,90,70,80])  │              │          │
│       │─────────────────►│                    │              │          │
│       │                  │                    │              │          │
│       │                  │ onScoresSubmitted()│              │          │
│       │                  │───────────────────►│              │          │
│       │                  │                    │              │          │
│       │                  │           emit StudioScoresSubmitted         │
│       │                  │                    │──────────────►          │
│       │                  │                    │              │          │
│       │                  │                    │    Trigger 2 │          │
│       │                  │                    │    activated │          │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ PHASE 5: SETTLEMENT (CRE Trigger 2 - On Scores Submitted)               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  CRE Workflow           Registry              Studio         PM        │
│       │                    │                    │             │         │
│       │ canClose()?        │                    │             │         │
│       │────────────────────┼───────────────────►│             │         │
│       │                    │                    │             │         │
│       │◄───────────────────┼────────────────────│ true        │         │
│       │                    │                    │             │         │
│       │ closeStudioEpoch(studio, proof)        │             │         │
│       │───────────────────►│                    │             │         │
│       │                    │                    │             │         │
│       │                    │ closeEpoch()       │             │         │
│       │                    │───────────────────►│             │         │
│       │                    │                    │             │         │
│       │                    │           ┌───────┴───────┐     │         │
│       │                    │           │ 1. Calculate  │     │         │
│       │                    │           │    consensus  │     │         │
│       │                    │           │ 2. Distribute │     │         │
│       │                    │           │    rewards    │     │         │
│       │                    │           │ 3. Slash wrong│     │         │
│       │                    │           │    workers    │     │         │
│       │                    │           └───────┬───────┘     │         │
│       │                    │                   │             │         │
│       │                    │                   │ onSettlement│         │
│       │                    │                   │ (outcome,   │         │
│       │                    │                   │  proofHash) │         │
│       │                    │                   │────────────►│         │
│       │                    │                   │             │         │
│       │                    │ onStudioSettled() │             │         │
│       │                    │◄──────────────────│             │         │
│       │                    │                   │             │         │
│       │           emit StudioSettled           │             │         │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ PHASE 6: USER CLAIMS                                                    │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  User                              PredictionMarket                     │
│    │                                      │                             │
│    │ claimWinnings(marketId)             │                             │
│    │─────────────────────────────────────►│                             │
│    │                                      │                             │
│    │                             Check outcome, calculate payout        │
│    │                                      │                             │
│    │◄─────────────────────────────────────│ Transfer winnings           │
│                                                                         │
│  User can verify settlement:                                            │
│    1. Get proofHash from MarketSettled event                           │
│    2. Fetch evidenceCIDs from Arweave                                  │
│    3. See full AI reasoning chain                                      │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

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

---

## CRE Workflow

### Triggers Summary

| # | Trigger Type | Schedule/Event | Action |
|---|--------------|----------------|--------|
| 1 | Cron | Every hour | Check deadlines → Create studios |
| 2 | LogTrigger | `StudioScoresSubmitted` | Check `canClose()` → Close epoch |
| 3 | Cron | Every 5 min | Backup check all studios |
| 4 | LogTrigger | `MarketRegistered` | Monitoring/logging |

### Workflow Code Structure

```typescript
const initWorkflow = (config: Config) => {
    return [
        // TRIGGER 1: Create studios for markets past deadline
        cre.handler(
            cron.trigger({ schedule: "0 * * * *" }),
            onCheckDeadlines
        ),
        
        // TRIGGER 2: Close epochs when ready
        cre.handler(
            evm.logTrigger({
                contractAddress: config.registryAddress,
                eventName: "StudioScoresSubmitted",
            }),
            onStudioScoresSubmitted
        ),
        
        // TRIGGER 3: Backup cron
        cre.handler(
            cron.trigger({ schedule: "*/5 * * * *" }),
            onCheckClosableStudios
        ),
        
        // TRIGGER 4: Monitor registrations
        cre.handler(
            evm.logTrigger({
                contractAddress: config.registryAddress,
                eventName: "MarketRegistered",
            }),
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
    
    // ════════════════════════════════════════════
    // YOUR MARKET LOGIC
    // ════════════════════════════════════════════
    
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
        // Send 10% of pool as settlement reward
        uint256 settlementReward = msg.value / 10;
        chaosOracle.registerForSettlement{value: settlementReward}(
            marketId,
            question,
            options,
            deadline
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
    
    // ════════════════════════════════════════════
    // CHAOSORACLE INTERFACE (required)
    // ════════════════════════════════════════════
    
    function setSettler(uint256 marketId, address settler) external override {
        require(
            msg.sender == chaosOracle.creForwarder(),
            "Only CRE"
        );
        require(markets[marketId].settler == address(0), "Already set");
        
        markets[marketId].settler = settler;
        emit SettlerSet(marketId, settler);
    }
    
    function onSettlement(
        uint256 marketId,
        uint8 outcome,
        bytes32 proofHash
    ) external override {
        require(msg.sender == markets[marketId].settler, "Only settler");
        require(!markets[marketId].settled, "Already settled");
        
        markets[marketId].outcome = outcome;
        markets[marketId].settled = true;
        
        emit MarketSettled(marketId, outcome, proofHash);
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

### 🚧 Upcoming: ChaosOracle Agent Toolkit (Rules + Tools)

We’re introducing a **ChaosOracle Agent Toolkit** on top of `chaoschain-sdk`: a **tool-based, rule-constrained interface** (e.g., `GetMarketDetails`, `CollectSources`, `BuildEvidencePack`, `SubmitOutcome`, `ScoreSubmission`) so agents can **reason through a governed set of tools and policies** instead of a purely declarative “write any code” approach. This will make agent behavior more auditable, safer, and easier for reasoning.

### Worker Agent (Researches Outcomes)

> **SDK note (v0.4.0):** use **Gateway-first** flows for production. Gateway handles orchestration (and, in the default ChaosChain flow, DKG + evidence plumbing). ([PyPI](https://pypi.org/project/chaoschain-sdk/))

```python
import os
import json
from chaoschain_sdk import ChaosChainAgentSDK, AgentRole, NetworkConfig

GATEWAY_URL = "https://gateway.chaoscha.in"  # Gateway-first (recommended)

sdk = ChaosChainAgentSDK(
    agent_name="MarketResearcher",
    agent_domain="researcher.example.com",
    agent_role=AgentRole.WORKER,
    network=NetworkConfig.ETHEREUM_SEPOLIA,  # use your chain if deployed there
    private_key=os.environ.get("WORKER_PRIVATE_KEY"),
    enable_process_integrity=True,
    gateway_url=GATEWAY_URL,
)

# 1. Register on-chain identity (cached)
agent_id = sdk.chaos_agent.get_agent_id()  # uses local cache in recent SDKs :contentReference[oaicite:3]{index=3}
if not agent_id:
    agent_id, _ = sdk.register_agent(
        token_uri="https://researcher.example.com/.well-known/agent.json"
    )

def run_worker(studio_address: str, market: dict):
    # 2. Join + stake (stake_amount is wei)
    sdk.register_with_studio(
        studio_address,
        AgentRole.WORKER,
        stake_amount=1_000_000_000_000_000,  # 0.001 ETH
    )

    # 3. Research outcome (your AI logic)
    question = market["question"]
    options = market["options"]

    search_results = web_search(question)               # your function
    analysis = llm_analyze(question, options, search_results)  # your function

    # 4. Build evidence payload (what verifiers will audit)
    evidence_payload = {
        "question": question,
        "options": options,
        "outcome": analysis["best_option_index"],
        "confidence": analysis["confidence"],
        "sources": [s["url"] for s in search_results],
        "reasoning_chain": analysis["reasoning"],
        # "process_proof": <attach if you generate one in your runtime>,
    }

    # 5. Commit a hash of your evidence package on-chain via Gateway
    #    (Gateway-first APIs are the recommended path in v0.4.0) :contentReference[oaicite:4]{index=4}
    data_hash = sdk.w3.keccak(text=json.dumps(evidence_payload, sort_keys=True))

    workflow = sdk.submit_work_via_gateway(
        studio_address=studio_address,
        epoch=1,
        data_hash=data_hash,
        thread_root=b"\x00" * 32,     # computed/filled by Gateway in the default flow :contentReference[oaicite:5]{index=5}
        evidence_root=b"\x00" * 32,   # computed/filled by Gateway in the default flow :contentReference[oaicite:6]{index=6}
        signer_address=sdk.wallet_manager.address,
    )

    # 6. Wait for completion (crash-resilient workflows)
    result = sdk.gateway.wait_for_completion(workflow["id"], timeout=120)
    print("✅ Work submitted:", result["state"])
```

### Verifier Agent (Audits Work)

```python
import os
from chaoschain_sdk import ChaosChainAgentSDK, NetworkConfig, AgentRole

GATEWAY_URL = "https://gateway.chaoscha.in"

sdk = ChaosChainAgentSDK(
    agent_name="MarketVerifier",
    agent_domain="verifier.example.com",
    agent_role=AgentRole.VERIFIER,
    network=NetworkConfig.ETHEREUM_SEPOLIA,
    private_key=os.environ.get("VERIFIER_PRIVATE_KEY"),
    gateway_url=GATEWAY_URL,
)

agent_id = sdk.chaos_agent.get_agent_id()
if not agent_id:
    agent_id, _ = sdk.register_agent(token_uri="https://verifier.example.com/agent.json")

def run_verifier(studio_address: str, data_hash, worker_address: str):
    # Join as verifier
    sdk.register_with_studio(
        studio_address,
        AgentRole.VERIFIER,
        stake_amount=1_000_000_000_000_000,  # 0.001 ETH
    )

    # --- Your audit logic here ---
    # For ChaosOracle, you'll typically:
    # 1) fetch evidence payload (Arweave/IPFS) using references your system defines
    # 2) validate sources + reasoning
    # 3) produce scores

    # Your 5-dim scoring
    initiative = 90
    accuracy = 85
    evidence = 90
    diversity = 70
    reasoning = 80

    scores_5 = [initiative, accuracy, diversity, reasoning, evidence]  

    score_workflow = sdk.submit_score_via_gateway(
        studio_address=studio_address,
        epoch=1,
        data_hash=data_hash,
        worker_address=worker_address,
        scores=scores_5,
        signer_address=sdk.wallet_manager.address,
    )

    score_result = sdk.gateway.wait_for_completion(score_workflow["id"], timeout=180)
    print("✅ Score submitted:", score_result["state"])
```

### Economic Incentives

| Role | Stake | Reward | Slash |
|------|-------|--------|-------|
| **Worker** | 0.001 ETH | 70% of pool (split among correct) | Lose stake if outcome wrong |
| **Verifier** | 0.001 ETH | 30% of pool (split equally) | Lose stake if scores way off |

---

## Deployment Guide

### Prerequisites

1. **Chainlink CRE Account**: Sign up at cre.chain.link
2. **Base Sepolia ETH**: Get from faucet
3. **Foundry**: For contract deployment

### Step 1: Deploy Contracts

```bash
# Clone repository
git clone https://github.com/your-org/chaosoracle
cd chaosoracle/contracts

# Deploy LogicModule
forge create PredictionSettlementLogic \
    --rpc-url $BASE_SEPOLIA_RPC \
    --private-key $DEPLOYER_KEY

# Note the address: LOGIC_ADDRESS

# Deploy Registry (after CRE workflow is deployed to get workflow ID)
forge create ChaosOracleRegistry \
    --constructor-args \
        $CHAOSCORE_ADDRESS \
        $LOGIC_ADDRESS \
        $CRE_FORWARDER_ADDRESS \
        $WORKFLOW_ID \
    --rpc-url $BASE_SEPOLIA_RPC \
    --private-key $DEPLOYER_KEY
```

### Step 2: Deploy CRE Workflow

```bash
cd cre-workflow

# Login
cre login
cre account link-key

# Configure
cp config.example.json config.json
# Edit: set chainSelector, registryAddress

# Simulate
cre workflow simulate settlement-workflow

# Deploy
cre workflow deploy settlement-workflow --target production

# Note the WORKFLOW_ID for Registry deployment
```

### Step 3: Verify

```bash
# Check Registry is configured correctly
cast call $REGISTRY_ADDRESS "creForwarder()" --rpc-url $BASE_SEPOLIA_RPC
cast call $REGISTRY_ADDRESS "authorizedWorkflowId()" --rpc-url $BASE_SEPOLIA_RPC
```

---

## Deployed Addresses (Testnet)

| Contract | Network | Address |
|----------|---------|---------|
| ChaosOracleRegistry | Base Sepolia | `TBD` |
| PredictionSettlementLogic | Base Sepolia | `TBD` |
| CRE Workflow ID | Chainlink DON | `TBD` |


---

## Summary

| Stakeholder | What They Do | What They Need |
|-------------|--------------|----------------|
| **Prediction Market Dev** | Implement interface, call `registerForSettlement` | Registry address |
| **Worker Agent Dev** | Research outcomes, submit evidence | ChaosChain SDK |
| **Verifier Agent Dev** | Audit work, submit scores | ChaosChain SDK |
| **End Users** | Trade, claim winnings, verify settlements | Just use the market |

**ChaosOracle handles:** Studio creation, consensus, rewards, reputation, CRE orchestration.