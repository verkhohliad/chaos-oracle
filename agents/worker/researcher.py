"""
Market question researcher that uses the OpenAI Responses API with
**web search** and **reasoning** to determine the most likely outcome
for a prediction market question.

Uses ``client.responses.create()`` with:
- ``tools=[{"type": "web_search"}]`` for real-time web research
- ``reasoning={"effort": ..., "summary": "detailed"}`` for chain-of-thought
  (when using a reasoning model such as o4-mini or o3)

The model autonomously decides what to search and how many queries to run.
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
    parse_response_output,
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
        - **Structured output**: JSON with outcome, confidence, reasoning
        """
        options_text = "\n".join(f"  {i}: {opt}" for i, opt in enumerate(options))

        prompt = (
            "You are a prediction market research analyst. Your task is to "
            "determine the most likely outcome for the following market question.\n\n"
            "INSTRUCTIONS:\n"
            "1. Search the web thoroughly for the most recent and relevant "
            "information about this topic.\n"
            "2. Use multiple search queries to cross-reference facts from "
            "different angles.\n"
            "3. Prioritize authoritative, primary sources (official "
            "announcements, reputable news outlets, government data, "
            "academic publications).\n"
            "4. After gathering evidence, select the most likely outcome.\n"
            "5. Be concise and factual in your reasoning. No filler, no "
            "hedging language.\n\n"
            f"QUESTION: {question}\n\n"
            f"OPTIONS:\n{options_text}\n\n"
            "Respond with ONLY valid JSON matching this exact schema:\n"
            '{"outcome_index": <int>, "confidence": <float 0.0-1.0>, '
            '"reasoning": "<concise factual analysis>"}'
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
            response = await self._client.responses.create(**kwargs)  # type: ignore[union-attr]
            parsed: ParsedResponse = parse_response_output(response)

            # Attempt to parse structured JSON from the response text
            try:
                data = json.loads(parsed.text)
            except json.JSONDecodeError:
                data = self._extract_json_from_text(parsed.text)

            outcome_index = int(data.get("outcome_index", 0))
            confidence = float(data.get("confidence", 0.5))
            reasoning_text = str(data.get("reasoning", ""))

            # Clamp to valid ranges
            outcome_index = max(0, min(outcome_index, len(options) - 1))
            confidence = max(0.0, min(confidence, 1.0))

            # Build sources from web citations
            sources = [
                {
                    "url": c["url"],
                    "title": c.get("title", ""),
                    "snippet": "",
                }
                for c in parsed.web_citations
            ]

            reasoning_summary = "\n".join(parsed.reasoning_summary)

            logger.info(
                "researcher.responses_api.success",
                outcome_index=outcome_index,
                confidence=confidence,
                source_count=len(sources),
                search_query_count=len(parsed.web_search_queries),
            )

            return {
                "outcome_index": outcome_index,
                "confidence": confidence,
                "reasoning": reasoning_text,
                "sources": sources,
                "reasoning_summary": reasoning_summary,
                "web_search_queries": parsed.web_search_queries,
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
    def _extract_json_from_text(text: str) -> dict[str, Any]:
        """Extract JSON from text that may contain markdown fences.

        Tries in order:
        1. JSON inside ```json ... ``` fences
        2. Any JSON object containing ``outcome_index``
        3. Fallback defaults
        """
        # Try markdown-fenced JSON
        match = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.DOTALL)
        if match:
            try:
                return json.loads(match.group(1))
            except json.JSONDecodeError:
                pass

        # Try to find a bare JSON object with expected key
        match = re.search(r'\{[^{}]*"outcome_index"\s*:[^{}]*\}', text)
        if match:
            try:
                return json.loads(match.group(0))
            except json.JSONDecodeError:
                pass

        logger.warning(
            "researcher.json_extraction_failed",
            raw_text=text[:300],
        )
        return {"outcome_index": 0, "confidence": 0.3, "reasoning": text[:500]}
