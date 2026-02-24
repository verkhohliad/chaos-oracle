# ChaosOracle Frontend

Next.js prediction market explorer with wallet integration and DKG visualization.

## Stack

- **Next.js 15** (App Router, standalone output)
- **React 19**, **TypeScript**
- **Tailwind CSS v4** — Uniswap-inspired dark theme with purple accent (`#A855F7`)
- **wagmi v2 + viem** — wallet connection, contract writes
- **@rainbow-me/rainbowkit** — wallet modal UI
- **@tanstack/react-query** — server state from Envio GraphQL

## Local Development

```bash
cp .env.local.example .env.local
# Fill in INDEXER_GRAPHQL_URL and NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID

npm install
npm run dev       # http://localhost:3000
```

## Environment Variables

| Variable | Scope | Description |
|----------|-------|-------------|
| `NEXT_PUBLIC_CHAIN_ID` | Public | Chain ID (default: 11155111 Sepolia) |
| `NEXT_PUBLIC_MARKET_ADDRESS` | Public | ExamplePredictionMarket contract |
| `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID` | Public | WalletConnect Cloud project ID |
| `INDEXER_GRAPHQL_URL` | Server | Envio GraphQL endpoint (proxied via `/api/graphql`) |

## Pages

- **`/`** — Market explorer grid (all markets, pool bars, status badges)
- **`/market/[id]`** — Market detail: betting form, timeline, DKG panel (workers, score matrix, consensus)

## Connecting to Indexer

**Envio hosted** (production):
```
INDEXER_GRAPHQL_URL=https://indexer.bigdevenergy.link/<hash>/v1/graphql
```

**Local Envio dev** (development):
```
INDEXER_GRAPHQL_URL=http://localhost:8080/v1/graphql
```

The frontend proxies all GraphQL requests through `/api/graphql` to keep the indexer URL server-side.
