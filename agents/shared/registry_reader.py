"""
On-chain reader for ChaosOracleRegistry and PredictionSettlementLogic state.

Uses :pymod:`web3` to perform read-only contract calls against studio proxy
contracts and the central registry.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import structlog
from web3 import Web3
from web3.contract import Contract

from shared.constants import (
    CHAOS_ORACLE_REGISTRY_ADDRESS,
    CHAOS_ORACLE_REGISTRY_ABI,
    PREDICTION_SETTLEMENT_LOGIC_ABI,
    SEPOLIA_RPC_URL,
)

logger = structlog.get_logger(__name__)


@dataclass(frozen=True)
class StudioDetails:
    """Read-only snapshot of a studio's on-chain state."""

    address: str
    question: str
    options: list[str]
    worker_count: int
    verifier_count: int
    epoch_closed: bool


@dataclass(frozen=True)
class WorkerSubmission:
    """A single worker's submission data."""

    worker_address: str
    outcome: int
    evidence_cid: str
    timestamp: int


class RegistryReader:
    """Reads ChaosOracleRegistry and studio state from the blockchain.

    Parameters
    ----------
    rpc_url:
        Ethereum JSON-RPC endpoint.  Defaults to ``SEPOLIA_RPC_URL``.
    registry_address:
        Deployed ChaosOracleRegistry address.  Defaults to the constant
        from :mod:`shared.constants`.
    """

    def __init__(
        self,
        rpc_url: str | None = None,
        registry_address: str | None = None,
    ) -> None:
        self._rpc_url = rpc_url or SEPOLIA_RPC_URL
        self._registry_address = Web3.to_checksum_address(
            registry_address or CHAOS_ORACLE_REGISTRY_ADDRESS
        )

        self.w3 = Web3(Web3.HTTPProvider(self._rpc_url))
        if not self.w3.is_connected():
            logger.warning("registry_reader.rpc_not_connected", rpc_url=self._rpc_url)

        self._registry: Contract = self.w3.eth.contract(
            address=self._registry_address,
            abi=CHAOS_ORACLE_REGISTRY_ABI,
        )

        logger.info(
            "registry_reader.initialized",
            registry=self._registry_address,
            rpc=self._rpc_url,
        )

    # ------------------------------------------------------------------
    # Studio helpers
    # ------------------------------------------------------------------

    def _studio_contract(self, studio_address: str) -> Contract:
        """Return a :class:`Contract` bound to a studio proxy."""
        return self.w3.eth.contract(
            address=Web3.to_checksum_address(studio_address),
            abi=PREDICTION_SETTLEMENT_LOGIC_ABI,
        )

    # ------------------------------------------------------------------
    # Registry reads
    # ------------------------------------------------------------------

    def get_active_studios(self) -> list[str]:
        """Return the list of currently active (unsettled) studio addresses."""
        try:
            studios: list[str] = self._registry.functions.getActiveStudios().call()
            logger.info("registry_reader.active_studios", count=len(studios))
            return [Web3.to_checksum_address(s) for s in studios]
        except (ConnectionError, TimeoutError, OSError) as exc:
            logger.error("registry_reader.rpc_connection_error", error=str(exc))
            raise
        except Exception:
            logger.exception("registry_reader.get_active_studios.error")
            return []

    def can_close_studio(self, studio_address: str) -> bool:
        """Check whether a studio has met the minimum thresholds to close."""
        try:
            return self._registry.functions.canCloseStudio(
                Web3.to_checksum_address(studio_address),
            ).call()
        except Exception:
            logger.exception(
                "registry_reader.can_close_studio.error",
                studio=studio_address,
            )
            return False

    # ------------------------------------------------------------------
    # Studio reads
    # ------------------------------------------------------------------

    def get_studio_details(self, studio_address: str) -> StudioDetails:
        """Fetch question, options, worker/verifier counts for a studio.

        Parameters
        ----------
        studio_address:
            The StudioProxy contract address.

        Returns
        -------
        StudioDetails
            Frozen dataclass with the studio's current on-chain state.
        """
        studio = self._studio_contract(studio_address)

        question: str = studio.functions.question().call()
        option_count: int = min(studio.functions.getOptionCount().call(), 20)
        options = [studio.functions.getOption(i).call() for i in range(option_count)]
        worker_count: int = studio.functions.getWorkerCount().call()
        verifier_count: int = studio.functions.getVerifierCount().call()
        epoch_closed: bool = studio.functions.epochClosed().call()

        details = StudioDetails(
            address=studio_address,
            question=question,
            options=options,
            worker_count=worker_count,
            verifier_count=verifier_count,
            epoch_closed=epoch_closed,
        )

        logger.info(
            "registry_reader.studio_details",
            studio=studio_address,
            question=question[:80],
            options=options,
            workers=worker_count,
            verifiers=verifier_count,
            closed=epoch_closed,
        )
        return details

    def get_unscored_submissions(
        self,
        studio_address: str,
        verifier_address: str,
    ) -> list[WorkerSubmission]:
        """Return worker submissions that have not yet been scored by *verifier_address*.

        Iterates the studio's ``workerList`` and checks whether the
        verifier has already submitted scores for each worker.

        Parameters
        ----------
        studio_address:
            The StudioProxy contract address.
        verifier_address:
            Ethereum address of the verifier agent.

        Returns
        -------
        list[WorkerSubmission]
            Submissions the verifier has not yet scored.
        """
        studio = self._studio_contract(studio_address)
        verifier_cs = Web3.to_checksum_address(verifier_address)

        worker_count: int = studio.functions.getWorkerCount().call()
        unscored: list[WorkerSubmission] = []

        for i in range(worker_count):
            worker: str = studio.functions.workerList(i).call()
            worker_cs = Web3.to_checksum_address(worker)

            # Fetch submission
            outcome, evidence_cid, timestamp = studio.functions.submissions(worker_cs).call()
            if timestamp == 0:
                # Worker registered but hasn't submitted yet
                continue

            # Check if this verifier already scored this worker.
            # The Solidity getter for mapping(addr => mapping(addr => uint8[4]))
            # takes 3 args: (verifier, worker, index) and returns a single uint8.
            try:
                already_scored = any(
                    studio.functions.verifierScores(verifier_cs, worker_cs, idx).call() > 0
                    for idx in range(4)
                )
                if already_scored:
                    continue
            except Exception:
                # Uninitialised mapping entries return 0; treat errors as "not scored".
                pass

            unscored.append(
                WorkerSubmission(
                    worker_address=worker_cs,
                    outcome=outcome,
                    evidence_cid=evidence_cid,
                    timestamp=timestamp,
                )
            )

        logger.info(
            "registry_reader.unscored_submissions",
            studio=studio_address,
            verifier=verifier_address,
            total_workers=worker_count,
            unscored_count=len(unscored),
        )
        return unscored
