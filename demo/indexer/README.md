# ChaosOracle Indexer

Envio-powered indexer for ChaosOracle prediction market events on Sepolia.

## Indexed Contracts

| Contract | Address | Events |
|----------|---------|--------|
| ExamplePredictionMarket | `0x64A52A8ce57291cA701F18376f26E224F7E2AEcb` | MarketCreated, BetPlaced, MarketSettled, WinningsClaimed |
| ChaosOracleRegistry | `0x4D067737D50bFeC0da87Cc782eA144Aeb24c05d5` | MarketRegistered, StudioCreated, StudioSettled |
| RewardsDistributor | `0x11aF07D8933a25B7fa32D06408d77a3ffaDcEAD1` | EpochClosed |
| StudioProxy | Dynamic | AgentRegistered, WorkSubmitted, ScoreVectorSubmittedForWorker |

StudioProxy addresses are registered dynamically when `StudioCreated` fires.

## Schema

8 entities: **Market**, **Bet**, **Claim**, **Studio**, **StudioAgent**, **WorkSubmission**, **ScoreVector**, **EpochClose**.

## Local Development

```bash
cp .env.example .env
# Fill in ENVIO_API_TOKEN

pnpm codegen
pnpm install
pnpm dev          # Starts indexer + local PostgreSQL on port 8080
```

GraphQL playground: `http://localhost:8080`

## Envio Hosted Deployment

The indexer is designed for [Envio's hosted service](https://docs.envio.dev/docs/HyperIndex/hosted-service):

1. Push the indexer code to a GitHub repository
2. Log into [app.envio.dev](https://app.envio.dev) with GitHub
3. Install the Envio Deployments GitHub App
4. Click **Add Indexer**, select your repo, set root directory to `demo/indexer`
5. Choose a deployment branch and push to it

The hosted service provides a production GraphQL endpoint:
```
https://indexer.bigdevenergy.link/<hash>/v1/graphql
```

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `ENVIO_API_TOKEN` | Yes | HyperSync API access token |
