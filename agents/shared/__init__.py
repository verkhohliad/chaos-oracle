"""
ChaosOracle shared utilities re-exported for convenience.
"""

from shared.arweave_client import ArweaveClient
from shared.constants import (
    CHAIN_ID,
    CHAOS_ORACLE_REGISTRY_ADDRESS,
    CHAOS_ORACLE_REGISTRY_ABI,
    CHAOSCHAIN_GATEWAY_URL,
    ERC_8004_IDENTITY_ADDRESS,
    PREDICTION_SETTLEMENT_LOGIC_ABI,
    REPUTATION_CONTRACT_ADDRESS,
    SEPOLIA_RPC_URL,
    VERIFIER_STAKE_WEI,
    WORKER_STAKE_WEI,
)
from shared.registry_reader import RegistryReader, StudioDetails, WorkerSubmission

# ChaosOracleSDKClient depends on chaoschain_sdk which is only installed in
# gateway mode.  Import lazily so local-mode containers (which only need
# DirectSubmitter) don't crash on startup.
try:
    from shared.sdk_client import ChaosOracleSDKClient
except ImportError:
    ChaosOracleSDKClient = None  # type: ignore[assignment,misc]

__all__ = [
    "ArweaveClient",
    "ChaosOracleSDKClient",
    "RegistryReader",
    "StudioDetails",
    "WorkerSubmission",
    # constants
    "CHAIN_ID",
    "CHAOS_ORACLE_REGISTRY_ADDRESS",
    "CHAOS_ORACLE_REGISTRY_ABI",
    "CHAOSCHAIN_GATEWAY_URL",
    "ERC_8004_IDENTITY_ADDRESS",
    "PREDICTION_SETTLEMENT_LOGIC_ABI",
    "REPUTATION_CONTRACT_ADDRESS",
    "SEPOLIA_RPC_URL",
    "VERIFIER_STAKE_WEI",
    "WORKER_STAKE_WEI",
]
