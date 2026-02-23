"""
XMTP Bridge client for ChaosOracle Python agents.

Provides HTTP access to the XMTP network via the ``@chaoschain/xmtp-bridge``
Express service. Workers send DKG nodes as XMTP messages after research;
verifiers fetch DKG history to perform causal audits.

Bridge API:
    POST /v1/agents/register   — register agent with private key
    POST /v1/messages/send     — send message with DKG metadata
    POST /v1/threads/get       — fetch conversation thread as DKG graph
    GET  /v1/conversations     — list conversations
    POST /v1/agents/disconnect — cleanup
"""

from __future__ import annotations

from typing import Any

import aiohttp
import structlog

logger = structlog.get_logger(__name__)


class XMTPClient:
    """HTTP client for the XMTP bridge service.

    Parameters
    ----------
    bridge_url:
        URL of the xmtp-bridge Express server (e.g. ``http://xmtp-bridge:3847``).
    private_key:
        Hex-encoded Ethereum private key for agent identity.
    agent_id:
        Optional ERC-8004 agent ID (int).
    api_key:
        Optional API key for bridge authentication.
    """

    def __init__(
        self,
        bridge_url: str,
        private_key: str,
        agent_id: int | None = None,
        api_key: str | None = None,
    ) -> None:
        self._bridge_url = bridge_url.rstrip("/")
        self._private_key = private_key
        self._agent_id = agent_id
        self._api_key = api_key
        self._session_token: str | None = None
        self._address: str | None = None

    @property
    def is_registered(self) -> bool:
        return self._session_token is not None

    def _headers(self) -> dict[str, str]:
        headers: dict[str, str] = {"Content-Type": "application/json"}
        if self._api_key:
            headers["X-API-Key"] = self._api_key
        return headers

    async def register(self) -> str:
        """Register this agent with the XMTP bridge.

        Returns the agent's Ethereum address.
        """
        payload: dict[str, Any] = {"private_key": self._private_key}
        if self._agent_id is not None:
            payload["agent_id"] = self._agent_id

        async with aiohttp.ClientSession() as session:
            async with session.post(
                f"{self._bridge_url}/v1/agents/register",
                json=payload,
                headers=self._headers(),
            ) as resp:
                data = await resp.json()
                if not data.get("success"):
                    raise RuntimeError(f"XMTP bridge registration failed: {data}")

                self._session_token = data["session_token"]
                self._address = data["address"]
                logger.info(
                    "xmtp.registered",
                    address=self._address,
                    inbox_id=data.get("inbox_id"),
                )
                return self._address

    async def send_message(
        self,
        to: str,
        content: dict[str, Any],
        parent_ids: list[str] | None = None,
        artifact_ids: list[str] | None = None,
    ) -> tuple[str, dict[str, Any]]:
        """Send a message with DKG metadata.

        Parameters
        ----------
        to:
            Recipient Ethereum address.
        content:
            Message content dict (arbitrary JSON).
        parent_ids:
            Causal parent XMTP message IDs.
        artifact_ids:
            Evidence CIDs (Arweave/IPFS).

        Returns
        -------
        tuple[str, dict]
            (message_id, dkg_node_dict)
        """
        if not self._session_token:
            raise RuntimeError("Not registered — call register() first")

        payload: dict[str, Any] = {
            "session_token": self._session_token,
            "to": to,
            "content": content,
        }
        if parent_ids:
            payload["parent_ids"] = parent_ids
        if artifact_ids:
            payload["artifact_ids"] = artifact_ids

        async with aiohttp.ClientSession() as session:
            async with session.post(
                f"{self._bridge_url}/v1/messages/send",
                json=payload,
                headers=self._headers(),
            ) as resp:
                data = await resp.json()
                if not data.get("success"):
                    raise RuntimeError(f"XMTP send failed: {data}")

                msg_id = data["message_id"]
                dkg_node = data.get("dkg_node", {})
                logger.info(
                    "xmtp.message_sent",
                    message_id=msg_id,
                    to=to,
                    parent_count=len(parent_ids or []),
                    artifact_count=len(artifact_ids or []),
                )
                return msg_id, dkg_node

    async def get_thread(
        self,
        peer_address: str,
        limit: int = 100,
    ) -> dict[str, Any]:
        """Fetch a conversation thread as a DKG graph.

        Parameters
        ----------
        peer_address:
            Ethereum address of the conversation peer.
        limit:
            Max messages to fetch.

        Returns
        -------
        dict
            ``{"nodes": [...], "thread_root": "0x...", "edges": [...]}``
        """
        if not self._session_token:
            raise RuntimeError("Not registered — call register() first")

        payload = {
            "session_token": self._session_token,
            "peer_address": peer_address,
            "limit": limit,
        }

        async with aiohttp.ClientSession() as session:
            async with session.post(
                f"{self._bridge_url}/v1/threads/get",
                json=payload,
                headers=self._headers(),
            ) as resp:
                data = await resp.json()
                if not data.get("success"):
                    raise RuntimeError(f"XMTP get_thread failed: {data}")

                logger.info(
                    "xmtp.thread_fetched",
                    peer=peer_address,
                    node_count=len(data.get("nodes", [])),
                    thread_root=data.get("thread_root", "")[:18],
                )
                return data

    async def disconnect(self) -> None:
        """Disconnect from the XMTP bridge."""
        if not self._session_token:
            return

        try:
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    f"{self._bridge_url}/v1/agents/disconnect",
                    json={"session_token": self._session_token},
                    headers=self._headers(),
                ) as resp:
                    await resp.json()
        except Exception:
            logger.debug("xmtp.disconnect_error")
        finally:
            self._session_token = None
            logger.info("xmtp.disconnected")
