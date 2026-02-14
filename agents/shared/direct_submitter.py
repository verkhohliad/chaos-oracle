"""
Direct web3 contract submitter for local testing mode.

Replaces the ChaosChain Gateway for local (anvil fork) testing.  Calls
``registerAsWorker`` / ``submitWork`` / ``registerAsVerifier`` /
``submitScores`` directly on StudioProxy contracts via raw transactions.

No x402 payments, no ERC-8004 identity — just plain web3 calls.
"""

from __future__ import annotations

from typing import Any

import structlog
from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware

from shared.constants import (
    PREDICTION_SETTLEMENT_LOGIC_ABI,
    WORKER_STAKE_WEI,
    VERIFIER_STAKE_WEI,
)

logger = structlog.get_logger(__name__)


class DirectSubmitter:
    """Direct web3 contract calls — replaces ChaosChain Gateway for local mode.

    Implements the same public interface as :class:`ChaosOracleSDKClient` so
    the worker/verifier main loops can use either client interchangeably.

    Parameters
    ----------
    rpc_url:
        Ethereum JSON-RPC endpoint (e.g. ``http://anvil:8545``).
    private_key:
        Hex-encoded private key for the agent wallet.
    """

    def __init__(self, rpc_url: str, private_key: str) -> None:
        self.w3 = Web3(Web3.HTTPProvider(rpc_url))
        self.w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)

        self._account = self.w3.eth.account.from_key(private_key)
        self.wallet_address: str = self._account.address
        self.agent_id: int | None = 0  # No ERC-8004 identity in local mode

        logger.info(
            "direct_submitter.initialized",
            wallet=self.wallet_address,
            rpc=rpc_url,
            mode="local",
        )

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    def _studio_contract(self, studio_address: str):
        """Return a web3 Contract bound to a studio proxy."""
        return self.w3.eth.contract(
            address=Web3.to_checksum_address(studio_address),
            abi=PREDICTION_SETTLEMENT_LOGIC_ABI,
        )

    def _send_tx(self, tx_data: dict) -> str:
        """Sign, send, and wait for a transaction.  Returns the tx hash hex."""
        signed = self._account.sign_transaction(tx_data)
        tx_hash = self.w3.eth.send_raw_transaction(signed.raw_transaction)
        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
        if receipt["status"] != 1:
            raise RuntimeError(
                f"Transaction reverted: {tx_hash.hex()} "
                f"(gas used: {receipt['gasUsed']})"
            )
        return tx_hash.hex()

    def _build_tx(self, fn, value: int = 0) -> dict:
        """Build a transaction dict from a contract function call."""
        return fn.build_transaction({
            "from": self._account.address,
            "value": value,
            "nonce": self.w3.eth.get_transaction_count(self._account.address),
            "gas": 500_000,
            "gasPrice": self.w3.eth.gas_price,
        })

    # ------------------------------------------------------------------
    # Identity (no-op in local mode)
    # ------------------------------------------------------------------

    async def auto_register(self) -> int:
        """No-op — ERC-8004 identity is not needed for local testing.

        Returns
        -------
        int
            Always returns ``0``.
        """
        logger.info("direct_submitter.auto_register.skipped", msg="No ERC-8004 in local mode")
        return 0

    # ------------------------------------------------------------------
    # Worker flow
    # ------------------------------------------------------------------

    async def submit_work(
        self,
        studio_address: str,
        outcome: int,
        evidence_cid: str,
    ) -> dict[str, Any]:
        """Register as worker (if needed) and submit work to a studio.

        Parameters
        ----------
        studio_address:
            The StudioProxy contract address.
        outcome:
            Predicted outcome index (0-based).
        evidence_cid:
            Content identifier for the evidence package.

        Returns
        -------
        dict
            Result with ``state`` key for compatibility with SDK client.
        """
        studio = self._studio_contract(studio_address)

        # 1. Register as worker if not already registered
        if not studio.functions.isWorkerRegistered(self._account.address).call():
            logger.info(
                "direct_submitter.register_worker",
                studio=studio_address,
                stake=Web3.from_wei(WORKER_STAKE_WEI, "ether"),
            )
            tx = self._build_tx(
                studio.functions.registerAsWorker(),
                value=WORKER_STAKE_WEI,
            )
            tx_hash = self._send_tx(tx)
            logger.info("direct_submitter.worker_registered", tx=tx_hash)
        else:
            logger.info("direct_submitter.worker_already_registered", studio=studio_address)

        # 2. Submit work
        logger.info(
            "direct_submitter.submit_work",
            studio=studio_address,
            outcome=outcome,
            evidence_cid=evidence_cid,
        )
        tx = self._build_tx(studio.functions.submitWork(outcome, evidence_cid))
        tx_hash = self._send_tx(tx)
        logger.info("direct_submitter.work_submitted", tx=tx_hash)

        return {"state": "completed", "tx": tx_hash}

    # ------------------------------------------------------------------
    # Verifier flow
    # ------------------------------------------------------------------

    async def submit_scores(
        self,
        studio_address: str,
        worker_address: str,
        scores: list[int],
    ) -> dict[str, Any]:
        """Register as verifier (if needed) and submit scores for a worker.

        Parameters
        ----------
        studio_address:
            The StudioProxy contract address.
        worker_address:
            Ethereum address of the worker being scored.
        scores:
            ``[accuracy, evidence_quality, source_diversity, reasoning_depth]``,
            each 0-100.

        Returns
        -------
        dict
            Result with ``state`` key for compatibility with SDK client.
        """
        studio = self._studio_contract(studio_address)

        # 1. Register as verifier if not already registered
        if not studio.functions.isVerifierRegistered(self._account.address).call():
            logger.info(
                "direct_submitter.register_verifier",
                studio=studio_address,
                stake=Web3.from_wei(VERIFIER_STAKE_WEI, "ether"),
            )
            tx = self._build_tx(
                studio.functions.registerAsVerifier(),
                value=VERIFIER_STAKE_WEI,
            )
            tx_hash = self._send_tx(tx)
            logger.info("direct_submitter.verifier_registered", tx=tx_hash)
        else:
            logger.info("direct_submitter.verifier_already_registered", studio=studio_address)

        # 2. Submit scores
        logger.info(
            "direct_submitter.submit_scores",
            studio=studio_address,
            worker=worker_address,
            scores=scores,
        )
        tx = self._build_tx(
            studio.functions.submitScores(
                Web3.to_checksum_address(worker_address),
                scores,
            )
        )
        tx_hash = self._send_tx(tx)
        logger.info("direct_submitter.scores_submitted", tx=tx_hash)

        return {"state": "completed", "tx": tx_hash}
