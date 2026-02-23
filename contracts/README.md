# 🔮 ChaosOracle Smart Contracts

Foundry project containing the core settlement framework contracts and an example prediction market.

## Addresses

| Contract                    | Sepolia                                                       |
|-----------------------------|---------------------------------------------------------------|
| `ChaosOracleRegistry`       | `0x4D067737D50bFeC0da87Cc782eA144Aeb24c05d5`  |
| `PredictionSettlementLogic` | `0x689FD6DF59eeC5aB4729015cB238330a33a346c5`      |
| `ExamplePredictionMarket`   | `0x64A52A8ce57291cA701F18376f26E224F7E2AEcb` |

## Architecture

```
ChaosOracleRegistry (central hub)
  ├── Receives market registrations (payable)
  ├── Creates ChaosChain Studios via StudioProxyFactory (permissionless)
  ├── Routes CRE Forwarder calls (onlyCRE)
  └── Aggregates studio events for CRE triggers

PredictionSettlementLogic (LogicModule template)
  ├── Deployed once, used by many StudioProxy instances via delegatecall
  ├── Worker registration + work submission
  ├── Verifier registration + score submission
  └── closeEpoch() → score-weighted majority consensus

ExamplePredictionMarket (reference implementation)
  ├── Pool-based binary Yes/No market
  ├── 10% settlement fee → Registry
  └── Pro-rata payout from losing pool to winners
```

## Contracts

| Contract | Description |
|----------|-------------|
| `ChaosOracleRegistry.sol` | Central hub bridging prediction markets to ChaosChain studios |
| `PredictionSettlementLogic.sol` | LogicModule with score-weighted majority voting consensus |
| `ExamplePredictionMarket.sol` | Pool-based binary market implementing `IChaosOracleSettleable` |
| `IChaosOracleSettleable.sol` | Interface prediction markets must implement |
| `IChaosOracleRegistry.sol` | Registry interface with events and functions |
| `MarketKey.sol` | Key derivation library |

### Vendored Dependencies

`src/vendor/chaoschain/` contains ChaosChain interfaces vendored from `github.com/ChaosChain/chaoschain`:
- `IChaosCore.sol` - ChaosCore factory interface
- `IStudioProxy.sol` - Studio proxy interface
- `IStudioProxyFactory.sol` - Permissionless studio proxy factory interface
- `ProtocolConstants.sol` - Universal PoA dimensions
- `LogicModule.sol` - Abstract base for LogicModules

## Setup

```bash
# Install dependencies
forge install

# Build
forge build

# Run tests
forge test

# Run tests with verbosity
forge test -vvv
```

## Tests

90 tests across 7 test suites (86 unit + 4 fork):

| Suite | Tests | Coverage |
|-------|-------|----------|
| `ChaosOracleRegistry.t.sol` | 24 | Constructor, admin, registration, CRE access control, studio creation, escrow, views |
| `ExamplePredictionMarket.t.sol` | 15 | Market creation, betting, settlement, claims, payout math |
| `PredictionSettlementLogic.t.sol` | 6 | Initialize, studio interface, scoring criteria |
| `Integration.t.sol` | 5 | Full lifecycle, multi-market, agent interactions (mock infra) |
| `RewardsAndWithdrawal.t.sol` | 21 | Consensus, budget split (85/10/5), worker/validator rewards, withdrawal flow |
| `ScoringLibrary.t.sol` | 7 | MAD-based consensus: median, outlier filtering, stake weighting |
| `ForkIntegration.t.sol` | 4 | Full lifecycle, ERC-8004 agent registration, RewardsDistributor closeEpoch, withdrawals (real Sepolia) |

```bash
# Unit tests (no fork required)
forge test --skip ForkIntegration
# Ran 6 test suites: 86 tests passed, 0 failed, 0 skipped

# Fork tests (requires Sepolia RPC)
forge test --match-contract ForkIntegration --fork-url $SEPOLIA_RPC -vvv
# Suite result: ok. 4 passed; 0 failed; 0 skipped
```

### Fork Tests

Fork tests run against a Sepolia fork exercising **real ChaosChain infrastructure**:

- **ERC-8004 Identity Registry** — agents mint real identity NFTs via `register()`, verified via `ownerOf()`
- **StudioProxyFactory** — deploys real `StudioProxy` instances (permissionless)
- **StudioProxy** — real agent registration (`registerAgent`), work submission, score vectors
- **RewardsDistributor** — real `closeEpoch` flow: consensus computation, reward distribution, pull-payment withdrawals

### Test Mocks

| Mock | Purpose |
|------|---------|
| `MockChaosCore` | Implements `createStudio()` with deterministic proxy deployment |
| `MockStudioProxyFactory` | Deploys `MockStudioProxy` instances with multi-agent support |
| `MockRewardsDistributor` | Simplified `closeEpoch` with budget split and `releaseFunds` calls |
| `MockPredictionMarket` | Records `onSettlement()` calls |

