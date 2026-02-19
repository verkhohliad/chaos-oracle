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
from shared.registry_reader import RegistryReader, ScoringDimension, StudioDetails, WorkerSubmission

from shared.sdk_client import ChaosOracleSDKClient

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
