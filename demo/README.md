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

**Services** (8 Docker containers):
- `postgres` — Gateway persistence
- `gateway` — ChaosChain Gateway (dual-signer routing)
- `xmtp-bridge` — XMTP messaging bridge for Python agents
- `worker-1`, `worker-2` — AI worker agents
- `verifier-1`, `verifier-2` — AI verifier agents

**Contracts** (deployed on Sepolia):
- ChaosChainRegistry, ChaosCore, RewardsDistributor (deployed by us)
- ChaosOracleRegistry, PredictionSettlementLogic, ExamplePredictionMarket
- StudioProxyFactory, ERC-8004 registries (reused from ChaosChain team)

## Prerequisites

- **Sepolia ETH**: 0.5+ ETH in deployer wallet, 0.05 ETH in each agent wallet
- **API Keys**: OpenAI (`sk-...`), Alchemy/Infura Sepolia RPC
- **Tools**: `foundry` (forge, cast), `docker`, `docker compose`, CRE CLI
- **CRE CLI**: `cre workflow deploy` requires Chainlink CRE access

## Quick Start

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

### 4. Start Services

```bash
cd demo/run
docker compose -f docker-compose.sepolia.yml up --build
```

### 5. Run Demo

```bash
cd demo/run
./orchestrate-sepolia.sh
```

The orchestrator:
1. Creates a prediction market with a 3-minute deadline
2. Places test bets
3. Monitors CRE trigger 1 creating a studio
4. Monitors workers researching and submitting evidence
5. Monitors verifiers auditing and scoring
6. Monitors CRE trigger 3 closing the epoch via Gateway
7. Monitors CRE trigger 2 settling the market
8. Displays results

## Settlement Flow

1. **Market Registration**: `ExamplePredictionMarket.createMarket()` registers with `ChaosOracleRegistry`
2. **Studio Creation**: CRE cron trigger detects deadline passed, calls `createStudioForMarket()` via CRE report
3. **Worker Research**: Workers poll registry, research via OpenAI web_search, build evidence, submit via Gateway
4. **Verifier Audit**: Verifiers fetch evidence from Arweave, audit with OpenAI, submit scores via Gateway
5. **Epoch Close**: CRE cron trigger detects sufficient submissions, calls Gateway `/workflows/close-epoch`
6. **Settlement**: CRE log trigger detects `EpochClosed`, reads finalized scores, computes consensus, calls `settleWithOutcome()`
7. **Withdrawals**: Agents call `withdraw()` on StudioProxy to claim stakes + rewards

## Gateway Dual-Signer Routing

The Gateway uses two types of signers:
- **Agent signer** (per-agent private key): Used for `StudioProxy.submitWork()` and `submitScoreVectorForWorker()`
- **Default signer** (deployer key): Used for `RewardsDistributor.registerWork()`, `registerValidator()`, `closeEpoch()`

This is required because RewardsDistributor operations require owner authority.

## ERC-8004 Verification

After epoch close, query agent reputation:

```bash
cast call --rpc-url $SEPOLIA_RPC \
    0x8004B8FD1A363aa02fDC07635C0c5F94f6Af5B7E \
    "getReputation(address,string)(int128,uint8)" \
    <AGENT_ADDRESS> "prediction-settlement"
```

## Troubleshooting

**CRE trigger not firing**: Check workflow is deployed and authorized (`setAuthorizedWorkflowId`). Verify the CRE Forwarder address matches.

**Gateway signer error**: Ensure all agent private keys are in `.env` as `SIGNER_PRIVATE_KEY_2` through `SIGNER_PRIVATE_KEY_5`.

**Worker/verifier stuck**: Check OpenAI API key is valid. Check RPC URL connectivity. Review container logs: `docker compose -f docker-compose.sepolia.yml logs worker-1`.

**Insufficient gas**: CRE `gasLimit` must be 6M+ for `deployStudioProxy()`. Check `config.sepolia.json`.

**Evidence fetch fails**: Arweave uploads may take 5-10 seconds to propagate. Verifiers retry on next poll cycle.
