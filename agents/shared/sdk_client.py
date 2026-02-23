"""
High-level wrapper around ``ChaosChainAgentSDK`` tailored for ChaosOracle agents.

Handles ERC-8004 identity registration, work submission (worker flow), and
score submission (verifier flow) via the ChaosChain Gateway.

Adapted for **chaoschain-sdk v0.4.1** API.
"""

from __future__ import annotations

import json
import tempfile
from pathlib import Path
from typing import Any, TYPE_CHECKING

import structlog

if TYPE_CHECKING:
    from chaoschain_sdk import (
        AgentRole,
        ChaosChainAgentSDK,
        NetworkConfig,
    )
    from chaoschain_sdk.gateway_client import GatewayClient

from shared.constants import (
    STUDIO_PROXY_WITHDRAW_ABI,
    WORKER_STAKE_WEI,
    VERIFIER_STAKE_WEI,
)

logger = structlog.get_logger(__name__)

# SDK role integers (StudioProxy registerAgent uses uint8 role codes)
_ROLE_WORKER = 1
_ROLE_VERIFIER = 2


def _prepare_wallet_file(agent_name: str, private_key: str) -> str:
    """Create a ``chaoschain_wallets.json`` file pre-loaded with *private_key*.

    The SDK's ``WalletManager`` expects a JSON file keyed by agent name.
    By writing the private key here we avoid the SDK generating a random
    wallet and ensure it uses the caller-provided key.

    Returns the path to the wallet file.
    """
    from eth_account import Account

    account = Account.from_key(private_key)
    wallet_data = {
        agent_name: {
            "address": account.address,
            "private_key": private_key if private_key.startswith("0x") else f"0x{private_key}",
        }
    }
    wallet_path = Path(tempfile.gettempdir()) / f"chaoschain_wallet_{agent_name}.json"
    wallet_path.write_text(json.dumps(wallet_data, indent=2))
    return str(wallet_path)


