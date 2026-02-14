# 🔮 ChaosOracle Smart Contracts

Foundry project containing the core settlement framework contracts and an example prediction market.

## Addresses

| Contract                    | Sepolia                                                       |
|-----------------------------|---------------------------------------------------------------|
| `ChaosOracleRegistry`       | ``  |
| `PredictionSettlementLogic` | ``      |
| `ExamplePredictionMarket`   | `` |

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

68 tests across 5 test suites:

| Suite | Tests | Coverage |
|-------|-------|----------|
| `ChaosOracleRegistry.t.sol` | 23 | Constructor, admin, registration, CRE access control, studio creation, views |
| `PredictionSettlementLogic.t.sol` | 24 | Initialize, worker/verifier registration, submissions, scoring, consensus |
| `ExamplePredictionMarket.t.sol` | 18 | Market creation, betting, settlement, claims, payout math |
| `Integration.t.sol` | 2 | Full lifecycle, multiple markets |
| `ForkIntegration.t.sol` | 1 | Full lifecycle on forked Sepolia with real ChaosChain contracts |

```bash
forge test --skip ForkIntegration.t.sol
# Ran 4 test suites: 67 tests passed, 0 failed, 0 skipped

forge test ForkIntegration.t.sol --fork-url $SEPOLIA_RPC -vvvv
# Suite result: ok. 1 passed; 0 failed; 0 skipped;
```

### Test Mocks

| Mock | Purpose |
|------|---------|
| `MockChaosCore` | Implements `createStudio()` with deterministic proxy deployment |
| `MockStudioProxyFactory` | Deploys `MockStudioProxy` instances for testing |
| `MockPredictionMarket` | Records `setSettler()` and `onSettlement()` calls |

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
│   └── mocks/
│       ├── MockChaosCore.sol
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
