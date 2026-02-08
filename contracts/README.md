# ChaosOracle Smart Contracts

Foundry project containing the core settlement framework contracts and an example prediction market.

## Architecture

```
ChaosOracleRegistry (central hub)
  ├── Receives market registrations (payable)
  ├── Creates ChaosChain Studios via ChaosCore
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

67 tests across 4 test suites:

| Suite | Tests | Coverage |
|-------|-------|----------|
| `ChaosOracleRegistry.t.sol` | 23 | Constructor, admin, registration, CRE access control, studio creation, views |
| `PredictionSettlementLogic.t.sol` | 24 | Initialize, worker/verifier registration, submissions, scoring, consensus |
| `ExamplePredictionMarket.t.sol` | 18 | Market creation, betting, settlement, claims, payout math |
| `Integration.t.sol` | 2 | Full lifecycle, multiple markets |

```bash
forge test
# Ran 4 test suites: 67 tests passed, 0 failed, 0 skipped
```

### Test Mocks

| Mock | Purpose |
|------|---------|
| `MockChaosCore` | Implements `createStudio()` with deterministic proxy deployment |
| `MockPredictionMarket` | Records `setSettler()` and `onSettlement()` calls |

## Deployment

### Order

1. Deploy `PredictionSettlementLogic` (no dependencies)
2. Register LogicModule with ChaosCore: `chaosCore.registerLogicModule(logicAddr, "PredictionSettlement")`
3. Deploy `ChaosOracleRegistry(chaosCoreAddr, logicModuleAddr, creForwarderAddr)`
4. Deploy CRE Workflow -> get `WORKFLOW_ID`
5. Call `registry.setAuthorizedWorkflowId(WORKFLOW_ID)`
6. Deploy `ExamplePredictionMarket(registryAddr)`

### Using the deploy script

```bash
# Configure
cp .env.example .env
# Edit .env with your keys and addresses

# Deploy to Sepolia
forge script script/DeployAll.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast

# Deploy to Base Sepolia
forge script script/DeployAll.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast
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
│   └── config/
│       ├── sepolia.json
│       └── base-sepolia.json
└── lib/
    └── openzeppelin-contracts/     # OpenZeppelin v5.0.2 (git submodule)
```
