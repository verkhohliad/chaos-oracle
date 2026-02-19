"""
Shared OpenAI Responses API client for ChaosOracle agents.

Provides a thin wrapper around the OpenAI Python SDK that:
- Creates an ``AsyncOpenAI`` client with appropriate timeouts
- Detects whether a model supports reasoning (o3, o4-mini, etc.)
- Parses Responses API output items into a structured ``ParsedResponse``
- Streams Responses API calls with real-time logging of search queries,
  reasoning progress, and text output

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


# ── Streaming API call with real-time logging ─────────────────────────


async def stream_responses_with_logging(
    client: AsyncOpenAI,
    *,
    caller: str = "agent",
    **kwargs: Any,
) -> ParsedResponse:
    """Call ``client.responses.create(stream=True)`` and log events in real-time.

    Streams the Responses API call, logging each event as it arrives:
    - Web search queries as they are issued
    - Reasoning summary chunks as they are produced
    - Text output progress (periodically, not per-token)
    - Final summary with totals

    Parameters
    ----------
    client:
        An ``AsyncOpenAI`` client instance.
    caller:
        Label for log messages (e.g. ``"researcher"`` or ``"auditor"``).
    **kwargs:
        Arguments forwarded to ``client.responses.create()``.
        ``stream=True`` is set automatically.

    Returns
    -------
    ParsedResponse
        The same structured response as ``parse_response_output()``.
    """
    kwargs["stream"] = True

    result = ParsedResponse()

    # Accumulators for streaming state
    text_chunks: list[str] = []
    text_len = 0
    search_count = 0
    reasoning_parts: list[str] = []
    current_reasoning = ""

    stream = await client.responses.create(**kwargs)

    async for event in stream:
        event_type = getattr(event, "type", "")

        # ── Web search events ──
        if event_type == "response.web_search_call.searching":
            search_count += 1
            query = ""
            # The query is available on the item, not the event directly
            item = getattr(event, "item", None)
            if item:
                query = getattr(item, "query", "")
            logger.info(
                f"{caller}.stream.web_search",
                search_number=search_count,
                query=query or "(searching...)",
            )

        elif event_type == "response.web_search_call.completed":
            logger.info(
                f"{caller}.stream.web_search_done",
                search_number=search_count,
            )

        # ── Reasoning events ──
        elif event_type == "response.reasoning.delta":
            delta = getattr(event, "delta", None)
            if delta:
                text = getattr(delta, "text", "") or ""
                current_reasoning += text

        elif event_type == "response.reasoning.done":
            if current_reasoning:
                # Log a summary of reasoning (truncated)
                preview = current_reasoning[:200]
                if len(current_reasoning) > 200:
                    preview += "..."
                logger.info(
                    f"{caller}.stream.reasoning",
                    reasoning_preview=preview,
                    reasoning_length=len(current_reasoning),
                )
                reasoning_parts.append(current_reasoning)
                current_reasoning = ""

        elif event_type == "response.reasoning_summary_text.delta":
            # Some models emit reasoning summary as separate events
            delta = getattr(event, "delta", "")
            if delta:
                current_reasoning += delta

        elif event_type == "response.reasoning_summary_text.done":
            if current_reasoning:
                reasoning_parts.append(current_reasoning)
                current_reasoning = ""

        # ── Output text events ──
        elif event_type == "response.output_text.delta":
            delta = getattr(event, "delta", "")
            if delta:
                text_chunks.append(delta)
                text_len += len(delta)

        elif event_type == "response.output_text.done":
            text = getattr(event, "text", "")
            if text:
                # Use the final complete text, not accumulated chunks
                result.text = text
            else:
                result.text = "".join(text_chunks)
            logger.info(
                f"{caller}.stream.output_text_done",
                text_length=len(result.text),
            )

        # ── Output item lifecycle events ──
        elif event_type == "response.output_item.done":
            item = getattr(event, "item", None)
            if item:
                item_type = getattr(item, "type", None)

                if item_type == "web_search_call":
                    query = getattr(item, "query", "")
                    if query and query not in result.web_search_queries:
                        result.web_search_queries.append(query)

                elif item_type == "reasoning":
                    summary = getattr(item, "summary", None)
                    if summary:
                        for part in summary:
                            text = getattr(part, "text", None)
                            if text:
                                result.reasoning_summary.append(text)

        # ── Content part done — extract annotations ──
        elif event_type == "response.content_part.done":
            part = getattr(event, "part", None)
            if part and getattr(part, "type", None) == "output_text":
                annotations = getattr(part, "annotations", [])
                for ann in annotations:
                    if getattr(ann, "type", None) == "url_citation":
                        citation = {
                            "url": getattr(ann, "url", ""),
                            "title": getattr(ann, "title", ""),
                        }
                        if citation["url"] and citation not in result.web_citations:
                            result.web_citations.append(citation)

        # ── Completed ──
        elif event_type == "response.completed":
            # Final response object is available — parse it for anything
            # we might have missed during streaming
            response = getattr(event, "response", None)
            if response:
                final_parsed = parse_response_output(response)
                # Merge: prefer streaming text if we got it, else use final
                if not result.text and final_parsed.text:
                    result.text = final_parsed.text
                # Merge citations
                for c in final_parsed.web_citations:
                    if c not in result.web_citations:
                        result.web_citations.append(c)
                # Merge search queries
                for q in final_parsed.web_search_queries:
                    if q not in result.web_search_queries:
                        result.web_search_queries.append(q)
                # Merge reasoning summary
                if not result.reasoning_summary and final_parsed.reasoning_summary:
                    result.reasoning_summary = final_parsed.reasoning_summary

    # If text was never set via .done event, assemble from chunks
    if not result.text and text_chunks:
        result.text = "".join(text_chunks)

    # Add any reasoning parts we captured via deltas
    if reasoning_parts and not result.reasoning_summary:
        result.reasoning_summary = reasoning_parts

    logger.info(
        f"{caller}.stream.complete",
        text_length=len(result.text),
        search_queries=len(result.web_search_queries),
        citations=len(result.web_citations),
        reasoning_parts=len(result.reasoning_summary),
    )

    return result
