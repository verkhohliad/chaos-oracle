"""
High-level wrapper around ``ChaosChainAgentSDK`` tailored for ChaosOracle agents.

Handles ERC-8004 identity registration, work submission (worker flow), and
score submission (verifier flow) via the ChaosChain Gateway.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

from typing import TYPE_CHECKING

import structlog

if TYPE_CHECKING:
    from chaoschain_sdk import (
        AgentRole,
        ChaosChainAgentSDK,
        NetworkConfig,
        X402PaymentManager,
        GatewayClient,
    )

from shared.constants import (
    WORKER_STAKE_WEI,
    VERIFIER_STAKE_WEI,
)

logger = structlog.get_logger(__name__)

# File used to cache agent IDs across restarts so we avoid redundant
# on-chain identity registration transactions.
_AGENT_ID_CACHE_PATH = Path("chaoschain_agent_ids.json")


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
            X402PaymentManager,
        )

        if agent_role is None:
            agent_role = _AgentRole.WORKER

        self._private_key = private_key
        self._network = network
        self._gateway_url = gateway_url
        self._agent_name = agent_name
        self._agent_domain = agent_domain

        self.sdk = ChaosChainAgentSDK(
            agent_name=agent_name,
            agent_domain=agent_domain,
            agent_role=agent_role,
            network=network,
            private_key=private_key,
            enable_process_integrity=True,
            gateway_url=gateway_url,
        )

        self.payment_manager = X402PaymentManager(
            private_key=private_key,
            network=network,
        )

        self.gateway: GatewayClient = self.sdk.gateway

        self.agent_id: int | None = None
        self.wallet_address: str = self.sdk.wallet_manager.address

        logger.info(
            "sdk_client.initialized",
            wallet=self.wallet_address,
            network=str(network),
            role=str(agent_role),
        )

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
        on_chain_id = self.sdk.chaos_agent.get_agent_id()
        if on_chain_id:
            logger.info("sdk_client.identity_on_chain", agent_id=on_chain_id)
            self._save_cached_agent_id(on_chain_id)
            self.agent_id = on_chain_id
            return on_chain_id

        # 3. Register new identity
        token_uri = f"https://{self._agent_domain}/.well-known/agent.json"
        agent_id, _tx = self.sdk.register_agent(token_uri=token_uri)
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
            Gateway workflow result.
        """
        logger.info(
            "sdk_client.submit_work.start",
            studio=studio_address,
            outcome=outcome,
            evidence_cid=evidence_cid,
        )

        # Register with studio as worker (includes staking)
        from chaoschain_sdk import AgentRole

        self.sdk.register_with_studio(
            studio_address,
            AgentRole.WORKER,
            stake_amount=WORKER_STAKE_WEI,
        )
        logger.info("sdk_client.worker_registered", studio=studio_address)

        # Build data hash for gateway submission
        evidence_payload_str = json.dumps(
            {"outcome": outcome, "evidence_cid": evidence_cid},
            sort_keys=True,
        )
        data_hash = self.sdk.w3.keccak(text=evidence_payload_str)

        workflow = self.sdk.submit_work_via_gateway(
            studio_address=studio_address,
            epoch=1,
            data_hash=data_hash,
            thread_root=b"\x00" * 32,
            evidence_root=b"\x00" * 32,
            signer_address=self.wallet_address,
        )

        result = self.gateway.wait_for_completion(workflow["id"], timeout=120)
        logger.info(
            "sdk_client.submit_work.done",
            studio=studio_address,
            state=result.get("state"),
        )
        return result

    # ------------------------------------------------------------------
    # Verifier flow
    # ------------------------------------------------------------------

    async def submit_scores(
        self,
        studio_address: str,
        worker_address: str,
        scores: list[int],
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

        Returns
        -------
        dict
            Gateway workflow result.
        """
        logger.info(
            "sdk_client.submit_scores.start",
            studio=studio_address,
            worker=worker_address,
            scores=scores,
        )

        # Register with studio as verifier (includes staking)
        from chaoschain_sdk import AgentRole

        self.sdk.register_with_studio(
            studio_address,
            AgentRole.VERIFIER,
            stake_amount=VERIFIER_STAKE_WEI,
        )
        logger.info("sdk_client.verifier_registered", studio=studio_address)

        # Build data hash referencing the worker submission
        data_hash = self.sdk.w3.keccak(text=worker_address.lower())

        score_workflow = self.sdk.submit_score_via_gateway(
            studio_address=studio_address,
            epoch=1,
            data_hash=data_hash,
            worker_address=worker_address,
            scores=scores,
            signer_address=self.wallet_address,
        )

        result = self.gateway.wait_for_completion(score_workflow["id"], timeout=180)
        logger.info(
            "sdk_client.submit_scores.done",
            studio=studio_address,
            worker=worker_address,
            state=result.get("state"),
        )
        return result

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
    mode: str,
    private_key: str,
    rpc_url: str = "",
    network: Any = None,
    gateway_url: str = "",
    agent_name: str = "ChaosOracleAgent",
    agent_domain: str = "agent.chaosoracle.example.com",
    agent_role: Any = None,
) -> "ChaosOracleSDKClient | DirectSubmitter":
    """Create the appropriate SDK client based on *mode*.

    Parameters
    ----------
    mode:
        ``"local"`` for direct web3 calls (no Gateway / x402 / ERC-8004),
        ``"gateway"`` for production ChaosChain Gateway.
    private_key:
        Hex-encoded private key for the agent wallet.
    rpc_url:
        Ethereum JSON-RPC endpoint (required for ``"local"`` mode).
    network:
        :class:`NetworkConfig` value (required for ``"gateway"`` mode).
    gateway_url:
        ChaosChain Gateway URL (required for ``"gateway"`` mode).
    agent_name:
        Human-readable agent name.
    agent_domain:
        Domain claim for the agent identity token URI.
    agent_role:
        ``AgentRole.WORKER`` or ``AgentRole.VERIFIER``.
    """
    if mode == "local":
        from shared.direct_submitter import DirectSubmitter

        return DirectSubmitter(rpc_url=rpc_url, private_key=private_key)

    # Default: gateway mode
    return ChaosOracleSDKClient(
        private_key=private_key,
        network=network,
        gateway_url=gateway_url,
        agent_name=agent_name,
        agent_domain=agent_domain,
        agent_role=agent_role,
    )
