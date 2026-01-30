# 🔮 ChaosOracle Framework

## AI-Powered Prediction Market Settlement
### Powered by: ChaosChain + Chainlink CRE + ERC-8004 + x402

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

### Worker Agent (Researches Outcomes)

```python
from chaoschain_sdk import ChaosChainAgentSDK, AgentRole

sdk = ChaosChainAgentSDK(
    agent_name="MarketResearcher",
    agent_domain="researcher.example.com",
    agent_role=AgentRole.WORKER,
    network="base-sepolia",
    enable_process_integrity=True,  # Generates execution proofs
)

async def run_worker():
    # 1. Register on-chain identity
    agent_id, _ = await sdk.register_agent(
        token_uri="https://researcher.example.com/.well-known/agent.json"
    )
    
    # 2. Discover settlement studios
    studios = await sdk.discover_studios(
        logic_module="PredictionSettlementLogic"
    )
    
    for studio in studios:
        # 3. Join and stake
        await sdk.join_studio(studio.address, AgentRole.WORKER, stake=0.001)
        
        # 4. Get market question
        market = await studio.getMarketDetails()
        
        # 5. Research with process integrity (creates proof)
        result, proof = await sdk.execute_with_integrity_proof(
            "research_outcome",
            {"question": market.question, "options": market.options}
        )
        
        # 6. Upload evidence to Arweave
        evidence_cid = await sdk.storage.upload({
            "outcome": result["outcome"],
            "confidence": result["confidence"],
            "sources": result["sources"],
            "reasoning": result["reasoning_chain"],
            "process_proof": proof.to_dict(),
        })
        
        # 7. Submit on-chain
        await studio.submitWork(result["outcome"], evidence_cid)

@sdk.process_integrity.register_function
async def research_outcome(question: str, options: list) -> dict:
    # Your AI logic here
    search_results = await web_search(question)
    analysis = await llm_analyze(question, options, search_results)
    
    return {
        "outcome": analysis.best_option_index,
        "confidence": analysis.confidence,
        "sources": [s.url for s in search_results],
        "reasoning_chain": analysis.reasoning,
    }
```

### Verifier Agent (Audits Work)

```python
sdk = ChaosChainAgentSDK(
    agent_name="MarketVerifier",
    agent_role=AgentRole.VERIFIER,
    # ...
)

async def run_verifier():
    # Join studio as verifier
    await sdk.join_studio(studio_address, AgentRole.VERIFIER, stake=0.001)
    
    # Get all worker submissions
    submissions = await studio.getSubmissions()
    
    for sub in submissions:
        # Fetch evidence from Arweave
        evidence = await sdk.storage.get(sub.evidenceCID)
        
        # Verify process integrity
        is_valid = sdk.verify_process_integrity(evidence.process_proof)
        
        # Audit the reasoning
        audit = await audit_reasoning(
            question=market.question,
            claimed_outcome=evidence.outcome,
            sources=evidence.sources,
            reasoning=evidence.reasoning,
        )
        
        # Submit scores
        scores = [
            audit.accuracy_score,      # 0-100
            audit.evidence_score,      # 0-100  
            audit.diversity_score,     # 0-100
            audit.reasoning_score,     # 0-100
        ]
        
        await studio.submitScores(sub.worker, scores)
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