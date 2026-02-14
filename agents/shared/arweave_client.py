"""
Arweave evidence upload / download client for ChaosOracle agents.

Evidence packages are JSON objects conforming to the schema below and are
stored on Arweave for permanent, verifiable access.  The returned CID
(content identifier) is submitted on-chain as ``evidenceCID``.

Evidence package schema::

    {
        "question": "Will ETH reach $5000 by March 2025?",
        "outcome": 0,
        "confidence": 0.87,
        "sources": [
            {"url": "https://...", "title": "...", "snippet": "..."},
        ],
        "reasoning": "Free-form reasoning text ...",
        "timestamp": "2025-01-15T10:30:00Z"
    }
"""

from __future__ import annotations

import json
from typing import Any

import aiohttp
import structlog

logger = structlog.get_logger(__name__)

# Default Arweave gateway for reads.  Uploads go through a bundler service.
_DEFAULT_ARWEAVE_GATEWAY = "https://arweave.net"
_DEFAULT_BUNDLER_URL = "https://node2.bundlr.network"


class ArweaveClient:
    """Upload and download evidence packages to/from Arweave.

    Parameters
    ----------
    gateway_url:
        Arweave gateway for fetching data.
    bundler_url:
        Bundlr/Irys node URL for uploading data.
    wallet_path:
        Path to an Arweave JWK wallet file (required for uploads in
        production).  When ``None``, uploads use a stub that returns a
        deterministic placeholder CID -- suitable for local testing.
    """

    def __init__(
        self,
        gateway_url: str = _DEFAULT_ARWEAVE_GATEWAY,
        bundler_url: str = _DEFAULT_BUNDLER_URL,
        wallet_path: str | None = None,
    ) -> None:
        self._gateway_url = gateway_url.rstrip("/")
        self._bundler_url = bundler_url.rstrip("/")
        self._wallet_path = wallet_path

        logger.info(
            "arweave_client.initialized",
            gateway=self._gateway_url,
            bundler=self._bundler_url,
            has_wallet=wallet_path is not None,
        )

    # ------------------------------------------------------------------
    # Upload
    # ------------------------------------------------------------------

    async def upload_evidence(self, evidence_package: dict[str, Any]) -> str:
        """Upload an evidence package to Arweave and return the transaction ID (CID).

        In production this would sign the data with the Arweave wallet
        and post it to the bundler node.  The current implementation
        provides a working stub that deterministically hashes the payload.

        Parameters
        ----------
        evidence_package:
            Dictionary following the evidence package schema.

        Returns
        -------
        str
            Arweave transaction ID usable as ``evidenceCID``.
        """
        payload_bytes = json.dumps(evidence_package, sort_keys=True).encode()

        if self._wallet_path is not None:
            return await self._upload_via_bundler(payload_bytes)

        # Stub: produce a deterministic hash-based CID for local development.
        import hashlib

        cid = hashlib.sha256(payload_bytes).hexdigest()
        logger.warning(
            "arweave_client.upload_stub",
            cid=cid,
            size=len(payload_bytes),
            msg="No Arweave wallet configured; using SHA-256 stub CID.",
        )
        return cid

    async def _upload_via_bundler(self, payload_bytes: bytes) -> str:
        """Upload data to an Arweave bundler node.

        .. note::
            This is a placeholder implementation.  A full integration would:
            1. Load the JWK from ``self._wallet_path``.
            2. Create a signed DataItem (ANS-104).
            3. POST to the bundler.
            4. Return the transaction ID.

        For now we POST raw JSON and rely on the bundler to return a tx id.
        """
        url = f"{self._bundler_url}/tx"
        headers = {
            "Content-Type": "application/json",
        }

        try:
            async with aiohttp.ClientSession() as session:
                async with session.post(url, data=payload_bytes, headers=headers) as resp:
                    if resp.status in (200, 201):
                        data = await resp.json()
                        cid = data.get("id", data.get("txId", ""))
                        logger.info("arweave_client.uploaded", cid=cid)
                        return cid
                    else:
                        body = await resp.text()
                        logger.error(
                            "arweave_client.upload_failed",
                            status=resp.status,
                            body=body[:500],
                        )
                        raise RuntimeError(
                            f"Arweave upload failed with status {resp.status}: {body[:200]}"
                        )
        except aiohttp.ClientError as exc:
            logger.exception("arweave_client.upload_error")
            raise RuntimeError(f"Arweave upload error: {exc}") from exc

    # ------------------------------------------------------------------
    # Download
    # ------------------------------------------------------------------

    async def fetch_evidence(self, cid: str) -> dict[str, Any]:
        """Download and parse an evidence package from Arweave.

        Parameters
        ----------
        cid:
            Arweave transaction ID (or stub CID from :meth:`upload_evidence`).

        Returns
        -------
        dict
            Parsed evidence package JSON.

        Raises
        ------
        RuntimeError
            If the fetch fails or the response is not valid JSON.
        """
        # Stub CIDs are 64-char hex SHA-256 hashes (from upload_evidence stub mode).
        # Real Arweave TX IDs are 43-char base64url.  Don't hit the network for stubs.
        if len(cid) == 64 and all(c in "0123456789abcdef" for c in cid):
            logger.info("arweave_client.fetch_stub", cid=cid)
            return {
                "question": "(stub evidence — no Arweave wallet configured)",
                "outcome": 0,
                "confidence": 0.75,
                "sources": [],
                "reasoning": f"Stub evidence package for CID {cid}. "
                             "In production this would be fetched from Arweave.",
                "timestamp": "1970-01-01T00:00:00Z",
            }

        url = f"{self._gateway_url}/{cid}"
        logger.info("arweave_client.fetch.start", cid=cid, url=url)

        try:
            async with aiohttp.ClientSession() as session:
                async with session.get(url, timeout=aiohttp.ClientTimeout(total=30)) as resp:
                    if resp.status != 200:
                        body = await resp.text()
                        logger.error(
                            "arweave_client.fetch_failed",
                            cid=cid,
                            status=resp.status,
                            body=body[:500],
                        )
                        raise RuntimeError(
                            f"Arweave fetch failed for {cid}: HTTP {resp.status}"
                        )

                    data: dict[str, Any] = await resp.json()
                    logger.info("arweave_client.fetch.done", cid=cid)
                    return data
        except aiohttp.ClientError as exc:
            logger.exception("arweave_client.fetch_error", cid=cid)
            raise RuntimeError(f"Arweave fetch error for {cid}: {exc}") from exc
