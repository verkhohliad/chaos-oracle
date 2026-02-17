"""
Evidence package builder for ChaosOracle worker agents.

Constructs a structured evidence package that conforms to the schema expected
by verifier agents and archived on IPFS (sandbox) or Arweave (production).
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

import structlog

logger = structlog.get_logger(__name__)


class EvidenceBuilder:
    """Builds evidence packages from research results.

    Evidence packages are JSON-serialisable dictionaries uploaded to
    IPFS or Arweave.  Verifier agents later fetch these packages to
    audit the worker's reasoning and sources.

    Schema (v2.0.0)::

        {
            "version": "2.0.0",
            "question": str,
            "outcome": int,
            "confidence": float,
            "sources": [
                {"url": str, "title": str, "snippet": str},
                ...
            ],
            "reasoning": str,
            "reasoning_summary": str,
            "web_search_queries": [str, ...],
            "timestamp": str (ISO-8601)
        }
    """

    #: Current evidence package schema version.
    SCHEMA_VERSION: str = "2.0.0"

    def build(
        self,
        question: str,
        outcome: int,
        confidence: float,
        sources: list[dict[str, str]],
        reasoning: str,
        reasoning_summary: str = "",
        web_search_queries: list[str] | None = None,
    ) -> dict[str, Any]:
        """Assemble a complete evidence package.

        Parameters
        ----------
        question:
            The prediction market question being answered.
        outcome:
            0-based index of the chosen outcome option.
        confidence:
            Confidence score between 0.0 and 1.0.
        sources:
            List of source dictionaries with ``url``, ``title``, and
            ``snippet`` keys.
        reasoning:
            Free-form text explaining how the outcome was derived.
        reasoning_summary:
            Chain-of-thought reasoning summary from the model (optional).
        web_search_queries:
            List of web search queries the model executed (optional).

        Returns
        -------
        dict
            Evidence package ready for IPFS/Arweave upload.

        Raises
        ------
        ValueError
            If required fields are missing or out of range.
        """
        # Validate inputs
        if not question:
            raise ValueError("Evidence package requires a non-empty question.")
        if outcome < 0:
            raise ValueError(f"Outcome index must be >= 0, got {outcome}.")
        if not (0.0 <= confidence <= 1.0):
            raise ValueError(f"Confidence must be in [0, 1], got {confidence}.")

        # Normalise sources to ensure consistent key names
        normalised_sources = [
            {
                "url": s.get("url", ""),
                "title": s.get("title", ""),
                "snippet": s.get("snippet", ""),
            }
            for s in sources
        ]

        package: dict[str, Any] = {
            "version": self.SCHEMA_VERSION,
            "question": question,
            "outcome": outcome,
            "confidence": round(confidence, 4),
            "sources": normalised_sources,
            "reasoning": reasoning,
            "reasoning_summary": reasoning_summary,
            "web_search_queries": web_search_queries or [],
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }

        logger.info(
            "evidence_builder.built",
            question=question[:80],
            outcome=outcome,
            confidence=package["confidence"],
            source_count=len(normalised_sources),
            has_reasoning_summary=bool(reasoning_summary),
            search_query_count=len(package["web_search_queries"]),
        )
        return package
