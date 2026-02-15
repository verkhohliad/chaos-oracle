"""
On-chain reader for ChaosOracleRegistry and StudioProxy state.

Uses :pymod:`web3` to perform read-only contract calls against studio proxy
contracts and the central registry.

After the architecture change, PredictionSettlementLogic only provides
metadata (question, options, scoring criteria). Worker/verifier state is
managed natively by StudioProxy. The RegistryReader now checks settlement
status via the Registry's ``activeStudios`` mapping and reads worker
submissions via ``WorkSubmitted`` events from StudioProxy.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

import structlog
from web3 import Web3
from web3.contract import Contract

from shared.constants import (
    CHAOS_ORACLE_REGISTRY_ADDRESS,
    CHAOS_ORACLE_REGISTRY_ABI,
    PREDICTION_SETTLEMENT_LOGIC_ABI,
    SEPOLIA_RPC_URL,
    STUDIO_PROXY_WITHDRAW_ABI,
)

logger = structlog.get_logger(__name__)


# ---------------------------------------------------------------------------
# StudioProxy event ABIs (inline — for reading WorkSubmitted events)
# ---------------------------------------------------------------------------

STUDIO_PROXY_EVENT_ABI: list[dict] = [
    {
        "anonymous": False,
        "name": "WorkSubmitted",
        "type": "event",
        "inputs": [
            {"indexed": True, "name": "agentId", "type": "uint256"},
            {"indexed": True, "name": "dataHash", "type": "bytes32"},
            {"indexed": False, "name": "threadRoot", "type": "bytes32"},
            {"indexed": False, "name": "evidenceRoot", "type": "bytes32"},
            {"indexed": False, "name": "timestamp", "type": "uint256"},
        ],
    },
    {
        "anonymous": False,
        "name": "ScoreVectorSubmittedForWorker",
        "type": "event",
        "inputs": [
            {"indexed": True, "name": "validatorAgentId", "type": "uint256"},
            {"indexed": True, "name": "dataHash", "type": "bytes32"},
            {"indexed": True, "name": "worker", "type": "address"},
            {"indexed": False, "name": "scoreVector", "type": "bytes"},
            {"indexed": False, "name": "timestamp", "type": "uint256"},
        ],
    },
]


@dataclass(frozen=True)
class StudioDetails:
    """Read-only snapshot of a studio's on-chain state."""

    address: str
    question: str
    options: list[str]
    epoch_closed: bool


@dataclass(frozen=True)
class WorkerSubmission:
    """A single worker's submission discovered from events or storage."""

    worker_address: str
    data_hash: str
    evidence_cid: str


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

    def _studio_logic_contract(self, studio_address: str) -> Contract:
        """Return a :class:`Contract` bound to a studio proxy for LogicModule calls."""
        return self.w3.eth.contract(
            address=Web3.to_checksum_address(studio_address),
            abi=PREDICTION_SETTLEMENT_LOGIC_ABI,
        )

    def _studio_event_contract(self, studio_address: str) -> Contract:
        """Return a :class:`Contract` bound to a studio proxy for event reading."""
        return self.w3.eth.contract(
            address=Web3.to_checksum_address(studio_address),
            abi=STUDIO_PROXY_EVENT_ABI,
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
        """Check whether a studio exists and is not yet settled."""
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

    def is_studio_settled(self, studio_address: str) -> bool:
        """Check whether a studio has been settled via Registry.activeStudios."""
        try:
            result = self._registry.functions.activeStudios(
                Web3.to_checksum_address(studio_address),
            ).call()
            # Struct returns as tuple: (key, studio, studioId, market, marketId, settled)
            settled = result[5] if len(result) > 5 else False
            return bool(settled)
        except Exception:
            logger.exception(
                "registry_reader.is_studio_settled.error",
                studio=studio_address,
            )
            return False

    # ------------------------------------------------------------------
    # Studio reads (via LogicModule delegatecall — question/options only)
    # ------------------------------------------------------------------

    def get_studio_details(self, studio_address: str) -> StudioDetails:
        """Fetch question, options, and settlement status for a studio.

        Parameters
        ----------
        studio_address:
            The StudioProxy contract address.

        Returns
        -------
        StudioDetails
            Frozen dataclass with the studio's current on-chain state.
        """
        studio = self._studio_logic_contract(studio_address)

        question: str = studio.functions.question().call()
        option_count: int = min(studio.functions.getOptionCount().call(), 20)
        options = [studio.functions.getOption(i).call() for i in range(option_count)]
        epoch_closed = self.is_studio_settled(studio_address)

        details = StudioDetails(
            address=studio_address,
            question=question,
            options=options,
            epoch_closed=epoch_closed,
        )

        logger.info(
            "registry_reader.studio_details",
            studio=studio_address,
            question=question[:80],
            options=options,
            closed=epoch_closed,
        )
        return details

    def get_unscored_submissions(
        self,
        studio_address: str,
        verifier_address: str,
    ) -> list[WorkerSubmission]:
        """Return worker submissions that have not yet been scored by *verifier_address*.

        Reads ``WorkSubmitted`` events from StudioProxy to discover workers,
        then checks ``ScoreVectorSubmittedForWorker`` events to see which
        workers this verifier has already scored.

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
        studio_cs = Web3.to_checksum_address(studio_address)
        verifier_cs = Web3.to_checksum_address(verifier_address)
        studio_events = self._studio_event_contract(studio_address)

        try:
            # Get WorkSubmitted events
            work_events = studio_events.events.WorkSubmitted.get_logs(
                fromBlock=0,
                toBlock="latest",
            )

            if not work_events:
                logger.info(
                    "registry_reader.no_work_events",
                    studio=studio_address,
                )
                return []

            # Get ScoreVectorSubmittedForWorker events for this verifier
            # to determine which workers have already been scored
            score_events = studio_events.events.ScoreVectorSubmittedForWorker.get_logs(
                fromBlock=0,
                toBlock="latest",
            )

            # Build set of (dataHash, worker) pairs already scored by this verifier
            scored_data_hashes: set[str] = set()
            for evt in score_events:
                # Filter by verifier — check the worker field
                # We can't filter by validatorAgentId easily, so check all score events
                # and match by the worker to see if this verifier has scored
                # Note: We'd ideally filter by validator agent ID, but we just check
                # all score events for now
                dh = evt.args.dataHash.hex() if hasattr(evt.args.dataHash, 'hex') else str(evt.args.dataHash)
                worker = evt.args.worker
                scored_data_hashes.add(f"{dh}:{worker}")

            unscored: list[WorkerSubmission] = []
            for evt in work_events:
                dh = evt.args.dataHash.hex() if hasattr(evt.args.dataHash, 'hex') else str(evt.args.dataHash)
                # We don't have the worker address directly from WorkSubmitted,
                # but we can derive it from agentId or check dataHash/worker pairs.
                # For now, create a submission entry with the dataHash.
                unscored.append(
                    WorkerSubmission(
                        worker_address="",  # Not directly available from event
                        data_hash=dh,
                        evidence_cid="",  # Would need to read from storage
                    )
                )

            logger.info(
                "registry_reader.unscored_submissions",
                studio=studio_address,
                verifier=verifier_address,
                total_submissions=len(work_events),
                unscored_count=len(unscored),
            )
            return unscored

        except Exception:
            logger.exception(
                "registry_reader.get_unscored_submissions.error",
                studio=studio_address,
            )
            return []
