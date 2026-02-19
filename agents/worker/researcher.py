"""
Market question researcher that uses the OpenAI Responses API with
**web search** and **reasoning** to determine the most likely outcome
for a prediction market question.

Uses ``client.responses.create()`` with:
- ``tools=[{"type": "web_search"}]`` for real-time web research
- ``reasoning={"effort": ..., "summary": "detailed"}`` for chain-of-thought
  (when using a reasoning model such as o4-mini or o3)

The model autonomously decides what to search and how many queries to run.
The enhanced prompt requests structured output including key sources with
relevance context, search queries used, and contrary evidence analysis.
"""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass, field
from typing import Any

import structlog

from shared.openai_client import (
    ParsedResponse,
    create_async_client,
    is_reasoning_model,
    stream_responses_with_logging,
)

logger = structlog.get_logger(__name__)


@dataclass
class ResearchResult:
    """Structured result from a research run."""

    outcome_index: int
    confidence: float
    sources: list[dict[str, str]]
    reasoning: str
    reasoning_summary: str = ""
    web_search_queries: list[str] = field(default_factory=list)


class Researcher:
    """Researches prediction market questions to determine the best outcome.

    Parameters
    ----------
    openai_api_key:
        API key for the OpenAI Responses API.
    openai_model:
        Model identifier (e.g. ``o4-mini``, ``o3``, ``gpt-4o``).
    reasoning_effort:
        Reasoning effort level: ``"low"``, ``"medium"``, or ``"high"``.
        Only used with reasoning models (o-series).
    """

    def __init__(
        self,
        openai_api_key: str = "",
        openai_model: str = "gpt-5-2025-08-07",
        reasoning_effort: str = "high",
    ) -> None:
        self._api_key = openai_api_key
        self._model = openai_model
        self._reasoning_effort = reasoning_effort
        self._client = create_async_client(openai_api_key) if openai_api_key else None

        logger.info(
            "researcher.initialized",
            has_api_key=bool(openai_api_key),
            model=openai_model,
            reasoning_effort=reasoning_effort,
            is_reasoning_model=is_reasoning_model(openai_model),
        )

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    async def research(
        self,
        question: str,
        options: list[str],
    ) -> ResearchResult:
        """Research a market question and return the predicted outcome.

        Parameters
        ----------
        question:
            The prediction market question text.
        options:
            List of possible outcome strings (0-indexed).

        Returns
        -------
        ResearchResult
            Contains the chosen outcome index, confidence score,
            supporting sources, reasoning, and reasoning summary.
        """
        logger.info(
            "researcher.research.start",
            question=question[:120],
            option_count=len(options),
        )

        # Allow forcing a specific outcome via env var (for local E2E testing)
        forced = os.environ.get("WORKER_FORCED_OUTCOME")
        if forced is not None:
            try:
                forced_idx = int(forced)
                if not (0 <= forced_idx < len(options)):
                    raise ValueError(
                        f"WORKER_FORCED_OUTCOME={forced_idx} out of range "
                        f"[0, {len(options)})"
                    )
                logger.info(
                    "researcher.forced_outcome",
                    outcome_index=forced_idx,
                    env_var="WORKER_FORCED_OUTCOME",
                )
                return ResearchResult(
                    outcome_index=forced_idx,
                    confidence=0.99,
                    sources=[
                        {
                            "url": "env://WORKER_FORCED_OUTCOME",
                            "title": "Forced outcome",
                            "snippet": f"Forced to outcome {forced_idx} via WORKER_FORCED_OUTCOME env var",
                        },
                    ],
                    reasoning=f"Forced outcome={forced_idx} via WORKER_FORCED_OUTCOME env var (local testing).",
                )
            except (ValueError, TypeError) as exc:
                logger.warning(
                    "researcher.invalid_forced_outcome",
                    value=forced,
                    error=str(exc),
                )
                # Fall through to normal research

        # --- LLM + Web Search via Responses API ---
        if self._client:
            analysis = await self._call_responses_api(question, options)
        else:
            # Fallback: no API key configured
            logger.warning(
                "researcher.no_api_key",
                msg="No OpenAI API key; returning placeholder.",
            )
            analysis = {
                "outcome_index": 0,
                "confidence": 0.5,
                "reasoning": (
                    f"Placeholder analysis for: '{question}'. "
                    f"Options: {options}. "
                    f"No LLM API key configured; defaulting to option 0."
                ),
                "sources": [],
                "reasoning_summary": "",
                "web_search_queries": [],
            }

        result = ResearchResult(
            outcome_index=analysis["outcome_index"],
            confidence=analysis["confidence"],
            sources=analysis.get("sources", []),
            reasoning=analysis["reasoning"],
            reasoning_summary=analysis.get("reasoning_summary", ""),
            web_search_queries=analysis.get("web_search_queries", []),
        )

        logger.info(
            "researcher.research.done",
            outcome_index=result.outcome_index,
            outcome_label=(
                options[result.outcome_index]
                if result.outcome_index < len(options)
                else "?"
            ),
            confidence=result.confidence,
            source_count=len(result.sources),
            search_queries=result.web_search_queries,
        )
        return result

    # ------------------------------------------------------------------
    # Responses API call (web search + reasoning)
    # ------------------------------------------------------------------

    async def _call_responses_api(
        self,
        question: str,
        options: list[str],
    ) -> dict[str, Any]:
        """Call the OpenAI Responses API with web search and reasoning.

        A single API call that combines:
        - **Web search**: the model autonomously searches for relevant info
        - **Reasoning**: chain-of-thought with accessible summary
        - **Structured output**: JSON with outcome, confidence, reasoning,
          key sources, search queries, and contrary evidence
        """
        options_text = "\n".join(f"  {i}: {opt}" for i, opt in enumerate(options))

        prompt = (
            "You are an expert prediction market research analyst. Your task "
            "is to determine the most likely outcome for the following market "
            "question using thorough web research.\n\n"
            "INSTRUCTIONS:\n"
            "1. Search the web thoroughly for the most recent and relevant "
            "information about this topic.\n"
            "2. Use multiple search queries to cross-reference facts from "
            "different angles (direct query, news, data sources, contrary "
            "evidence).\n"
            "3. Prioritize authoritative, primary sources: official "
            "announcements, reputable news outlets, government data, "
            "academic publications.\n"
            "4. Look for the most recent information — prediction markets "
            "are time-sensitive.\n"
            "5. Search for contrary evidence to test your hypothesis.\n"
            "6. After gathering evidence, select the most likely outcome.\n"
            "7. Be concise and factual in your reasoning. Reference specific "
            "sources and data points. No filler, no hedging language.\n\n"
            f"QUESTION: {question}\n\n"
            f"OPTIONS:\n{options_text}\n\n"
            "Respond with ONLY valid JSON matching this exact schema:\n"
            "{\n"
            '  "outcome_index": <int, 0-based index of the chosen option>,\n'
            '  "confidence": <float 0.0-1.0>,\n'
            '  "reasoning": "<comprehensive factual analysis supporting your '
            'choice, referencing specific sources and data points>",\n'
            '  "key_sources": [\n'
            '    {"url": "<url>", "title": "<source title>", '
            '"relevance": "<how this source supports the conclusion>"}\n'
            "  ],\n"
            '  "search_queries_used": ["<query1>", "<query2>", ...],\n'
            '  "contrary_evidence": "<summary of any evidence against the '
            'chosen outcome, or empty string if none found>"\n'
            "}"
        )

        kwargs: dict[str, Any] = {
            "model": self._model,
            "input": prompt,
            "tools": [{"type": "web_search"}],
        }

        if is_reasoning_model(self._model):
            kwargs["reasoning"] = {
                "effort": self._reasoning_effort,
                "summary": "detailed",
            }

        try:
            parsed: ParsedResponse = await stream_responses_with_logging(
                self._client, caller="researcher", **kwargs,
            )

            # Attempt to parse structured JSON from the response text
            try:
                data = json.loads(parsed.text)
            except json.JSONDecodeError:
                data = self._extract_json_from_text(parsed.text)

            outcome_index = int(data.get("outcome_index", 0))
            confidence = float(data.get("confidence", 0.5))
            reasoning_text = str(data.get("reasoning", ""))

            # Append contrary evidence to reasoning if present
            contrary = data.get("contrary_evidence", "")
            if contrary:
                reasoning_text += f"\n\nContrary evidence considered: {contrary}"

            # Clamp to valid ranges
            outcome_index = max(0, min(outcome_index, len(options) - 1))
            confidence = max(0.0, min(confidence, 1.0))

            # Build sources: merge web_citations (API metadata — actual URLs
            # visited) + key_sources (model-reported, with relevance context)
            sources: list[dict[str, str]] = []
            seen_urls: set[str] = set()

            # Primary: web citations from the Responses API
            for c in parsed.web_citations:
                url = c.get("url", "")
                if url and url not in seen_urls:
                    seen_urls.add(url)
                    sources.append({
                        "url": url,
                        "title": c.get("title", ""),
                        "snippet": "",
                    })

            # Secondary: model-reported key sources (include relevance)
            for ks in data.get("key_sources", []):
                url = ks.get("url", "")
                if url and url not in seen_urls:
                    seen_urls.add(url)
                    sources.append({
                        "url": url,
                        "title": ks.get("title", ""),
                        "snippet": ks.get("relevance", ""),
                    })

            # Merge search queries from API metadata + model self-report
            search_queries = list(parsed.web_search_queries)
            for q in data.get("search_queries_used", []):
                if q and q not in search_queries:
                    search_queries.append(q)

            reasoning_summary = "\n".join(parsed.reasoning_summary)

            logger.info(
                "researcher.responses_api.success",
                outcome_index=outcome_index,
                confidence=confidence,
                source_count=len(sources),
                search_query_count=len(search_queries),
                has_contrary_evidence=bool(contrary),
            )

            return {
                "outcome_index": outcome_index,
                "confidence": confidence,
                "reasoning": reasoning_text,
                "sources": sources,
                "reasoning_summary": reasoning_summary,
                "web_search_queries": search_queries,
            }

        except Exception:
            logger.exception("researcher.responses_api.call_failed")
            return {
                "outcome_index": 0,
                "confidence": 0.3,
                "reasoning": f"API call failed; fallback to option 0 for '{question}'.",
                "sources": [],
                "reasoning_summary": "",
                "web_search_queries": [],
            }

    # ------------------------------------------------------------------
    # JSON extraction helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _find_json_objects(text: str) -> list[dict[str, Any]]:
        """Find all valid JSON objects in text using balanced-brace scanning.

        Handles nested objects and arrays (e.g. ``key_sources`` array),
        unlike simple ``\\{[^{}]*\\}`` regex.
        """
        results: list[dict[str, Any]] = []
        i = 0
        while i < len(text):
            if text[i] == "{":
                depth = 0
                start = i
                in_string = False
                escape_next = False
                for j in range(i, len(text)):
                    c = text[j]
                    if escape_next:
                        escape_next = False
                        continue
                    if c == "\\":
                        escape_next = True
                        continue
                    if c == '"' and not escape_next:
                        in_string = not in_string
                    if not in_string:
                        if c == "{":
                            depth += 1
                        elif c == "}":
                            depth -= 1
                        if depth == 0:
                            candidate = text[start : j + 1]
                            try:
                                obj = json.loads(candidate)
                                if isinstance(obj, dict):
                                    results.append(obj)
                            except json.JSONDecodeError:
                                pass
                            i = j + 1
                            break
                else:
                    i += 1
            else:
                i += 1
        return results

    @staticmethod
    def _extract_json_from_text(text: str) -> dict[str, Any]:
        """Extract JSON from text that may contain markdown fences or prose.

        Tries in order:
        1. JSON inside ```json ... ``` fences (balanced-brace aware)
        2. All balanced JSON objects — prefer one with ``outcome_index``
        3. Fallback defaults
        """
        # Try markdown-fenced JSON (balanced-brace scan on fenced content)
        fence_match = re.search(r"```(?:json)?\s*(\{.+)\s*```", text, re.DOTALL)
        if fence_match:
            fenced = fence_match.group(1)
            objs = Researcher._find_json_objects(fenced)
            if objs:
                # Prefer object with outcome_index
                for obj in objs:
                    if "outcome_index" in obj:
                        return obj
                return objs[0]

        # Scan full text for JSON objects
        objs = Researcher._find_json_objects(text)
        if objs:
            # Prefer object with outcome_index key
            for obj in objs:
                if "outcome_index" in obj:
                    return obj
            # Fall back to the largest object
            return max(objs, key=lambda o: len(o))

        logger.warning(
            "researcher.json_extraction_failed",
            raw_text=text[:300],
        )
        return {"outcome_index": 0, "confidence": 0.3, "reasoning": text[:500]}
