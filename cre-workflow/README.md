# ChaosOracle CRE Workflow

Chainlink CRE (Chainlink Runtime Environment) workflow that orchestrates prediction market settlement. Three triggers handle the full lifecycle: creating studios for markets past their deadline, closing epochs when scores are ready, and settling outcomes once verifier scores are finalized on-chain.

## Architecture

```
CRE DON (Decentralized Oracle Network)
  |
  |-- Trigger 0: Cron (every 5 min)
  |   +-- onCheckDeadlines --> createStudioForMarket()
  |
  |-- Trigger 1: LogTrigger (EpochClosed on RewardsDistributor)
  |   +-- onEpochClosed --> reads finalized scores --> settleWithOutcome()
  |
  +-- Trigger 2: Cron (every 3 min)
      +-- onReadyToClose --> checks studio readiness --> Gateway /close-epoch
```

All writes go through the **CRE Forwarder** contract. The Registry validates `msg.sender == creForwarder` and verifies the `workflowId` from the CRE report.

## Handlers

### `onCheckDeadlines` (Trigger 0 -- Cron every 5 min)

Reads `getMarketsReadyForSettlement()` from the Registry. For each market past its deadline without a studio, calls `createStudioForMarket(key, creReport)` via CRE report signing.

### `onEpochClosed` (Trigger 1 -- LogTrigger on RewardsDistributor)

Fires when `EpochClosed(address indexed studio, uint64 indexed epoch, uint256 workCount, uint256 validatorCount)` is emitted by the RewardsDistributor after `closeEpoch()` finalizes per-worker quality scores on-chain.

Settlement steps:
1. Decode the `EpochClosed` event to extract the studio address and epoch number
2. Read all work hashes for the epoch via `getEpochWork(studio, epoch)` on RewardsDistributor
3. For each work hash, enumerate participating workers via `getWorkParticipants(dataHash)` on the StudioProxy
4. Read finalized quality scores for each worker via `getConsensusResult(workerDataHash)` on RewardsDistributor (where `workerDataHash = keccak256(abi.encodePacked(dataHash, worker))`)
5. Fetch evidence from IPFS (sandbox) or Arweave (production) to extract each worker's predicted outcome
6. Compute score-weighted consensus: each worker's outcome is weighted by the mean of their finalized quality scores (9 dimensions)
7. Call `settleWithOutcome(studio, outcome, proofHash, creReport)` where `proofHash = keccak256(sorted evidence CIDs joined by comma)`

### `onReadyToClose` (Trigger 2 -- Cron every 3 min)

Checks if active studios have sufficient worker submissions and verifier scores to close the epoch. Performs a two-layer readiness check:

1. Read all work hashes for the studio's epoch via `getEpochWork(studio, epoch)` on RewardsDistributor
2. **Layer 1**: For each work hash, check validators registered on RewardsDistributor via `getWorkValidators(dataHash)`
3. **Layer 2**: For each work hash and participant, verify actual score vectors exist on StudioProxy via `getScoreVectorsForWorker(dataHash, worker)`
4. If all checks pass (min workers, min validators, min scores per worker), calls the ChaosChain Gateway's `/workflows/close-epoch` endpoint to trigger `closeEpoch()` on RewardsDistributor

## EVM Interaction Pattern

```
Read:  EVMClient.callContract(runtime, { call, blockNumber })
       --> encodeCallMsg + encodeFunctionData (viem)
       --> Decodes response with decodeFunctionResult()

Write: reportResponse = runtime.report({ encodedPayload, encoderName, ... }).result()
       --> EVMClient.writeReport(runtime, { receiver, report, gasConfig })
       --> CRE Forwarder delivers tx to Registry
```

## Core Logic Extraction

Business logic is split across three files by execution context:

