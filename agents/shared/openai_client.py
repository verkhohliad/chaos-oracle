"""
Shared OpenAI Responses API client for ChaosOracle agents.

Provides a thin wrapper around the OpenAI Python SDK that:
- Creates an ``AsyncOpenAI`` client with appropriate timeouts
- Detects whether a model supports reasoning (o3, o4-mini, etc.)
- Parses Responses API output items into a structured ``ParsedResponse``

Both the worker ``Researcher`` and verifier ``Auditor`` import from here
to avoid duplicating response-parsing logic.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

import structlog
from openai import AsyncOpenAI

logger = structlog.get_logger(__name__)

# ── Reasoning model detection ──────────────────────────────────────────

# Prefixes for model families that support the `reasoning` parameter.
_REASONING_PREFIXES = ("o1", "o3", "o4")


def is_reasoning_model(model: str) -> bool:
    """Return *True* if *model* belongs to a reasoning family (o1/o3/o4).

    Reasoning models support the ``reasoning`` parameter with
    ``effort`` and ``summary`` controls.  Non-reasoning models
    (gpt-4o, gpt-4.1, gpt-5, etc.) should omit this parameter.
    """
    return any(model.startswith(prefix) for prefix in _REASONING_PREFIXES)


# ── Client factory ─────────────────────────────────────────────────────


def create_async_client(api_key: str, timeout: float = 120.0) -> AsyncOpenAI:
    """Create an :class:`AsyncOpenAI` client with a generous timeout.

    Reasoning models combined with web search can take 30-90 seconds,
    so the default timeout is 120 s (up from the SDK default of 60 s).
    """
    return AsyncOpenAI(api_key=api_key, timeout=timeout)


# ── Response parsing ───────────────────────────────────────────────────


@dataclass
class ParsedResponse:
    """Structured result extracted from a Responses API response.

    Attributes
    ----------
    text:
        The concatenated message text from all ``output_text`` blocks.
    reasoning_summary:
        Reasoning summary segments (from ``type="reasoning"`` items).
    web_citations:
        URL citations from ``url_citation`` annotations.  Each entry has
        ``url`` and ``title`` keys.
    web_search_queries:
        The search queries the model executed via the ``web_search`` tool.
    """

    text: str = ""
    reasoning_summary: list[str] = field(default_factory=list)
    web_citations: list[dict[str, str]] = field(default_factory=list)
    web_search_queries: list[str] = field(default_factory=list)


def parse_response_output(response: Any) -> ParsedResponse:
    """Parse a Responses API response into structured components.

    Iterates over ``response.output`` items and extracts:

    * ``type="reasoning"`` → ``.summary[].text`` segments
    * ``type="web_search_call"`` → the search query string
    * ``type="message"`` → text content and ``url_citation`` annotations

    Parameters
    ----------
    response:
        The response object returned by ``client.responses.create()``.

    Returns
    -------
    ParsedResponse
        A structured view of the response content.
    """
    result = ParsedResponse()

    for item in response.output:
        item_type = getattr(item, "type", None)

        if item_type == "reasoning":
            # Reasoning items have a .summary list of objects with .text
            summary = getattr(item, "summary", None)
            if summary:
                for part in summary:
                    text = getattr(part, "text", None)
                    if text:
                        result.reasoning_summary.append(text)

        elif item_type == "web_search_call":
            query = getattr(item, "query", None)
            if query:
                result.web_search_queries.append(query)

        elif item_type == "message":
            content_list = getattr(item, "content", [])
            for block in content_list:
                block_type = getattr(block, "type", None)
                if block_type == "output_text":
                    result.text += getattr(block, "text", "")
                    # Extract url_citation annotations
                    annotations = getattr(block, "annotations", [])
                    for ann in annotations:
                        if getattr(ann, "type", None) == "url_citation":
                            citation = {
                                "url": getattr(ann, "url", ""),
                                "title": getattr(ann, "title", ""),
                            }
                            # Deduplicate by URL
                            if citation["url"] and citation not in result.web_citations:
                                result.web_citations.append(citation)

    logger.debug(
        "openai_client.parsed_response",
        text_len=len(result.text),
        reasoning_parts=len(result.reasoning_summary),
        citations=len(result.web_citations),
        searches=len(result.web_search_queries),
    )
    return result
