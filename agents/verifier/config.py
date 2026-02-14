"""
Verifier agent configuration loaded from environment variables.

Uses ``pydantic-settings`` for validated, typed configuration with sensible
defaults targeting Ethereum Sepolia.
"""

from __future__ import annotations

from pydantic import Field
from pydantic_settings import BaseSettings


class VerifierConfig(BaseSettings):
    """Configuration for the ChaosOracle Verifier agent.

    All values can be overridden via environment variables (case-insensitive).
    The ``model_config`` block instructs pydantic-settings to also read from
    a ``.env`` file when present.
    """

    model_config = {"env_file": ".env", "env_file_encoding": "utf-8", "extra": "ignore"}

    # ---- Agent wallet ----
    verifier_private_key: str = Field(
        ...,
        description="Hex-encoded private key for the verifier agent wallet.",
    )

    # ---- ChaosChain mode ----
    chaoschain_mode: str = Field(
        default="gateway",
        description=(
            "'gateway' for production (ChaosChain Gateway + x402), "
            "'local' for direct web3 calls (no Gateway, no ERC-8004)."
        ),
    )

    # ---- ChaosChain network ----
    chaoschain_gateway_url: str = Field(
        default="https://gateway.chaoscha.in",
        description="ChaosChain Gateway URL.",
    )
    chaoschain_network: str = Field(
        default="ethereum_sepolia",
        description="ChaosChain network identifier (e.g. ethereum_sepolia).",
    )

    # ---- RPC ----
    sepolia_rpc_url: str = Field(
        default="",
        description="Ethereum Sepolia JSON-RPC endpoint (required).",
    )

    # ---- Audit LLM ----
    openai_api_key: str = Field(
        default="",
        description="OpenAI API key used by the Auditor for LLM-based evaluation.",
    )
    openai_model: str = Field(
        default="gpt-4o",
        description="OpenAI model identifier for audit analysis.",
    )

    # ---- Polling ----
    poll_interval_seconds: int = Field(
        default=30,
        ge=5,
        description="Seconds between registry poll cycles.",
    )

    # ---- Staking ----
    verifier_stake: int = Field(
        default=1_000_000_000_000_000,  # 0.001 ETH in wei
        description="Stake amount in wei deposited when joining a studio.",
    )

    # ---- Contract addresses ----
    chaos_oracle_registry_address: str = Field(
        default="0x0000000000000000000000000000000000000000",
        description="Deployed ChaosOracleRegistry address on Sepolia.",
    )
