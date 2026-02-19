"""
High-level wrapper around ``ChaosChainAgentSDK`` tailored for ChaosOracle agents.

Handles ERC-8004 identity registration, work submission (worker flow), and
score submission (verifier flow) via the ChaosChain Gateway.

Adapted for **chaoschain-sdk v0.4.1** API.
"""

from __future__ import annotations

import json
import os
import tempfile
import threading
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

# File used to cache agent IDs across restarts so we avoid redundant
# on-chain identity registration transactions.
_AGENT_ID_CACHE_PATH = Path("chaoschain_agent_ids.json")

# Shared evidence CID mapping (Docker shared volume).
# Workers write {dataHash: evidenceCID} here after submitting work.
# Verifiers read from this file to resolve evidence CIDs when
# getEvidenceCID() returns empty (submitWork single-agent doesn't store on-chain).
_EVIDENCE_MAP_PATH = Path(os.environ.get("SHARED_DIR", "/shared")) / "evidence_map.json"
_EVIDENCE_MAP_LOCK = threading.Lock()

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
    # ERC-8004 identity
    # ------------------------------------------------------------------

    async def auto_register(self) -> int:
        """Ensure the agent has an ERC-8004 on-chain identity.

        If the wallet already holds an agent ID (checked via the SDK and
        a local JSON cache), registration is skipped.  Otherwise a new
        identity token is minted on-chain.

        Returns
        -------
        int
            The agent's on-chain ERC-8004 token ID.
        """
        # 1. Check local cache first
        cached_id = self._load_cached_agent_id()
        if cached_id is not None:
            logger.info("sdk_client.identity_cached", agent_id=cached_id)
            self.agent_id = cached_id
            return cached_id

        # 2. Check on-chain via SDK
        on_chain_id = self.sdk.get_agent_id()
        if on_chain_id:
            logger.info("sdk_client.identity_on_chain", agent_id=on_chain_id)
            self._save_cached_agent_id(on_chain_id)
            self.agent_id = on_chain_id
            return on_chain_id

        # 3. Register new identity
        token_uri = f"https://{self._agent_domain}/.well-known/agent.json"
        agent_id, _tx = self.sdk.register_identity(token_uri=token_uri)
        logger.info("sdk_client.identity_registered", agent_id=agent_id, token_uri=token_uri)
        self._save_cached_agent_id(agent_id)
        self.agent_id = agent_id
        return agent_id

    # ------------------------------------------------------------------
    # Worker flow
    # ------------------------------------------------------------------

    async def submit_work(
        self,
        studio_address: str,
        outcome: int,
        evidence_cid: str,
    ) -> dict[str, Any]:
        """Register as a worker (with stake) and submit work to the studio.

        Parameters
        ----------
        studio_address:
            The StudioProxy contract address.
        outcome:
            Predicted outcome index (0-based).
        evidence_cid:
            Arweave / IPFS content identifier pointing to the evidence package.

        Returns
        -------
        dict
            Gateway workflow result (converted from WorkflowStatus).
        """
        logger.info(
            "sdk_client.submit_work.start",
            studio=studio_address,
            outcome=outcome,
            evidence_cid=evidence_cid,
        )

        if self.agent_id is None:
            raise RuntimeError("Agent not registered — call auto_register() first.")

        # Register with studio as worker (includes staking).
        # Tolerate "Already registered" — the worker may have registered
        # in a prior run before the agent was restarted.  The contract's
        # registerAgent checks `_agentIds[msg.sender] == 0` and reverts
        # on duplicate registration for the same wallet.
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

        # Build data hash for gateway submission
        evidence_payload_str = json.dumps(
            {"outcome": outcome, "evidence_cid": evidence_cid},
            sort_keys=True,
        )
        data_hash: bytes = self.w3.keccak(text=evidence_payload_str)

        # StudioProxy requires non-zero threadRoot and evidenceRoot
        thread_root: bytes = self.w3.keccak(text=f"thread:{studio_address}:{evidence_cid}")
        evidence_root: bytes = self.w3.keccak(text=f"evidence:{evidence_cid}")

        # Build evidence content bytes (the Gateway uploads to Arweave/IPFS)
        evidence_content = evidence_payload_str.encode()

        # submit_work_via_gateway returns a WorkflowStatus (dataclass)
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

        # Write evidence CID mapping to shared volume so verifiers can resolve it.
        # submitWork (single-agent) doesn't store the CID on-chain, so we persist
        # the mapping {dataHash: evidenceCID} in a shared JSON file.
        if state_str == "COMPLETED" and evidence_cid:
            data_hash_hex = data_hash.hex() if hasattr(data_hash, "hex") else str(data_hash)
            self._write_evidence_mapping(data_hash_hex, evidence_cid)

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
        # Tolerate "Already registered" — the verifier may score multiple workers
        # in the same studio, but only needs to register once.
        # The SDK raises a generic ContractError("Studio registration transaction
        # failed") when the tx reverts, without including the revert reason.
        # We also tolerate that generic error after the first successful registration.
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

    # ------------------------------------------------------------------
    # Evidence CID mapping (shared volume)
    # ------------------------------------------------------------------

    @staticmethod
    def _write_evidence_mapping(data_hash_hex: str, evidence_cid: str) -> None:
        """Append a ``{dataHash: evidenceCID}`` entry to the shared evidence map.

        Thread-safe via a module-level lock.  Multiple workers may run
        concurrently in the sandbox, each writing their own mapping.
        """
        with _EVIDENCE_MAP_LOCK:
            mapping: dict[str, str] = {}
            if _EVIDENCE_MAP_PATH.exists():
                try:
                    mapping = json.loads(_EVIDENCE_MAP_PATH.read_text())
                except (json.JSONDecodeError, OSError):
                    pass

            # Strip 0x prefix for consistency with registry_reader lookup
            key = data_hash_hex.removeprefix("0x")
            mapping[key] = evidence_cid

            try:
                _EVIDENCE_MAP_PATH.parent.mkdir(parents=True, exist_ok=True)
                _EVIDENCE_MAP_PATH.write_text(json.dumps(mapping, indent=2))
                logger.info(
                    "sdk_client.evidence_mapping_written",
                    data_hash=key,
                    evidence_cid=evidence_cid,
                    path=str(_EVIDENCE_MAP_PATH),
                )
            except OSError:
                logger.exception(
                    "sdk_client.evidence_mapping_write_failed",
                    data_hash=key,
                )

    # ------------------------------------------------------------------
    # Agent ID cache helpers
    # ------------------------------------------------------------------

    def _load_cached_agent_id(self) -> int | None:
        """Return the cached agent ID for this wallet, or ``None``."""
        if not _AGENT_ID_CACHE_PATH.exists():
            return None
        try:
            data: dict[str, int] = json.loads(_AGENT_ID_CACHE_PATH.read_text())
            return data.get(self.wallet_address)
        except (json.JSONDecodeError, OSError):
            return None

    def _save_cached_agent_id(self, agent_id: int) -> None:
        """Persist ``agent_id`` keyed by wallet address."""
        data: dict[str, int] = {}
        if _AGENT_ID_CACHE_PATH.exists():
            try:
                data = json.loads(_AGENT_ID_CACHE_PATH.read_text())
            except (json.JSONDecodeError, OSError):
                pass
        data[self.wallet_address] = agent_id
        _AGENT_ID_CACHE_PATH.write_text(json.dumps(data, indent=2))
        logger.debug("sdk_client.agent_id_cached", path=str(_AGENT_ID_CACHE_PATH))


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
