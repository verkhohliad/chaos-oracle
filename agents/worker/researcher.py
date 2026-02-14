"""
Market question researcher that uses LLM analysis and web search to determine
the most likely outcome for a prediction market question.

.. note::
    The web search and LLM calls are placeholder implementations that
    illustrate the expected interface.  Replace them with real API
    integrations (e.g., OpenAI, Tavily, SerpAPI) before production use.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Any

import aiohttp
import structlog

logger = structlog.get_logger(__name__)


@dataclass
class ResearchResult:
    """Structured result from a research run."""

    outcome_index: int
    confidence: float
    sources: list[dict[str, str]]
    reasoning: str


class Researcher:
    """Researches prediction market questions to determine the best outcome.

    Parameters
    ----------
    openai_api_key:
        API key for OpenAI (or compatible) LLM service.
    openai_model:
        Model identifier (e.g. ``gpt-4o``).
    """

    def __init__(
        self,
        openai_api_key: str = "",
        openai_model: str = "gpt-4o",
    ) -> None:
        self._api_key = openai_api_key
        self._model = openai_model

        logger.info(
            "researcher.initialized",
            has_api_key=bool(openai_api_key),
            model=openai_model,
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
            supporting sources, and free-form reasoning text.
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

        # Step 1: Search the web for relevant information
        sources = await self._web_search(question)

        # Step 2: Analyze with LLM
        analysis = await self._llm_analyze(question, options, sources)

        result = ResearchResult(
            outcome_index=analysis["outcome_index"],
            confidence=analysis["confidence"],
            sources=sources,
            reasoning=analysis["reasoning"],
        )

        logger.info(
            "researcher.research.done",
            outcome_index=result.outcome_index,
            outcome_label=options[result.outcome_index] if result.outcome_index < len(options) else "?",
            confidence=result.confidence,
            source_count=len(result.sources),
        )
        return result

    # ------------------------------------------------------------------
    # Web search (placeholder)
    # ------------------------------------------------------------------

    async def _web_search(self, query: str) -> list[dict[str, str]]:
        """Search the web for information relevant to *query*.

        .. note::
            **Placeholder implementation.**  In production, integrate with
            a search API such as Tavily, SerpAPI, or Brave Search.

        Returns
        -------
        list[dict]
            Each entry has keys ``url``, ``title``, and ``snippet``.
        """
        logger.info("researcher.web_search.placeholder", query=query[:80])

        # TODO: Replace with a real search API integration.
        # Example with Tavily:
        #
        #   async with aiohttp.ClientSession() as session:
        #       async with session.post(
        #           "https://api.tavily.com/search",
        #           json={"query": query, "api_key": self._tavily_key},
        #       ) as resp:
        #           data = await resp.json()
        #           return [
        #               {"url": r["url"], "title": r["title"], "snippet": r["content"]}
        #               for r in data.get("results", [])
        #           ]

        return [
            {
                "url": "https://example.com/placeholder-source-1",
                "title": "Placeholder source 1",
                "snippet": "This is a placeholder search result. Replace with real search API.",
            },
            {
                "url": "https://example.com/placeholder-source-2",
                "title": "Placeholder source 2",
                "snippet": "This is a placeholder search result. Replace with real search API.",
            },
        ]

    # ------------------------------------------------------------------
    # LLM analysis (placeholder)
    # ------------------------------------------------------------------

    async def _llm_analyze(
        self,
        question: str,
        options: list[str],
        sources: list[dict[str, str]],
    ) -> dict[str, Any]:
        """Use an LLM to analyze the question and sources, selecting the best outcome.

        .. note::
            **Placeholder implementation.**  In production, send a
            structured prompt to an LLM API (OpenAI, Anthropic, etc.)
            requesting a JSON response with ``outcome_index``,
            ``confidence``, and ``reasoning``.

        Returns
        -------
        dict
            Keys: ``outcome_index`` (int), ``confidence`` (float 0-1),
            ``reasoning`` (str).
        """
        if self._api_key:
            return await self._call_openai(question, options, sources)

        # Fallback: deterministic placeholder that always picks the first option.
        logger.warning(
            "researcher.llm_analyze.placeholder",
            msg="No API key configured; returning default outcome 0.",
        )
        return {
            "outcome_index": 0,
            "confidence": 0.5,
            "reasoning": (
                f"Placeholder analysis for: '{question}'. "
                f"Options: {options}. "
                f"No LLM API key configured; defaulting to option 0. "
                f"Sources consulted: {len(sources)}."
            ),
        }

    async def _call_openai(
        self,
        question: str,
        options: list[str],
        sources: list[dict[str, str]],
    ) -> dict[str, Any]:
        """Call the OpenAI Chat Completions API for analysis.

        Sends a structured prompt and expects a JSON response from the model.
        """
        options_text = "\n".join(f"  {i}: {opt}" for i, opt in enumerate(options))
        sources_text = "\n".join(
            f"  - [{s.get('title', 'N/A')}]({s.get('url', '')}): {s.get('snippet', '')}"
            for s in sources
        )

        system_prompt = (
            "You are a prediction market research analyst. Given a market question, "
            "possible outcomes, and web search results, determine the most likely "
            "outcome. Respond ONLY with valid JSON matching this schema:\n"
            '{"outcome_index": <int>, "confidence": <float 0-1>, "reasoning": "<string>"}'
        )
        user_prompt = (
            f"Question: {question}\n\n"
            f"Options:\n{options_text}\n\n"
            f"Sources:\n{sources_text}\n\n"
            "Analyze the evidence and select the most likely outcome."
        )

        headers = {
            "Authorization": f"Bearer {self._api_key}",
            "Content-Type": "application/json",
        }
        payload = {
            "model": self._model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
            "temperature": 1,
            "response_format": {"type": "json_object"},
        }

        try:
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    "https://api.openai.com/v1/chat/completions",
                    json=payload,
                    headers=headers,
                    timeout=aiohttp.ClientTimeout(total=60),
                ) as resp:
                    if resp.status != 200:
                        body = await resp.text()
                        logger.error(
                            "researcher.openai.error",
                            status=resp.status,
                            body=body[:500],
                        )
                        raise RuntimeError(f"OpenAI API error: {resp.status}")

                    data = await resp.json()
                    content = data["choices"][0]["message"]["content"]

                    import json
                    result = json.loads(content)

                    # Validate expected keys
                    outcome_index = int(result.get("outcome_index", 0))
                    confidence = float(result.get("confidence", 0.5))
                    reasoning = str(result.get("reasoning", ""))

                    # Clamp to valid range
                    outcome_index = max(0, min(outcome_index, len(options) - 1))
                    confidence = max(0.0, min(confidence, 1.0))

                    logger.info(
                        "researcher.openai.success",
                        outcome_index=outcome_index,
                        confidence=confidence,
                    )
                    return {
                        "outcome_index": outcome_index,
                        "confidence": confidence,
                        "reasoning": reasoning,
                    }
        except Exception:
            logger.exception("researcher.openai.call_failed")
            # Graceful fallback
            return {
                "outcome_index": 0,
                "confidence": 0.3,
                "reasoning": f"LLM call failed; fallback to option 0 for '{question}'.",
            }