class ChaosOracleSDKClient:
    """Wraps :class:`ChaosChainAgentSDK` with ChaosOracle-specific helpers.

    Parameters
    ----------
    private_key:
        Hex-encoded Ethereum private key for the agent wallet.
    network:
        :class:`NetworkConfig` value (e.g. ``NetworkConfig.ETHEREUM_SEPOLIA``).
    gateway_url:
        URL of the ChaosChain Gateway.
    agent_name:
        Human-readable agent name used during ERC-8004 registration.
    agent_domain:
        Domain claim for the agent identity token URI.
    agent_role:
        ``AgentRole.WORKER`` or ``AgentRole.VERIFIER``.
    """

    def __init__(
        self,
        private_key: str,
        network: NetworkConfig,
        gateway_url: str,
        agent_name: str = "ChaosOracleAgent",
        agent_domain: str = "agent.chaosoracle.example.com",
        agent_role: AgentRole | None = None,
    ) -> None:
        from chaoschain_sdk import (
            AgentRole as _AgentRole,
            ChaosChainAgentSDK,
        )

        if agent_role is None:
            agent_role = _AgentRole.WORKER

        self._private_key = private_key
        self._network = network
        self._gateway_url = gateway_url
        self._agent_name = agent_name
        self._agent_domain = agent_domain

        # Pre-create wallet file so the SDK uses our private key.
        wallet_file = _prepare_wallet_file(agent_name, private_key)

        self.sdk: ChaosChainAgentSDK = ChaosChainAgentSDK(
            agent_name=agent_name,
            agent_domain=agent_domain,
            agent_role=agent_role,
            network=network,
            enable_process_integrity=True,
            wallet_file=wallet_file,
            gateway_url=gateway_url,
        )

        # Redirect ERC-8004 agent ID cache to /app/cache/ so Docker volumes
        # persist it across container rebuilds (avoids minting a new NFT each
        # time).  The SDK defaults to os.getcwd() which is ephemeral.
        cache_dir = Path("/app/cache")
        if cache_dir.is_dir():
            cache_path = str(cache_dir / "chaoschain_agent_ids.json")
            self.sdk.chaos_agent._get_cache_file_path = lambda: cache_path  # type: ignore[assignment]
            logger.debug("sdk_client.cache_path_override", path=cache_path)

        # Convenience aliases
        self.gateway: GatewayClient | None = self.sdk.gateway
        self.agent_id: int | None = None
        self.wallet_address: str = self.sdk.wallet_address

        logger.info(
            "sdk_client.initialized",
            wallet=self.wallet_address,
            network=str(network),
            role=str(agent_role),
        )

    # ------------------------------------------------------------------
    # Web3 helper
    # ------------------------------------------------------------------

    @property
    def w3(self):
        """Shortcut to the SDK's Web3 instance."""
        return self.sdk.chaos_agent.w3

    # ------------------------------------------------------------------
    # Studio registration check
    # ------------------------------------------------------------------

    def _is_registered_in_studio(self, studio_address: str) -> bool:
        """Check if this agent is already registered in a StudioProxy.

        Uses ``getEscrowBalance(agent) > 0`` as the indicator — registerAgent()
        requires ``msg.value > 0`` so a non-zero escrow means the agent has
        already registered and staked.
        """
        try:
            from web3 import Web3

            proxy = self.w3.eth.contract(
                address=Web3.to_checksum_address(studio_address),
                abi=STUDIO_PROXY_WITHDRAW_ABI,
            )
            balance = proxy.functions.getEscrowBalance(
                Web3.to_checksum_address(self.wallet_address)
            ).call()
            return balance > 0
        except Exception:
            logger.debug(
                "sdk_client.registration_check_failed",
                studio=studio_address,
                wallet=self.wallet_address,
            )
            return False  # On error, proceed with registration attempt

    # ------------------------------------------------------------------
    # ERC-8004 identity
    # ------------------------------------------------------------------

    async def auto_register(self) -> int:
        """Ensure the agent has an ERC-8004 on-chain identity.

        Uses the SDK's built-in identity lookup (with its own cache in
        ``chaos_agent.py``).  If no identity exists, mints a new one.

        Returns
        -------
        int
            The agent's on-chain ERC-8004 token ID.
        """
        # 1. Check on-chain via SDK (SDK has its own cache layer)
        on_chain_id = self.sdk.get_agent_id()
        if on_chain_id:
            logger.info("sdk_client.identity_found", agent_id=on_chain_id)
            self.agent_id = on_chain_id
            self._verify_identity_ownership(on_chain_id)
            # Ensure cache is populated (SDK register_agent doesn't always save).
            self._save_agent_id_cache(on_chain_id)
            return on_chain_id

        # 2. Register new identity
        token_uri = f"https://{self._agent_domain}/.well-known/agent.json"
        agent_id, _tx = self.sdk.register_identity(token_uri=token_uri)
        logger.info("sdk_client.identity_registered", agent_id=agent_id, token_uri=token_uri)
        self.agent_id = agent_id
        # Explicitly save to cache — the SDK's register_agent() doesn't always
        # call _save_agent_id_to_cache() on the success path.
        self._save_agent_id_cache(agent_id)
        return agent_id

    def _save_agent_id_cache(self, agent_id: int) -> None:
        """Persist agent ID via the SDK's own cache mechanism.

        This ensures the cache file is written even when the SDK's
        ``register_agent()`` path skips the save.
        """
        try:
            self.sdk.chaos_agent._save_agent_id_to_cache(agent_id)
            logger.debug("sdk_client.cache_saved", agent_id=agent_id)
        except Exception as exc:
            logger.warning("sdk_client.cache_save_failed", error=str(exc))

    def _verify_identity_ownership(self, agent_id: int) -> None:
        """Verify this wallet actually owns the given agent ID on-chain.

        Raises :class:`RuntimeError` if the IdentityRegistry reports a
        different owner — this catches stale SDK cache or Enumerable
        iteration bugs before they cause an on-chain revert.
        """
        try:
            identity_registry = self.sdk.chaos_agent.identity_registry
            owner = identity_registry.functions.ownerOf(agent_id).call()
            if owner.lower() != self.wallet_address.lower():
                raise RuntimeError(
                    f"Agent ID {agent_id} is owned by {owner}, not by "
                    f"{self.wallet_address}. The SDK cache may be stale — "
                    f"delete chaoschain_agent_ids.json and restart."
                )
            logger.debug(
                "sdk_client.identity_ownership_verified",
                agent_id=agent_id,
                owner=owner,
            )
        except RuntimeError:
            raise
        except Exception as exc:
            logger.warning(
                "sdk_client.identity_ownership_check_failed",
                agent_id=agent_id,
                error=str(exc),
            )

    # ------------------------------------------------------------------
    # Worker flow
    # ------------------------------------------------------------------

    async def submit_work(
        self,
        studio_address: str,
        outcome: int,
        evidence_content: bytes,
    ) -> dict[str, Any]:
        """Register as a worker (with stake) and submit work to the studio.

        The Gateway handles: Arweave upload → StudioProxy.submitWork() →
        RewardsDistributor.registerWork().

        Parameters
        ----------
        studio_address:
            The StudioProxy contract address.
        outcome:
            Predicted outcome index (0-based).
        evidence_content:
            Raw evidence bytes (JSON-encoded evidence package). The Gateway
            uploads this to Arweave and stores the CID.

        Returns
        -------
        dict
            Gateway workflow result (converted from WorkflowStatus).
        """
        logger.info(
            "sdk_client.submit_work.start",
            studio=studio_address,
            outcome=outcome,
            evidence_size=len(evidence_content),
        )

        if self.agent_id is None:
            raise RuntimeError("Agent not registered — call auto_register() first.")

        # Register with studio as worker (includes staking).
        # Pre-flight check: skip if already registered (avoids wasted gas + gateway timeout).
        if self._is_registered_in_studio(studio_address):
            logger.info("sdk_client.worker_already_registered_onchain", studio=studio_address)
        else:
            try:
                self.sdk.register_with_studio(
                    studio_address,
                    agent_id=self.agent_id,
                    role=_ROLE_WORKER,
                    stake_amount=WORKER_STAKE_WEI,
                )
                logger.info("sdk_client.worker_registered", studio=studio_address)
            except Exception as exc:
                exc_str = str(exc)
                if "Already registered" in exc_str or "registration transaction failed" in exc_str:
                    logger.debug("sdk_client.worker_already_registered", studio=studio_address)
                else:
                    raise

        # Build DKG node and compute proper thread_root / evidence_root
        from shared.dkg_client import DKGBuilder

        dkg = DKGBuilder(
            wallet_address=self.wallet_address,
            private_key=self._private_key,
        )

        data_hash: bytes = self.w3.keccak(evidence_content)
        # Use data_hash hex as artifact_id so evidence_root is non-zero.
        # The actual Arweave CID isn't known yet (gateway uploads later),
        # but the contract just needs a non-zero Merkle root.
        artifact_id = "0x" + data_hash.hex()
        dkg.add_work_node(
            evidence_content=evidence_content,
            artifact_ids=[artifact_id],
        )

        thread_root: bytes = dkg.compute_thread_root()
        evidence_root: bytes = dkg.compute_evidence_root()

        # submit_work_via_gateway returns a WorkflowStatus (dataclass).
        # The SDK passes signer_address=self.wallet_address (agent's key) to Gateway.
        # Gateway uses that signer for StudioProxy.submitWork() and the default
        # signer (deployer) for RewardsDistributor.registerWork().
        workflow_status = self.sdk.submit_work_via_gateway(
            studio_address=studio_address,
            epoch=1,
            data_hash=data_hash,
            thread_root=thread_root,
            evidence_root=evidence_root,
            evidence_content=evidence_content,
            wait_for_completion=True,
        )

        state_str = workflow_status.state.value if hasattr(workflow_status.state, "value") else str(workflow_status.state)
        logger.info(
            "sdk_client.submit_work.done",
            studio=studio_address,
            state=state_str,
        )

        return {"state": state_str, "id": workflow_status.id}

    # ------------------------------------------------------------------
    # Verifier flow
    # ------------------------------------------------------------------

    async def submit_scores(
        self,
        studio_address: str,
        worker_address: str,
        scores: list[int],
        data_hash: str | None = None,
    ) -> dict[str, Any]:
        """Register as a verifier (with stake) and submit scores for a worker.

        Parameters
        ----------
        studio_address:
            The StudioProxy contract address.
        worker_address:
            Ethereum address of the worker being scored.
        scores:
            List of score values ``[accuracy, evidence_quality,
            source_diversity, reasoning_depth]``, each 0-100.
        data_hash:
            The on-chain data hash from the WorkSubmitted event. If not
            provided, falls back to ``keccak(worker_address)`` (legacy).

        Returns
        -------
        dict
            Gateway workflow result (converted from WorkflowStatus).
        """
        logger.info(
            "sdk_client.submit_scores.start",
            studio=studio_address,
            worker=worker_address,
            scores=scores,
        )

        if self.agent_id is None:
            raise RuntimeError("Agent not registered — call auto_register() first.")

        # Register with studio as verifier (includes staking).
        # Pre-flight check: skip if already registered (avoids wasted gas + gateway timeout).
        # The verifier may score multiple workers in the same studio but only
        # needs to register once.
        if self._is_registered_in_studio(studio_address):
            logger.info("sdk_client.verifier_already_registered_onchain", studio=studio_address)
        else:
            try:
                self.sdk.register_with_studio(
                    studio_address,
                    agent_id=self.agent_id,
                    role=_ROLE_VERIFIER,
                    stake_amount=VERIFIER_STAKE_WEI,
                )
                logger.info("sdk_client.verifier_registered", studio=studio_address)
            except Exception as exc:
                exc_str = str(exc)
                if "Already registered" in exc_str or "registration transaction failed" in exc_str:
                    logger.debug("sdk_client.verifier_already_registered", studio=studio_address)
                else:
                    raise

        # Normalise data_hash to bytes for the SDK.
        if data_hash is None:
            data_hash_bytes: bytes = self.w3.keccak(text=worker_address.lower())
        elif isinstance(data_hash, str):
            data_hash_bytes = bytes.fromhex(data_hash.removeprefix("0x"))
        else:
            data_hash_bytes = data_hash

        # Use submit_score_via_gateway (DIRECT mode).
        # DIRECT mode: simple scoring via submitScoreVectorForWorker.
        # Requires worker_address.  The gateway handles the on-chain tx,
        # confirmation, and registerValidator on RewardsDistributor.
        #
        # Gateway expects scores in basis points (0-10000) and divides by 100
        # to get uint8 (0-100) for on-chain storage.  Our auditor returns
        # scores in 0-100, so multiply by 100 here.
        scores_bp = [s * 100 for s in scores]
        workflow_status = self.sdk.submit_score_via_gateway(
            studio_address=studio_address,
            epoch=1,
            data_hash=data_hash_bytes,
            scores=scores_bp,
            worker_address=worker_address,
            mode="direct",
            wait_for_completion=True,
        )

        state_str = workflow_status.state.value if hasattr(workflow_status.state, "value") else str(workflow_status.state)
        logger.info(
            "sdk_client.submit_scores.done",
            studio=studio_address,
            worker=worker_address,
            state=state_str,
        )
        return {"state": state_str, "id": workflow_status.id}

    # ------------------------------------------------------------------
    # Close epoch flow
    # ------------------------------------------------------------------

    async def close_epoch(
        self,
        studio_address: str,
        epoch: int = 1,
    ) -> dict[str, Any]:
        """Close an epoch on the RewardsDistributor via the Gateway.

        Triggers consensus finalisation and reward distribution.  This is
        economically final and cannot be undone.

        Parameters
        ----------
        studio_address:
            The StudioProxy contract address.
        epoch:
            The epoch number to close (default 1 for sandbox).

        Returns
        -------
        dict
            Gateway workflow result (converted from WorkflowStatus).
        """
        logger.info(
            "sdk_client.close_epoch.start",
            studio=studio_address,
            epoch=epoch,
        )

        workflow_status = self.sdk.close_epoch_via_gateway(
            studio_address=studio_address,
            epoch=epoch,
            wait_for_completion=True,
        )

        state_str = workflow_status.state.value if hasattr(workflow_status.state, "value") else str(workflow_status.state)
        logger.info(
            "sdk_client.close_epoch.done",
            studio=studio_address,
            epoch=epoch,
            state=state_str,
        )
        return {"state": state_str, "id": workflow_status.id}

    # ------------------------------------------------------------------
    # Withdraw flow
    # ------------------------------------------------------------------

    async def withdraw_from_studio(self, studio_address: str) -> bool:
        """Withdraw available funds (stakes + rewards) from a settled studio.

        Uses the SDK's internal web3 instance to call ``withdraw()``
        directly on the StudioProxy (no Gateway workflow needed).

        Parameters
        ----------
        studio_address:
            The StudioProxy contract address.

        Returns
        -------
        bool
            ``True`` if the withdrawal transaction succeeded,
            ``False`` if it reverted or there was nothing to withdraw.
        """
        from web3 import Web3

        w3 = self.w3
        account = w3.eth.account.from_key(self._private_key)

        proxy = w3.eth.contract(
            address=Web3.to_checksum_address(studio_address),
            abi=STUDIO_PROXY_WITHDRAW_ABI,
        )

        # Check if there is anything to withdraw.
        # Use getWithdrawableBalance (the _withdrawable mapping) — this is
        # what withdraw() actually checks.  getEscrowBalance is the deposit
        # record and stays non-zero even after withdrawal.
        try:
            balance = proxy.functions.getWithdrawableBalance(account.address).call()
            logger.info(
                "sdk_client.withdraw.balance_check",
                studio=studio_address,
                withdrawable_wei=balance,
            )
            if balance == 0:
                logger.info(
                    "sdk_client.withdraw.nothing_to_withdraw",
                    studio=studio_address,
                )
                return False  # Retry later — closeEpoch may not have been called yet
        except Exception:
            # getWithdrawableBalance may not exist; proceed anyway
            logger.debug(
                "sdk_client.withdraw.balance_check_skipped",
                studio=studio_address,
            )

        try:
            tx = proxy.functions.withdraw().build_transaction({
                "from": account.address,
                "value": 0,
                "nonce": w3.eth.get_transaction_count(account.address),
                "gas": 200_000,
                "gasPrice": w3.eth.gas_price,
            })
            signed = account.sign_transaction(tx)
            tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
            receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)

            if receipt["status"] != 1:
                logger.warning(
                    "sdk_client.withdraw.reverted",
                    studio=studio_address,
                    tx=tx_hash.hex(),
                )
                return False

            logger.info(
                "sdk_client.withdraw.success",
                studio=studio_address,
                tx=tx_hash.hex(),
            )
            return True
        except Exception:
            logger.exception(
                "sdk_client.withdraw.failed",
                studio=studio_address,
            )
            return False



# ---------------------------------------------------------------------------
# Factory function
# ---------------------------------------------------------------------------


def create_sdk_client(
    private_key: str,
    network: Any = None,
    gateway_url: str = "",
    agent_name: str = "ChaosOracleAgent",
    agent_domain: str = "agent.chaosoracle.example.com",
    agent_role: Any = None,
    **kwargs: Any,
) -> "ChaosOracleSDKClient":
    """Create a ChaosChain SDK client for gateway mode.

    Parameters
    ----------
    private_key:
        Hex-encoded private key for the agent wallet.
    network:
        :class:`NetworkConfig` value (e.g. ``NetworkConfig.ETHEREUM_SEPOLIA``).
    gateway_url:
        ChaosChain Gateway URL.
    agent_name:
        Human-readable agent name.
    agent_domain:
        Domain claim for the agent identity token URI.
    agent_role:
        ``AgentRole.WORKER`` or ``AgentRole.VERIFIER``.
    **kwargs:
        Ignored (for backwards compatibility with old ``mode``/``rpc_url`` args).
    """
    return ChaosOracleSDKClient(
        private_key=private_key,
        network=network,
        gateway_url=gateway_url,
        agent_name=agent_name,
        agent_domain=agent_domain,
        agent_role=agent_role,
    )
