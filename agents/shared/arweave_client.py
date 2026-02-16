"""
Arweave / IPFS evidence upload & download client for ChaosOracle agents.

Evidence packages are JSON objects conforming to the schema below and are
stored on Arweave (production) or IPFS (sandbox) for permanent, verifiable
access.  The returned CID (content identifier) is submitted on-chain as
``evidenceCID``.

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

Storage backends (priority order):
1. **IPFS** -- when ``ipfs_api_url`` is set (sandbox: ``http://ipfs:5001``)
2. **Arweave Bundler** -- when ``wallet_path`` is set (production)
3. **SHA-256 Stub** -- deterministic hash, no storage (unit tests only)
"""

from __future__ import annotations

import json
import os
from typing import Any

import aiohttp
import structlog

logger = structlog.get_logger(__name__)

# Default Arweave gateway for reads.  Uploads go through a bundler service.
_DEFAULT_ARWEAVE_GATEWAY = "https://arweave.net"
_DEFAULT_BUNDLER_URL = "https://node2.bundlr.network"


class ArweaveClient:
    """Upload and download evidence packages to/from Arweave or IPFS.

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
    ipfs_api_url:
        IPFS API URL for uploading/downloading evidence (e.g.
        ``http://ipfs:5001``).  Takes priority over both Arweave and stub.
        Set via ``IPFS_API_URL`` env var in the sandbox.
    """

    def __init__(
        self,
        gateway_url: str = _DEFAULT_ARWEAVE_GATEWAY,
        bundler_url: str = _DEFAULT_BUNDLER_URL,
        wallet_path: str | None = None,
        ipfs_api_url: str | None = None,
    ) -> None:
        self._gateway_url = gateway_url.rstrip("/")
        self._bundler_url = bundler_url.rstrip("/")
        self._wallet_path = wallet_path
        self._ipfs_api_url = (ipfs_api_url or os.environ.get("IPFS_API_URL") or "").rstrip("/") or None

        # Derive IPFS gateway URL from API URL (port 5001 → 8080)
        self._ipfs_gateway_url: str | None = None
        if self._ipfs_api_url:
            self._ipfs_gateway_url = self._ipfs_api_url.replace(":5001", ":8080")

        logger.info(
            "arweave_client.initialized",
            gateway=self._gateway_url,
            bundler=self._bundler_url,
            has_wallet=wallet_path is not None,
            ipfs_api=self._ipfs_api_url,
        )

    # ------------------------------------------------------------------
    # Upload
    # ------------------------------------------------------------------

    async def upload_evidence(self, evidence_package: dict[str, Any]) -> str:
        """Upload an evidence package and return the content identifier (CID).

        Uses IPFS if configured, then Arweave bundler, then falls back to
        a deterministic SHA-256 stub.

        Parameters
        ----------
        evidence_package:
            Dictionary following the evidence package schema.

        Returns
        -------
        str
            Content identifier (IPFS CID, Arweave TX ID, or stub hash).
        """
        payload_bytes = json.dumps(evidence_package, sort_keys=True).encode()

        # Priority 1: IPFS (sandbox)
        if self._ipfs_api_url:
            return await self._upload_via_ipfs(payload_bytes)

        # Priority 2: Arweave bundler (production)
        if self._wallet_path is not None:
            return await self._upload_via_bundler(payload_bytes)

        # Priority 3: Stub CID (unit tests)
        import hashlib

        cid = hashlib.sha256(payload_bytes).hexdigest()
        logger.warning(
            "arweave_client.upload_stub",
            cid=cid,
            size=len(payload_bytes),
            msg="No IPFS or Arweave wallet configured; using SHA-256 stub CID.",
        )
        return cid

    async def _upload_via_ipfs(self, payload_bytes: bytes) -> str:
        """Upload data to an IPFS node via the HTTP API.

        Calls ``POST /api/v0/add`` which returns a JSON object with a
        ``Hash`` field containing the CID.
        """
        url = f"{self._ipfs_api_url}/api/v0/add"

        try:
            async with aiohttp.ClientSession() as session:
                data = aiohttp.FormData()
                data.add_field(
                    "file",
                    payload_bytes,
                    filename="evidence.json",
                    content_type="application/json",
                )
                async with session.post(url, data=data, timeout=aiohttp.ClientTimeout(total=30)) as resp:
                    if resp.status in (200, 201):
                        result = await resp.json()
                        cid = result.get("Hash", "")
                        logger.info("arweave_client.ipfs_uploaded", cid=cid, size=len(payload_bytes))
                        return cid
                    else:
                        body = await resp.text()
                        logger.error(
                            "arweave_client.ipfs_upload_failed",
                            status=resp.status,
                            body=body[:500],
                        )
                        raise RuntimeError(
                            f"IPFS upload failed with status {resp.status}: {body[:200]}"
                        )
        except aiohttp.ClientError as exc:
            logger.exception("arweave_client.ipfs_upload_error")
            raise RuntimeError(f"IPFS upload error: {exc}") from exc

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
        """Download and parse an evidence package from IPFS or Arweave.

        Parameters
        ----------
        cid:
            Content identifier — IPFS CID (starts with ``Qm`` or ``bafy``),
            Arweave TX ID (43-char base64url), or stub CID (64-char hex).

        Returns
        -------
        dict
            Parsed evidence package JSON.

        Raises
        ------
        RuntimeError
            If the fetch fails or the response is not valid JSON.
        """
        # IPFS CIDs (CIDv0 starts with "Qm", CIDv1 starts with "bafy")
        if cid.startswith("Qm") or cid.startswith("bafy"):
            return await self._fetch_from_ipfs(cid)

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

        # Arweave fetch
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

    async def _fetch_from_ipfs(self, cid: str) -> dict[str, Any]:
        """Fetch evidence from an IPFS gateway.

        Tries the configured IPFS gateway (derived from ``ipfs_api_url``)
        first, then falls back to the public ``ipfs.io`` gateway.
        """
        gateways = []
        if self._ipfs_gateway_url:
            gateways.append(self._ipfs_gateway_url)
        gateways.append("https://ipfs.io")

        last_error: Exception | None = None
        for gateway in gateways:
            url = f"{gateway}/ipfs/{cid}"
            logger.info("arweave_client.ipfs_fetch.start", cid=cid, url=url)

            try:
                async with aiohttp.ClientSession() as session:
                    async with session.get(url, timeout=aiohttp.ClientTimeout(total=30)) as resp:
                        if resp.status == 200:
                            data: dict[str, Any] = await resp.json()
                            logger.info("arweave_client.ipfs_fetch.done", cid=cid)
                            return data
                        else:
                            body = await resp.text()
                            logger.warning(
                                "arweave_client.ipfs_fetch_failed",
                                cid=cid,
                                gateway=gateway,
                                status=resp.status,
                                body=body[:200],
                            )
            except Exception as exc:
                last_error = exc
                logger.warning(
                    "arweave_client.ipfs_fetch_error",
                    cid=cid,
                    gateway=gateway,
                    error=str(exc),
                )

        raise RuntimeError(
            f"IPFS fetch failed for {cid} from all gateways: {last_error}"
        )