- **`core.ts`** -- Pure functions with no CRE SDK dependency. Contains all ABI encoding/decoding helpers, event log parsing, evidence resolution, and consensus computation. Shared by both `main.ts` and `sandbox-runner.ts`.
- **`main.ts`** -- Thin CRE handler wrappers. Routes I/O through CRE SDK capabilities (`EVMClient`, `HTTPClient`, `runtime.report()`) and delegates all computation to `core.ts`.
- **`sandbox-runner.ts`** -- Bun CLI debugging fallback. Imports `core.ts` directly but uses native `fetch()` and viem `walletClient` for direct transaction signing. Three subcommands: `check-deadlines`, `settle` (legacy, pre-closeEpoch), and `settle-finalized` (mirrors the CRE `onEpochClosed` handler).

## WASM Constraints

CRE handlers run inside a **QuickJS WASM sandbox**. This means:

- **No native `fetch()`** -- use `HTTPClient.sendRequest()` from the CRE SDK instead
- **No Node.js APIs** -- no `fs`, `path`, `process`, etc.
- **HTTP body must be base64-encoded** -- CRE's WASM runtime expects the `body` field as base64-encoded bytes (protobuf bytes field). Convert via `hexToBase64(toHex(body))` using CRE SDK's `hexToBase64` and viem's `toHex`.
- **Handler return type** -- each `HandlerFn` must return a `string` (CreSerializable)

The `core.ts` native `fetch()` helpers (e.g., `fetchWorkLogs`, `fetchEvidence`, `ethCall`) are for `sandbox-runner.ts` only and cannot be used inside CRE handlers.

## Setup

```bash
# Install Bun (if not installed)
curl -fsSL https://bun.sh/install | bash

# Install dependencies
cd settlement-workflow
bun install

# Configure
# Edit config.staging.json with your deployed Registry and RewardsDistributor addresses
```

## Deployment

```bash
# Login to CRE
cre login
cre account link-key

# Simulate locally
cre workflow simulate ./settlement-workflow

# Deploy to DON
cre workflow deploy ./settlement-workflow --target staging-settings

# Trigger 0 — onCheckDeadlines (creates studios for markets past deadline)
cd cre-workflow
cre workflow simulate ./settlement-workflow \
  --target sepolia-settings \
  --broadcast \
  --non-interactive \
  --trigger-index 0 \
  --engine-logs

# Trigger 2 — onReadyToClose (checks studio readiness, closes epoch via Gateway)
cre workflow simulate ./settlement-workflow \
  --target sepolia-settings \
  --broadcast \
  --non-interactive \
  --trigger-index 2 \
  --engine-logs

# Trigger 1 — onEpochClosed (reads scores, settles market — needs tx hash)
cre workflow simulate ./settlement-workflow \
  --target sepolia-settings \
  --broadcast \
  --non-interactive \
  --trigger-index 1 \
  --evm-tx-hash 0x<EPOCH_CLOSED_TX_HASH> \
  --evm-event-index 0 \
  --engine-logs


# Note the WORKFLOW_ID from the deploy output
# Then authorize it on-chain:
#   registry.setAuthorizedWorkflowId(WORKFLOW_ID)
```

## Configuration

Set environment variables in `.env` at the project root:

| Variable | Description |
|----------|-------------|
| `CRE_ETH_PRIVATE_KEY` | Ethereum private key for workflow deployment |
| `CRE_TARGET` | Target environment (default: `staging-settings`) |

Workflow config is in `settlement-workflow/config.<target>.json`:

| Field | Description | Default |
|-------|-------------|---------|
| `registryAddress` | Deployed ChaosOracleRegistry address | Required |
| `rewardsDistributorAddress` | Deployed RewardsDistributor address | Required |
| `chainSelectorName` | Chainlink chain selector name | `ethereum-testnet-sepolia` |
| `gasLimit` | Gas limit for CRE write transactions | `6000000` |
| `minWorkers` | Minimum workers for consensus | `3` |
| `minValidators` | Minimum validators for consensus | `2` |
| `minScoresPerWorker` | Min scores per worker for consensus | `2` |
| `rpcUrl` | RPC URL for HTTP calls (sandbox-runner and evidence fetching) | (empty) |
| `arweaveGatewayUrl` | Arweave gateway for evidence (production) | `https://arweave.net` |
| `ipfsGatewayUrl` | IPFS gateway for evidence (sandbox only) | `https://ipfs.io` |
| `fromBlock` | Starting block for event queries (hex) | `0x0` |

