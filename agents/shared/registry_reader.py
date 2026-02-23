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
    REWARDS_DISTRIBUTOR_ABI,
    REWARDS_DISTRIBUTOR_ADDRESS,
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


# Maximum block range per eth_getLogs call.  Alchemy free tier limits this
# to 10 blocks.  We use a slightly conservative value.
_MAX_LOG_RANGE = 10


def _paginated_get_logs(event, from_block: int, to_block: int) -> list:
    """Fetch event logs in small page-sized chunks.

    Alchemy free tier limits ``eth_getLogs`` to a 10-block range.  This
    helper splits a larger range into pages of ``_MAX_LOG_RANGE`` blocks
    each and concatenates the results.
    """
    all_logs: list = []
    cursor = from_block
    while cursor <= to_block:
        page_end = min(cursor + _MAX_LOG_RANGE - 1, to_block)
        try:
            logs = event.get_logs(from_block=cursor, to_block=page_end)
            all_logs.extend(logs)
        except Exception:
            # If a single page fails, skip it and continue
            pass
        cursor = page_end + 1
    return all_logs


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
        rewards_distributor_address: str | None = None,
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

        # RewardsDistributor — optional, degrades gracefully.
        rd_addr = rewards_distributor_address or REWARDS_DISTRIBUTOR_ADDRESS
        self._rewards_dist: Contract | None = None
        if rd_addr:
            self._rewards_dist = self.w3.eth.contract(
                address=Web3.to_checksum_address(rd_addr),
                abi=REWARDS_DISTRIBUTOR_ABI,
            )

        logger.info(
            "registry_reader.initialized",
            registry=self._registry_address,
            rewards_distributor=rd_addr or "(none)",
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

        Uses batched RPC calls where possible to reduce round-trips.

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
        studio_cs = Web3.to_checksum_address(studio_address)

        # ── Batch 1: question + optionCount + scoringCriteria + settled ──
        try:
            with self.w3.batch_requests() as batch:
                batch.add(studio.functions.question().call)
                batch.add(studio.functions.getOptionCount().call)
                batch.add(studio.functions.getScoringCriteria().call)
                batch.add(self._registry.functions.activeStudios(studio_cs).call)
            question, option_count, scoring_raw, studio_info = batch.execute()
        except Exception:
            logger.debug("registry_reader.batch1_fallback", studio=studio_address)
            # Fallback to sequential calls if batch not supported
            question = studio.functions.question().call()
            option_count = studio.functions.getOptionCount().call()
            scoring_raw = studio.functions.getScoringCriteria().call()
            studio_info = self._registry.functions.activeStudios(studio_cs).call()

        option_count = min(option_count, 20)
        epoch_closed = bool(studio_info[5]) if len(studio_info) > 5 else False

        # Parse scoring criteria
        names, weights = scoring_raw
        scoring_criteria = [
            ScoringDimension(name=n, weight=int(w))
            for n, w in zip(names, weights)
        ]

        # ── Batch 2: all getOption(i) calls ──
        options: list[str] = []
        if option_count > 0:
            try:
                with self.w3.batch_requests() as batch:
                    for i in range(option_count):
                        batch.add(studio.functions.getOption(i).call)
                options = list(batch.execute())
            except Exception:
                logger.debug("registry_reader.batch2_fallback", studio=studio_address)
                options = [studio.functions.getOption(i).call() for i in range(option_count)]

        # ── Worker count via RewardsDistributor (preferred) or events ──
        worker_count = 0
        if self._rewards_dist:
            try:
                work_hashes: list[bytes] = self._rewards_dist.functions.getEpochWork(
                    studio_cs, 1
                ).call()
                worker_count = len(work_hashes)
            except Exception:
                logger.debug("registry_reader.rd_worker_count_fallback", studio=studio_address)
        if worker_count == 0:
            try:
                from_block = _get_deploy_block()
                latest = self.w3.eth.block_number
                if from_block == 0:
                    from_block = max(0, latest - 200)
                studio_events = self._studio_event_contract(studio_address)
                work_events = _paginated_get_logs(
                    studio_events.events.WorkSubmitted,
                    from_block=from_block,
                    to_block=latest,
                )
                worker_count = len(work_events)
            except Exception:
                logger.debug("registry_reader.worker_count_fallback", studio=studio_address)

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
        """Return worker submissions that have not yet been *fully* scored by *verifier_address*.

        "Fully scored" means the score exists on StudioProxy **and** the
        validator is registered in RewardsDistributor.  If the Gateway's
        REGISTER_VALIDATOR step failed, the submission will be returned so
        the verifier re-submits.

        Uses batched RPC calls for ``getWorkSubmitter`` / ``getEvidenceCID``
        lookups to minimise round-trips.

        Parameters
        ----------
        studio_address:
            The StudioProxy contract address.
        verifier_address:
            Ethereum address of the verifier agent.

        Returns
        -------
        list[WorkerSubmission]
            Submissions the verifier has not yet fully scored.
        """
        studio_cs = Web3.to_checksum_address(studio_address)
        verifier_cs = Web3.to_checksum_address(verifier_address)
        studio_view = self._studio_view_contract(studio_address)

        try:
            from_block = _get_deploy_block()
            latest = self.w3.eth.block_number
            if from_block == 0:
                from_block = max(0, latest - 200)

            # Get WorkSubmitted events (paginated)
            work_events = _paginated_get_logs(
                studio_view.events.WorkSubmitted,
                from_block=from_block,
                to_block=latest,
            )

            if not work_events:
                logger.info("registry_reader.no_work_events", studio=studio_address)
                return []

            # Get ScoreVectorSubmittedForWorker events (paginated)
            score_events = _paginated_get_logs(
                studio_view.events.ScoreVectorSubmittedForWorker,
                from_block=from_block,
                to_block=latest,
            )

            # Build set of dataHash hex values scored by THIS verifier
            # on StudioProxy (event-based check).
            scored_on_studio: set[str] = set()
            for evt in score_events:
                try:
                    tx = self.w3.eth.get_transaction(evt.transactionHash)
                    scorer_addr = Web3.to_checksum_address(tx["from"])
                except Exception:
                    continue
                if scorer_addr == verifier_cs:
                    dh = evt.args.dataHash
                    scored_on_studio.add(
                        dh.hex() if hasattr(dh, "hex") else str(dh)
                    )

            # Cross-check: verify validator is also registered in
            # RewardsDistributor for each scored dataHash.
            scored_by_verifier: set[str] = set()
            if self._rewards_dist and scored_on_studio:
                for dh_hex in scored_on_studio:
                    try:
                        dh_bytes = bytes.fromhex(dh_hex)
                        validators: list[str] = self._rewards_dist.functions.getWorkValidators(
                            dh_bytes
                        ).call()
                        if verifier_cs.lower() in [v.lower() for v in validators]:
                            scored_by_verifier.add(dh_hex)
                        else:
                            logger.warning(
                                "registry_reader.validator_not_in_rd",
                                studio=studio_address,
                                data_hash=dh_hex,
                                verifier=verifier_address,
                            )
                    except Exception:
                        # RD query failed — trust StudioProxy event
                        scored_by_verifier.add(dh_hex)
            else:
                # No RD configured — trust StudioProxy events only
                scored_by_verifier = scored_on_studio

            # Load shared evidence mapping as fallback for on-chain CIDs
            evidence_map = _load_evidence_map()

            # ── Batch: getWorkSubmitter + getEvidenceCID for all submissions ──
            data_hashes = [evt.args.dataHash for evt in work_events]
            submitters: list[str] = []
            cids: list[str] = []

            try:
                with self.w3.batch_requests() as batch:
                    for dh in data_hashes:
                        batch.add(studio_view.functions.getWorkSubmitter(dh).call)
                        batch.add(studio_view.functions.getEvidenceCID(dh).call)
                results = batch.execute()
                for i in range(len(data_hashes)):
                    submitters.append(Web3.to_checksum_address(results[i * 2]))
                    cids.append(results[i * 2 + 1])
            except Exception:
                logger.debug("registry_reader.batch_view_fallback", studio=studio_address)
                # Fallback to sequential calls
                for dh in data_hashes:
                    try:
                        s = studio_view.functions.getWorkSubmitter(dh).call()
                        submitters.append(Web3.to_checksum_address(s))
                    except Exception:
                        submitters.append("0x0000000000000000000000000000000000000000")
                    try:
                        cids.append(studio_view.functions.getEvidenceCID(dh).call())
                    except Exception:
                        cids.append("")

            unscored: list[WorkerSubmission] = []
            for idx, evt in enumerate(work_events):
                dh_bytes = evt.args.dataHash
                dh_hex = dh_bytes.hex() if hasattr(dh_bytes, "hex") else str(dh_bytes)
                worker_addr = submitters[idx]
                evidence_cid = cids[idx]

                # Skip zero-address (no submitter recorded)
                if worker_addr == "0x0000000000000000000000000000000000000000":
                    continue

                # Skip if fully scored (StudioProxy + RewardsDistributor)
                if dh_hex in scored_by_verifier:
                    continue

                # Fallback: check shared evidence mapping file
                if not evidence_cid:
                    evidence_cid = evidence_map.get(dh_hex, "")

                # Fallback: extract evidence URI from submitWork tx input data.
                if not evidence_cid:
                    try:
                        tx = self.w3.eth.get_transaction(evt.transactionHash)
                        tx_input = tx["input"]
                        if tx_input[:4].hex() == "b5844c70" and len(tx_input) > 164:
                            import eth_abi
                            _, _, _, feedback_bytes = eth_abi.decode(
                                ["bytes32", "bytes32", "bytes32", "bytes"],
                                tx_input[4:],
                            )
                            uri = feedback_bytes.rstrip(b"\x00").decode("utf-8", errors="ignore")
                            if uri.startswith("ar://") or uri.startswith("ipfs://"):
                                evidence_cid = uri
                    except Exception:
                        pass

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

    # ------------------------------------------------------------------
    # On-chain submission checks
    # ------------------------------------------------------------------

    def has_worker_fully_submitted(
        self,
        studio_address: str,
        worker_address: str,
        data_hash_hex: str | None = None,
    ) -> bool:
        """Check if a worker has submitted AND the work is registered in RewardsDistributor.

        Returns ``True`` only when:
        1. StudioProxy.getEscrowBalance(worker) > 0  — work submitted on-chain
        2. RewardsDistributor.getEpochWork(studio, 1) contains the worker's
           dataHash (or at least has entries, if dataHash unknown)

        If RewardsDistributor is not configured, falls back to StudioProxy only.

        Parameters
        ----------
        studio_address:
            The StudioProxy contract address.
        worker_address:
            Ethereum address of the worker agent.
        data_hash_hex:
            Hex-encoded dataHash (without 0x) to check in getEpochWork.
            If ``None``, accepts any non-empty epoch work list.
        """
        try:
            worker_cs = Web3.to_checksum_address(worker_address)
            studio_cs = Web3.to_checksum_address(studio_address)
            proxy = self.w3.eth.contract(
                address=studio_cs,
                abi=STUDIO_PROXY_WITHDRAW_ABI,
            )

            # ── Batch: escrow + epoch work ──
            if self._rewards_dist:
                try:
                    with self.w3.batch_requests() as batch:
                        batch.add(proxy.functions.getEscrowBalance(worker_cs).call)
                        batch.add(self._rewards_dist.functions.getEpochWork(studio_cs, 1).call)
                    balance, work_hashes = batch.execute()
                except Exception:
                    logger.debug("registry_reader.batch_submit_check_fallback", studio=studio_address)
                    balance = proxy.functions.getEscrowBalance(worker_cs).call()
                    work_hashes = self._rewards_dist.functions.getEpochWork(studio_cs, 1).call()
            else:
                balance = proxy.functions.getEscrowBalance(worker_cs).call()
                work_hashes = None

            if balance == 0:
                return False

            # StudioProxy says worker staked.  Now verify RD.
            if work_hashes is None:
                # No RD configured — trust StudioProxy
                logger.info(
                    "registry_reader.worker_already_staked",
                    studio=studio_address,
                    worker=worker_address,
                    escrow_wei=balance,
                )
                return True

            if not work_hashes:
                # StudioProxy has escrow but RD has ZERO work hashes → incomplete
                logger.warning(
                    "registry_reader.work_not_in_rd",
                    studio=studio_address,
                    worker=worker_address,
                    escrow_wei=balance,
                    rd_work_count=0,
                )
                return False

            # We MUST know the specific dataHash to verify THIS worker's submission.
            # getEpochWork() returns ALL work hashes for the epoch (from all workers),
            # so a non-empty list only proves *some* worker submitted — not this one.
            if not data_hash_hex:
                logger.info(
                    "registry_reader.no_data_hash_to_verify",
                    studio=studio_address,
                    worker=worker_address,
                    escrow_wei=balance,
                    rd_work_count=len(work_hashes),
                )
                return False  # Cannot confirm without worker's specific hash

            target = bytes.fromhex(data_hash_hex)
            if target not in work_hashes:
                logger.warning(
                    "registry_reader.specific_work_not_in_rd",
                    studio=studio_address,
                    worker=worker_address,
                    data_hash=data_hash_hex,
                    rd_work_count=len(work_hashes),
                )
                return False

            logger.info(
                "registry_reader.worker_fully_submitted",
                studio=studio_address,
                worker=worker_address,
                escrow_wei=balance,
                rd_work_count=len(work_hashes),
            )
            return True

        except Exception:
            logger.exception(
                "registry_reader.has_worker_fully_submitted.error",
                studio=studio_address,
                worker=worker_address,
            )
            return False

    def is_work_registered(
        self,
        studio_address: str,
        epoch: int,
        data_hash_hex: str,
    ) -> bool:
        """Check if a specific dataHash is registered in RewardsDistributor.

        Parameters
        ----------
        studio_address:
            The StudioProxy contract address.
        epoch:
            The epoch number (usually 1).
        data_hash_hex:
            Hex-encoded dataHash (without 0x prefix).

        Returns
        -------
        bool
            ``True`` if the dataHash is found in ``getEpochWork(studio, epoch)``.
        """
        if not self._rewards_dist:
            return False
        try:
            studio_cs = Web3.to_checksum_address(studio_address)
            work_hashes: list[bytes] = self._rewards_dist.functions.getEpochWork(
                studio_cs, epoch
            ).call()
            target = bytes.fromhex(data_hash_hex)
            return target in work_hashes
        except Exception:
            logger.debug(
                "registry_reader.is_work_registered.error",
                studio=studio_address,
                data_hash=data_hash_hex,
            )
            return False

    def is_validator_registered(
        self,
        data_hash_hex: str,
        validator_address: str,
    ) -> bool:
        """Check if a validator is registered in RewardsDistributor for a dataHash.

        Parameters
        ----------
        data_hash_hex:
            Hex-encoded dataHash (without 0x prefix).
        validator_address:
            Ethereum address of the validator.

        Returns
        -------
        bool
            ``True`` if the validator is in ``getWorkValidators(dataHash)``.
        """
        if not self._rewards_dist:
            return False
        try:
            dh_bytes = bytes.fromhex(data_hash_hex)
            validator_cs = Web3.to_checksum_address(validator_address)
            validators: list[str] = self._rewards_dist.functions.getWorkValidators(
                dh_bytes
            ).call()
            return validator_cs.lower() in [v.lower() for v in validators]
        except Exception:
            logger.debug(
                "registry_reader.is_validator_registered.error",
                data_hash=data_hash_hex,
                validator=validator_address,
            )
            return False

    # ------------------------------------------------------------------
    # ERC-8004 Reputation
    # ------------------------------------------------------------------

    def get_agent_reputation(
        self,
        agent_address: str,
        domain: str = "prediction-settlement",
    ) -> tuple[int, int] | None:
        """Read an agent's reputation from the ERC-8004 ReputationRegistry.

        Parameters
        ----------
        agent_address:
            Ethereum address of the agent.
        domain:
            Reputation domain string (e.g. "prediction-settlement").

        Returns
        -------
        tuple[int, int] | None
            ``(value, value_decimals)`` or ``None`` if no reputation set.
            value is int128 (signed), value_decimals is uint8.
        """
        # ERC-8004 ReputationRegistry on Sepolia
        REPUTATION_REGISTRY = "0x8004B8FD1A363aa02fDC07635C0c5F94f6Af5B7E"
        REPUTATION_ABI = [
            {
                "inputs": [
                    {"name": "agent", "type": "address"},
                    {"name": "domain", "type": "string"},
                ],
                "name": "getReputation",
                "outputs": [
                    {"name": "value", "type": "int128"},
                    {"name": "valueDecimals", "type": "uint8"},
                ],
                "stateMutability": "view",
                "type": "function",
            }
        ]

        try:
            contract = self.w3.eth.contract(
                address=Web3.to_checksum_address(REPUTATION_REGISTRY),
                abi=REPUTATION_ABI,
            )
            result = contract.functions.getReputation(
                Web3.to_checksum_address(agent_address),
                domain,
            ).call()
            value, decimals = result
            logger.info(
                "registry_reader.reputation",
                agent=agent_address,
                domain=domain,
                value=value,
                decimals=decimals,
            )
            return (value, decimals)
        except Exception:
            logger.debug(
                "registry_reader.reputation_not_found",
                agent=agent_address,
                domain=domain,
            )
            return None
