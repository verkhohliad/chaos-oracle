"""
DKG (Directed Knowledge Graph) client for ChaosOracle agents.

Builds DKG nodes for worker evidence and computes thread_root / evidence_root
as required by StudioProxy.submitWork(). Based on the ChaosChain protocol spec.

§1.1: Graph Structure — DAG with nodes and causal edges
§1.2: Canonicalization — deterministic node hashing
§1.3: Verifiable Logical Clock (VLC) — causal ordering

thread_root = Merkle root over topologically-sorted canonical node hashes
evidence_root = Merkle root over sorted evidence artifact CIDs
"""

from __future__ import annotations

import time
from collections import deque
from dataclasses import dataclass, field
from typing import Any

import structlog
from eth_account import Account
from eth_utils import keccak

logger = structlog.get_logger(__name__)


@dataclass
class DKGNode:
    """A node in the Directed Knowledge Graph (§1.1)."""

    author: str  # Agent Ethereum address
    ts: int  # Unix timestamp (ms)
    xmtp_msg_id: str  # XMTP message ID (or synthetic ID)
    artifact_ids: list[str]  # Arweave/IPFS CIDs
    payload_hash: bytes  # keccak256 of content
    parents: list[str]  # Parent node IDs (causal links)
    sig: bytes = b""  # Signature of canonical hash
    canonical_hash: bytes | None = None  # Computed

    def compute_canonical_hash(self) -> bytes:
        """Canon(v) = keccak256(author || ts || xmtp_msg_id || payload_hash || parents[])"""
        sorted_parents = sorted(self.parents)
        canonical = (
            f"{self.author}|"
            f"{self.ts}|"
            f"{self.xmtp_msg_id}|"
            f"{self.payload_hash.hex()}|"
            f"{'|'.join(sorted_parents)}"
        )
        self.canonical_hash = keccak(text=canonical)
        return self.canonical_hash


class DKGBuilder:
    """Builds a DKG for a single studio work session.

    Workers create nodes after research, linking to prior work. The builder
    computes thread_root (Merkle over topo-sorted canonical hashes) and
    evidence_root (Merkle over sorted artifact CIDs).

    Usage::

        builder = DKGBuilder(wallet_address="0x...", private_key="0x...")
        node_id = builder.add_work_node(
            evidence_content=evidence_bytes,
            artifact_ids=["ar://abc123"],
        )
        thread_root = builder.compute_thread_root()
        evidence_root = builder.compute_evidence_root()
    """

    def __init__(self, wallet_address: str, private_key: str) -> None:
        self.wallet_address = wallet_address.lower()
        self._private_key = private_key
        self._account = Account.from_key(private_key)
        self.nodes: dict[str, DKGNode] = {}
        self.roots: set[str] = set()
        self._edges: dict[str, list[str]] = {}

    def add_work_node(
        self,
        evidence_content: bytes,
        artifact_ids: list[str] | None = None,
        parents: list[str] | None = None,
        xmtp_msg_id: str | None = None,
    ) -> str:
        """Create and add a DKG node for a work submission.

        Parameters
        ----------
        evidence_content:
            Raw evidence bytes (used to compute payload_hash).
        artifact_ids:
            CIDs of stored artifacts (Arweave tx IDs, IPFS CIDs).
        parents:
            Parent node IDs for causal links (empty for root nodes).
        xmtp_msg_id:
            XMTP message ID. Auto-generated if not provided.

        Returns
        -------
        str
            The node ID (xmtp_msg_id).
        """
        ts = int(time.time() * 1000)
        msg_id = xmtp_msg_id or f"work_{self.wallet_address}_{ts}"
        parents = parents or []
        artifact_ids = artifact_ids or []

        payload_hash = keccak(evidence_content)

        node = DKGNode(
            author=self.wallet_address,
            ts=ts,
            xmtp_msg_id=msg_id,
            artifact_ids=artifact_ids,
            payload_hash=payload_hash,
            parents=parents,
        )

        # Compute canonical hash and sign it
        canon_hash = node.compute_canonical_hash()
        signed = self._account.unsafe_sign_hash(canon_hash)
        node.sig = signed.signature

        # Track in graph
        self.nodes[msg_id] = node
        if not parents:
            self.roots.add(msg_id)
        for parent_id in parents:
            self._edges.setdefault(parent_id, []).append(msg_id)

        logger.info(
            "dkg.node_added",
            node_id=msg_id,
            author=self.wallet_address,
            parents=parents,
            artifact_count=len(artifact_ids),
        )
        return msg_id

    def compute_thread_root(self) -> bytes:
        """Compute thread_root: Merkle root over topo-sorted canonical hashes.

        Returns 32-byte thread root for StudioProxy.submitWork().
        """
        sorted_ids = self._topological_sort()
        hashes = []
        for nid in sorted_ids:
            node = self.nodes[nid]
            if node.canonical_hash is None:
                node.compute_canonical_hash()
            hashes.append(node.canonical_hash)

        root = _merkle_root(hashes)
        logger.debug("dkg.thread_root", root=root.hex(), node_count=len(hashes))
        return root

    def compute_evidence_root(self) -> bytes:
        """Compute evidence_root: Merkle root over sorted artifact CIDs.

        Returns 32-byte evidence root for StudioProxy.submitWork().
        """
        all_cids: list[str] = []
        for node in self.nodes.values():
            all_cids.extend(node.artifact_ids)

        sorted_cids = sorted(set(all_cids))
        hashes = [keccak(text=cid) for cid in sorted_cids]
        root = _merkle_root(hashes)
        logger.debug("dkg.evidence_root", root=root.hex(), cid_count=len(sorted_cids))
        return root

    def to_dict(self) -> dict[str, Any]:
        """Serialize the DKG for XMTP transport or logging."""
        return {
            "nodes": {
                nid: {
                    "author": n.author,
                    "ts": n.ts,
                    "xmtp_msg_id": n.xmtp_msg_id,
                    "artifact_ids": n.artifact_ids,
                    "payload_hash": n.payload_hash.hex(),
                    "parents": n.parents,
                    "sig": n.sig.hex() if n.sig else "",
                    "canonical_hash": n.canonical_hash.hex() if n.canonical_hash else "",
                }
                for nid, n in self.nodes.items()
            },
            "roots": list(self.roots),
        }

    def _topological_sort(self) -> list[str]:
        """Kahn's algorithm — parents before children."""
        in_degree = {nid: len(n.parents) for nid, n in self.nodes.items()}
        queue = deque(sorted(self.roots))  # sorted for determinism
        result: list[str] = []

        while queue:
            nid = queue.popleft()
            result.append(nid)
            for child_id in self._edges.get(nid, []):
                in_degree[child_id] -= 1
                if in_degree[child_id] == 0:
                    queue.append(child_id)

        return result


def _merkle_root(hashes: list[bytes]) -> bytes:
    """Compute a binary Merkle root from a list of 32-byte hashes."""
    if not hashes:
        return bytes(32)
    if len(hashes) == 1:
        return hashes[0]

    level = list(hashes)
    while len(level) > 1:
        next_level: list[bytes] = []
        for i in range(0, len(level), 2):
            if i + 1 < len(level):
                next_level.append(keccak(level[i] + level[i + 1]))
            else:
                next_level.append(keccak(level[i] + level[i]))
        level = next_level

    return level[0]
