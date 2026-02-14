# ChaosOracle Standalone Agents

Cloud-ready Python asyncio daemons for autonomous prediction market settlement. Worker agents research market outcomes; verifier agents audit submissions and score quality.

## Architecture

```
┌─────────────────────────────────────────────────┐
│              Docker Compose                      │
│                                                  │
│  ┌──────────────┐    ┌──────────────┐           │
│  │ Worker Agent │    │Verifier Agent│           │
│  │  (polling)   │    │  (polling)   │           │
│  └──────┬───────┘    └──────┬───────┘           │
│         │                   │                    │
│         └─────────┬─────────┘                    │
│                   │                              │
│          ┌────────┴────────┐                     │
│          │  shared/        │                     │
│          │  sdk_client.py  │                     │
│          │  registry_reader│                     │
│          │  arweave_client │                     │
│          └─────────────────┘                     │
└─────────────────────┼───────────────────────────┘
                      │ outbound HTTPS only
         ┌────────────┼────────────────┐
         │            │                │
    Ethereum RPC   ChaosChain     Arweave / OpenAI
    (read state)   Gateway        (evidence + LLM)
                   (x402 payment)
```

**Key design:** Agents are purely outbound. No HTTP ports exposed. No inbound communication. All authentication happens through agent wallet signatures and x402 payments.

## Worker Agent Flow

Every `POLL_INTERVAL_SECONDS` (default 30):

1. Poll `ChaosOracleRegistry.getActiveStudios()` via RPC
2. For each new studio:
   - Read question and options from StudioProxy
   - Research the question using OpenAI (web search + analysis)
   - Build evidence package (JSON with outcome, confidence, sources, reasoning)
   - Upload evidence to Arweave, get CID
   - Register as worker on studio (stake 0.001 ETH)
   - Submit work via ChaosChain Gateway (x402 payment)
3. Track participated studios (in-memory set)

## Verifier Agent Flow

Every `POLL_INTERVAL_SECONDS` (default 5):

1. Poll `ChaosOracleRegistry.getActiveStudios()` via RPC
2. For each studio with unscored submissions:
   - Fetch worker's evidence package from Arweave
   - Audit evidence using OpenAI (accuracy, source quality, reasoning)
   - Register as verifier on studio (stake 0.001 ETH)
   - Submit scores via ChaosChain Gateway (x402 payment)
   - Scores: `[accuracy, evidence_quality, source_diversity, reasoning_depth]` (each 0-100)
3. Track scored (studio, worker) pairs (in-memory set)

## ERC-8004 Identity

On first boot, each agent auto-registers an on-chain identity:

```python
token_uri = f"https://{agent_domain}/.well-known/agent.json"
agent_id, tx = sdk.register_agent(token_uri=token_uri)
```

- Mints an ERC-721 token on the IdentityRegistry
- Agent ID cached locally in `chaoschain_agent_ids.json`
- Reputation accumulates from verifier scores across studios

## x402 Payment Flow

Agents pay the ChaosChain Gateway for work/score submission via x402:

1. Agent sends request to Gateway
2. Gateway returns 402 (Payment Required)
3. `X402PaymentManager` signs payment proof with agent's private key
4. Payment settled in USDC on Base Sepolia via facilitator
5. Gateway processes the submission

## Setup

```bash
# Install dependencies
pip install -r requirements.txt

# Configure
cp .env.example .env
# Edit .env with your keys
```

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `WORKER_PRIVATE_KEY` | Worker | Hex private key for worker wallet |
| `VERIFIER_PRIVATE_KEY` | Verifier | Hex private key for verifier wallet |
| `CHAOSCHAIN_GATEWAY_URL` | Both | Gateway URL (default: `https://gateway.chaoscha.in`) |
| `CHAOSCHAIN_NETWORK` | Both | Network identifier (default: `ethereum_sepolia`) |
| `SEPOLIA_RPC_URL` | Both | Ethereum Sepolia JSON-RPC endpoint |
| `CHAOS_ORACLE_REGISTRY_ADDRESS` | Both | Deployed ChaosOracleRegistry address |
| `OPENAI_API_KEY` | Both | OpenAI API key for research/audit |
| `OPENAI_MODEL` | Both | Model identifier (default: `gpt-4o`) |
| `POLL_INTERVAL_SECONDS` | Both | Poll interval (default: `30`) |
| `ARWEAVE_WALLET_PATH` | Optional | Path to Arweave JWK wallet (empty = stub mode) |

## Running Locally

```bash
# Run worker
python -m worker.main

# Run verifier
python -m verifier.main
```

## Docker Deployment

```bash
# Build and run both agents
docker compose up -d

# View logs
docker compose logs -f worker
docker compose logs -f verifier

# Stop
docker compose down
```

## Dependencies

```
chaoschain-sdk>=0.4.0     # ChaosChain Agent SDK (ERC-8004, x402, Gateway)
web3>=6.0.0               # Ethereum interaction
aiohttp>=3.9.0            # Async HTTP client
pydantic>=2.0.0           # Config validation
pydantic-settings>=2.0    # Environment variable loading
structlog>=23.0.0         # Structured logging
```

## File Structure

```
agents/
├── .env.example            # Environment template
├── requirements.txt        # Python dependencies
├── Dockerfile              # Container image
├── docker-compose.yml      # Run worker + verifier together
├── shared/
│   ├── __init__.py
│   ├── sdk_client.py       # ChaosChain SDK wrapper (ERC-8004, x402, Gateway)
│   ├── registry_reader.py  # Read ChaosOracleRegistry + StudioProxy on-chain
│   ├── arweave_client.py   # Upload/fetch evidence to/from Arweave
│   └── constants.py        # Contract addresses, ABIs, network configs
├── worker/
│   ├── __init__.py
│   ├── main.py             # Entry point - asyncio polling loop
│   ├── config.py           # Worker config (pydantic-settings)
│   ├── researcher.py       # OpenAI-powered question research
│   └── evidence.py         # Evidence package builder
└── verifier/
    ├── __init__.py
    ├── main.py             # Entry point - asyncio polling loop
    ├── config.py           # Verifier config (pydantic-settings)
    └── auditor.py          # OpenAI-powered evidence audit + scoring
```
