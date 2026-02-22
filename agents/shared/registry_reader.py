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

import fcntl
import json
import os
from dataclasses import dataclass, field
from pathlib import Path
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
# StudioProxy ABIs (inline — events + view functions)
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

# View functions for resolving worker addresses and evidence CIDs from dataHashes
STUDIO_PROXY_VIEW_ABI: list[dict] = [
    *STUDIO_PROXY_EVENT_ABI,
    {
        "inputs": [{"name": "dataHash", "type": "bytes32"}],
        "name": "getWorkSubmitter",
        "outputs": [{"name": "submitter", "type": "address"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [{"name": "dataHash", "type": "bytes32"}],
        "name": "getEvidenceCID",
        "outputs": [{"name": "evidenceCID", "type": "string"}],
        "stateMutability": "view",
        "type": "function",
    },
]

# Path to shared evidence mapping file (Docker shared volume)
_SHARED_DIR_PATH = Path(os.environ.get("SHARED_DIR", "/shared"))
_EVIDENCE_MAP_PATH = _SHARED_DIR_PATH / "evidence_map.json"
_EVIDENCE_MAP_LOCK_PATH = _SHARED_DIR_PATH / "evidence_map.lock"


def _get_deploy_block() -> int:
    """Read the deploy block from addresses.json (written by deploy.sh).

    This is used as the ``fromBlock`` for event queries to avoid hitting
    free-tier Sepolia RPC ``eth_getLogs`` range limits on an Anvil fork.
    """
    try:
        addr_file = _SHARED_DIR_PATH / "addresses.json"
        if addr_file.exists():
            data = json.loads(addr_file.read_text())
            return int(data.get("deployBlock", 0))
    except Exception:
        pass
    return 0


@dataclass(frozen=True)
class ScoringDimension:
    """A single scoring dimension from the studio's logic module."""

    name: str
    weight: int  # 100 = 1.0x baseline


@dataclass(frozen=True)
class StudioDetails:
    """Read-only snapshot of a studio's on-chain state."""

    address: str
    question: str
    options: list[str]
    epoch_closed: bool
    worker_count: int = 0
    scoring_criteria: list[ScoringDimension] = field(default_factory=list)


@dataclass(frozen=True)
class WorkerSubmission:
    """A single worker's submission discovered from events or storage."""

    worker_address: str
    data_hash: str
    evidence_cid: str


def _load_evidence_map() -> dict[str, str]:
    """Load the shared evidence CID mapping from the Docker shared volume.

    Workers write ``{dataHash: evidenceCID}`` here after submitting work.
    Used as a fallback when ``getEvidenceCID()`` returns empty (single-agent
    ``submitWork()`` doesn't store the CID on-chain).

    Acquires a shared (read) lock via ``fcntl.flock()`` to prevent reading
    a partially written file during a concurrent write from another
    container.
    """
    if not _EVIDENCE_MAP_PATH.exists():
        return {}
    try:
        lock_fd = open(_EVIDENCE_MAP_LOCK_PATH, "w")
        fcntl.flock(lock_fd, fcntl.LOCK_SH)
        try:
            return json.loads(_EVIDENCE_MAP_PATH.read_text())
        finally:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
            lock_fd.close()
    except (json.JSONDecodeError, OSError):
        return {}


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

    def _studio_view_contract(self, studio_address: str) -> Contract:
        """Return a :class:`Contract` for StudioProxy view functions + events."""
        return self.w3.eth.contract(
            address=Web3.to_checksum_address(studio_address),
            abi=STUDIO_PROXY_VIEW_ABI,
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
    # Scoring criteria (via LogicModule delegatecall)
    # ------------------------------------------------------------------

    def get_scoring_criteria(self, studio_address: str) -> list[ScoringDimension]:
        """Read scoring criteria from the studio's logic module.

        Calls ``getScoringCriteria()`` on the StudioProxy (delegated to the
        LogicModule) to discover dimension names and weights.

        Returns
        -------
        list[ScoringDimension]
            Scoring dimensions with names and weights.  Falls back to 4
            default prediction-specific dimensions if the call fails.
        """
        studio = self._studio_logic_contract(studio_address)
        try:
            names, weights = studio.functions.getScoringCriteria().call()
            criteria = [
                ScoringDimension(name=n, weight=int(w))
                for n, w in zip(names, weights)
            ]
            logger.info(
                "registry_reader.scoring_criteria",
                studio=studio_address,
                dimensions=[(c.name, c.weight) for c in criteria],
            )
            return criteria
        except Exception:
            logger.warning(
                "registry_reader.scoring_criteria_fallback",
                studio=studio_address,
            )
            return [
                ScoringDimension(name="Accuracy", weight=200),
                ScoringDimension(name="Evidence Quality", weight=150),
                ScoringDimension(name="Source Diversity", weight=120),
                ScoringDimension(name="Reasoning Depth", weight=130),
            ]

    # ------------------------------------------------------------------
    # Studio reads (via LogicModule delegatecall — question/options)
    # ------------------------------------------------------------------

    def get_studio_details(self, studio_address: str) -> StudioDetails:
        """Fetch question, options, settlement status, and worker count for a studio.

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

        # Count work submissions via events.
        # Use deploy block as fromBlock to avoid hitting RPC eth_getLogs range
        # limits on free-tier Sepolia providers behind an Anvil fork.
        worker_count = 0
        try:
            from_block = _get_deploy_block()
            studio_events = self._studio_event_contract(studio_address)
            work_events = studio_events.events.WorkSubmitted.get_logs(
                from_block=from_block,
                to_block="latest",
            )
            worker_count = len(work_events)
        except Exception:
            logger.debug(
                "registry_reader.worker_count_fallback",
                studio=studio_address,
            )

        # Read scoring criteria from the logic module.
        scoring_criteria = self.get_scoring_criteria(studio_address)

        details = StudioDetails(
            address=studio_address,
            question=question,
            options=options,
            epoch_closed=epoch_closed,
            worker_count=worker_count,
            scoring_criteria=scoring_criteria,
        )

        logger.info(
            "registry_reader.studio_details",
            studio=studio_address,
            question=question[:80],
            options=options,
            closed=epoch_closed,
            worker_count=worker_count,
        )
        return details

    def get_unscored_submissions(
        self,
        studio_address: str,
        verifier_address: str,
    ) -> list[WorkerSubmission]:
        """Return worker submissions that have not yet been scored by *verifier_address*.

        Reads ``WorkSubmitted`` events from StudioProxy to discover workers,
        resolves worker addresses via ``getWorkSubmitter(dataHash)`` and
        evidence CIDs via ``getEvidenceCID(dataHash)`` (with fallback to
        the shared evidence mapping file).

        Then checks ``ScoreVectorSubmittedForWorker`` events to see which
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
        studio_view = self._studio_view_contract(studio_address)

        try:
            # Use deploy block as fromBlock to avoid hitting RPC eth_getLogs range
            # limits on free-tier Sepolia providers behind an Anvil fork.
            from_block = _get_deploy_block()

            # Get WorkSubmitted events
            work_events = studio_view.events.WorkSubmitted.get_logs(
                from_block=from_block,
                to_block="latest",
            )

            if not work_events:
                logger.info(
                    "registry_reader.no_work_events",
                    studio=studio_address,
                )
                return []

            # Get ScoreVectorSubmittedForWorker events (DIRECT mode scoring)
            score_events = studio_view.events.ScoreVectorSubmittedForWorker.get_logs(
                from_block=from_block,
                to_block="latest",
            )

            # Build set of (worker, dataHash) pairs already scored by ANY
            # verifier.  We key by (worker, tx.from) so each verifier can
            # independently score each worker.  Since the event only exposes
            # ``validatorAgentId`` (not address), we read the tx sender.
            scored_by_verifier: set[str] = set()  # set of dataHash hex
            for evt in score_events:
                try:
                    tx = self.w3.eth.get_transaction(evt.transactionHash)
                    scorer_addr = Web3.to_checksum_address(tx["from"])
                except Exception:
                    continue
                if scorer_addr == verifier_cs:
                    dh = evt.args.dataHash
                    scored_by_verifier.add(
                        dh.hex() if hasattr(dh, "hex") else str(dh)
                    )

            # Load shared evidence mapping as fallback for on-chain CIDs
            evidence_map = _load_evidence_map()

            unscored: list[WorkerSubmission] = []
            for evt in work_events:
                dh_bytes = evt.args.dataHash
                dh_hex = dh_bytes.hex() if hasattr(dh_bytes, "hex") else str(dh_bytes)

                # Resolve worker address from on-chain storage
                try:
                    worker_addr = studio_view.functions.getWorkSubmitter(dh_bytes).call()
                    worker_addr = Web3.to_checksum_address(worker_addr)
                except Exception:
                    logger.warning(
                        "registry_reader.getWorkSubmitter_failed",
                        studio=studio_address,
                        data_hash=dh_hex,
                    )
                    continue

                # Skip zero-address (no submitter recorded)
                if worker_addr == "0x0000000000000000000000000000000000000000":
                    continue

                # Skip if this verifier already scored this dataHash
                if dh_hex in scored_by_verifier:
                    continue

                # Resolve evidence CID from on-chain storage
                evidence_cid = ""
                try:
                    evidence_cid = studio_view.functions.getEvidenceCID(dh_bytes).call()
                except Exception:
                    logger.debug(
                        "registry_reader.getEvidenceCID_failed",
                        data_hash=dh_hex,
                    )

                # Fallback: check shared evidence mapping file
                if not evidence_cid:
                    evidence_cid = evidence_map.get(dh_hex, "")

                unscored.append(
                    WorkerSubmission(
                        worker_address=worker_addr,
                        data_hash=dh_hex,
                        evidence_cid=evidence_cid,
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