## Deployment

### Order

1. Deploy `PredictionSettlementLogic` (no dependencies)
2. Deploy `ChaosOracleRegistry(chaosCoreAddr, logicModuleAddr, creForwarderAddr, studioProxyFactoryAddr, chaosChainRegistryAddr, rewardsDistributorAddr)`
3. Deploy `ExamplePredictionMarket(registryAddr)`
4. Deploy CRE Workflow -> get `WORKFLOW_ID`
5. Call `registry.setAuthorizedWorkflowId(WORKFLOW_ID)`

### Deploy contracts

```bash
# Configure
cp .env.example .env
# Edit .env with your keys and addresses

# Deploy all contracts with Etherscan verification
source .env && forge script script/DeployAll.s.sol \
    --rpc-url $SEPOLIA_RPC \
    --broadcast \
    --verify
```

### Post-deployment setup

```bash
# Update .env with deployed addresses:
#   REGISTRY=0x...
#   LOGIC_MODULE=0x...

# Step 1: Deploy CRE workflow via `cre workflow deploy`, then set CRE_WORKFLOW_ID in .env

# Step 2: Set workflow ID on Registry
source .env && forge script script/PostDeploy.s.sol \
    --sig "setWorkflowId()" \
    --rpc-url $SEPOLIA_RPC \
    --broadcast
```

### Verify already-deployed contracts

If contracts were deployed without `--verify`, verify them manually:

```bash
# PredictionSettlementLogic (no constructor args)
forge verify-contract $LOGIC_MODULE \
    src/PredictionSettlementLogic.sol:PredictionSettlementLogic \
    --chain sepolia \
    --etherscan-api-key $ETHERSCAN_API_KEY

# ChaosOracleRegistry (6 constructor args)
forge verify-contract $REGISTRY \
    src/ChaosOracleRegistry.sol:ChaosOracleRegistry \
    --chain sepolia \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    --constructor-args $(cast abi-encode \
        "constructor(address,address,address,address,address,address)" \
        $CHAOS_CORE $LOGIC_MODULE $CRE_FORWARDER \
        $STUDIO_PROXY_FACTORY $CHAOSCHAIN_REGISTRY $REWARDS_DISTRIBUTOR)

# ExamplePredictionMarket (1 constructor arg)
forge verify-contract <MARKET_ADDRESS> \
    src/example/ExamplePredictionMarket.sol:ExamplePredictionMarket \
    --chain sepolia \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    --constructor-args $(cast abi-encode \
        "constructor(address)" $REGISTRY)
```

### Network configs

- `script/config/sepolia.json` - Ethereum Sepolia addresses
- `script/config/base-sepolia.json` - Base Sepolia addresses

## Key Constants

| Constant | Value | Location |
|----------|-------|----------|
| `MIN_WORKERS` | 3 | PredictionSettlementLogic |
| `MIN_VERIFIERS` | 2 | PredictionSettlementLogic |
| `MIN_SCORES_PER_WORKER` | 2 | PredictionSettlementLogic |
| `WORKER_STAKE` | 0.001 ETH | PredictionSettlementLogic |
| `VERIFIER_STAKE` | 0.001 ETH | PredictionSettlementLogic |
| `SETTLEMENT_REWARD_BPS` | 1000 (10%) | ExamplePredictionMarket |

## File Structure

```
contracts/
├── foundry.toml                    # Foundry config (shanghai EVM, OZ v5.0.2)
├── .env.example                    # Environment template
├── src/
│   ├── ChaosOracleRegistry.sol     # Central hub
│   ├── PredictionSettlementLogic.sol # LogicModule template
│   ├── example/
│   │   └── ExamplePredictionMarket.sol
│   ├── interfaces/
│   │   ├── IChaosOracleSettleable.sol
│   │   └── IChaosOracleRegistry.sol
│   ├── libraries/
│   │   └── MarketKey.sol
│   └── vendor/chaoschain/          # Vendored ChaosChain interfaces
├── test/
│   ├── ChaosOracleRegistry.t.sol
│   ├── PredictionSettlementLogic.t.sol
│   ├── ExamplePredictionMarket.t.sol
│   ├── Integration.t.sol
│   ├── RewardsAndWithdrawal.t.sol  # Consensus, rewards, withdrawal flow
│   ├── ScoringLibrary.t.sol        # MAD-based consensus algorithm
│   ├── ForkIntegration.t.sol       # Real Sepolia infrastructure tests
│   └── mocks/
│       ├── MockChaosCore.sol
│       ├── MockRewardsDistributor.sol
│       └── MockPredictionMarket.sol
├── script/
│   ├── DeployAll.s.sol
│   ├── PostDeploy.s.sol
│   └── config/
│       ├── sepolia.json
│       └── base-sepolia.json
└── lib/
    └── openzeppelin-contracts/     # OpenZeppelin v5.0.2 (git submodule)
```