## File Structure

```
cre-workflow/
+-- project.yaml                       # RPC endpoints per target (staging, production, sandbox)
+-- secrets.yaml                       # Secrets template
+-- .env                               # Private key + target (gitignored)
+-- .env.example                       # Environment template
+-- .gitignore                         # Ignores *.env, node_modules, dist
+-- .dockerignore                      # Excludes .env and node_modules from Docker context
+-- README.md
+-- contracts/                         # ABI definitions
|   +-- abi/
|       +-- index.ts                   # Barrel export
|       +-- ChaosOracleRegistry.ts     # Registry + StudioProxy + RewardsDistributor ABI fragments
+-- settlement-workflow/               # Main workflow
    +-- main.ts                        # CRE entry point (Runner + initWorkflow, thin handler wrappers)
    +-- core.ts                        # Pure business logic (ABI helpers, consensus, evidence)
    +-- sandbox-runner.ts              # Bun CLI debugging fallback (native fetch + viem walletClient)
    +-- package.json                   # @chainlink/cre-sdk, viem, zod
    +-- tsconfig.json                  # TypeScript config
    +-- workflow.yaml                  # Per-target artifact paths
    +-- config.sandbox.json            # Sandbox config (Anvil, patched at runtime by orchestrate.sh)
    +-- config.staging.json            # Staging config (public Sepolia)
    +-- config.production.json         # Production config
```

## Known Gotchas

**Gas limit for StudioProxy deployment**: `StudioProxyFactory.deployStudioProxy()` needs approximately 4.2M gas (CREATE opcode). The CRE config `gasLimit` must be set to 6M+ to cover the full call chain: CRE Forwarder -> Registry.onReport -> createStudioForMarket -> deployStudioProxy -> CREATE. Use `debug_traceTransaction` with `callTracer` to diagnose silent on-chain reverts if studio creation succeeds without error but no proxy is deployed.

**HTTP body must be base64-encoded**: CRE's WASM runtime `HTTPClient.sendRequest()` expects the `body` field as base64-encoded bytes (protobuf bytes field). The fix is `hexToBase64(toHex(body))` using the CRE SDK's `hexToBase64` helper combined with viem's `toHex`.

**fromBlock on Anvil fork**: Alchemy free tier limits `eth_getLogs` to a 10-block range. Querying `fromBlock: "0x0"` on an Anvil Sepolia fork fails because Anvil proxies the query upstream. Solution: use the deploy block as `fromBlock` (stored in `addresses.json` as `deployBlock` and patched into the CRE config as hex by `orchestrate.sh`).

**IPFS is sandbox-only, Arweave is production**: Evidence CIDs starting with `Qm` or `bafy` are routed to the IPFS gateway (only available in the Docker sandbox via the `ipfs` service). All other CIDs are assumed to be Arweave transaction IDs and routed to the Arweave gateway. SHA-256 stub CIDs (64 hex characters) have no real evidence and are skipped.

**CRE triggers cannot be named**: The CRE SDK does not support naming triggers. When running `cre workflow simulate`, triggers are presented by index: trigger 0 = `onCheckDeadlines` (cron), trigger 1 = `onEpochClosed` (log), trigger 2 = `onReadyToClose` (cron). Use `--trigger-index N` or select the trigger number via stdin.

**Score truncation**: The ChaosChain gateway encoder truncates 9 scoring dimensions to 5 for on-chain `uint8[]` storage. The `onEpochClosed` handler reads whatever dimensions are stored and averages them for the consensus weight.
