"""
Evidence auditor for ChaosOracle verifier agents.

Evaluates worker evidence packages and produces score vectors across
four dimensions matching the ``PredictionSettlementLogic.submitScores``
contract interface:

- **Accuracy** (0-100): How likely is the chosen outcome to be correct?
- **Evidence Quality** (0-100): Are the cited sources credible and relevant?
- **Source Diversity** (0-100): Are multiple independent sources used?
- **Reasoning Depth** (0-100): Is the reasoning chain thorough and logical?

Uses the OpenAI Responses API with **web search** to independently verify
worker claims, and **reasoning** (o4-mini / o3) for chain-of-thought scoring.
"""

from __future__ import annotations

import json
import re
from typing import Any

import structlog

from shared.openai_client import (
    create_async_client,
    is_reasoning_model,
    parse_response_output,
)

logger = structlog.get_logger(__name__)


class Auditor:
    """Audits worker evidence packages and produces score vectors.

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
            "auditor.initialized",
            has_api_key=bool(openai_api_key),
            model=openai_model,
            reasoning_effort=reasoning_effort,
            is_reasoning_model=is_reasoning_model(openai_model),
        )

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    async def audit(
        self,
        evidence_package: dict[str, Any],
        question: str,
        options: list[str],
    ) -> list[int]:
        """Audit an evidence package and return scores.

        Parameters
        ----------
        evidence_package:
            The full evidence package fetched from IPFS/Arweave.
        question:
            The prediction market question text.
        options:
            List of possible outcome strings.

        Returns
        -------
        list[int]
            Four scores ``[accuracy, evidence_quality, source_diversity,
            reasoning_depth]``, each in the range 0-100.
        """
        logger.info(
            "auditor.audit.start",
            question=question[:120],
            worker_outcome=evidence_package.get("outcome"),
        )

        if self._client:
            scores = await self._llm_audit(evidence_package, question, options)
        else:
            scores = self._heuristic_audit(evidence_package)

        # Clamp all scores to [0, 100]
        scores = [max(0, min(100, s)) for s in scores]

        logger.info(
            "auditor.audit.done",
            accuracy=scores[0],
            evidence_quality=scores[1],
            source_diversity=scores[2],
            reasoning_depth=scores[3],
        )
        return scores

    # ------------------------------------------------------------------
    # Heuristic fallback (no LLM)
    # ------------------------------------------------------------------

    def _heuristic_audit(self, evidence_package: dict[str, Any]) -> list[int]:
        """Simple rule-based audit when no LLM is available.

        Scoring heuristics:
        - Accuracy: default mid-range (no external verification).
        - Evidence quality: based on source count and snippet length.
        - Source diversity: based on unique domains in sources.
        - Reasoning depth: based on reasoning text length.
        """
        logger.warning("auditor.heuristic_fallback", msg="No LLM API key; using heuristics.")

        sources = evidence_package.get("sources", [])
        reasoning = evidence_package.get("reasoning", "")
        confidence = evidence_package.get("confidence", 0.5)

        # Accuracy: scale from confidence (very rough proxy)
        accuracy = int(confidence * 100)

        # Evidence quality: more sources with longer snippets = higher
        snippet_lengths = [len(s.get("snippet", "")) for s in sources]
        avg_snippet = sum(snippet_lengths) / max(len(snippet_lengths), 1)
        evidence_quality = min(100, int(len(sources) * 15 + avg_snippet / 5))

        # Source diversity: count unique domains
        domains: set[str] = set()
        for s in sources:
            url = s.get("url", "")
            if "://" in url:
                domain = url.split("://", 1)[1].split("/", 1)[0]
                domains.add(domain)
        source_diversity = min(100, len(domains) * 25)

        # Reasoning depth: length of reasoning text
        reasoning_depth = min(100, int(len(reasoning) / 10))

        return [accuracy, evidence_quality, source_diversity, reasoning_depth]

    # ------------------------------------------------------------------
    # LLM-based audit (Responses API with web search)
    # ------------------------------------------------------------------

    async def _llm_audit(
        self,
        evidence_package: dict[str, Any],
        question: str,
        options: list[str],
    ) -> list[int]:
        """Use the Responses API with web search to independently verify
        worker claims and score the evidence.

        The model:
        1. Reads the worker's submission
        2. Searches the web to verify cited sources and claims
        3. Cross-references with additional sources
        4. Produces structured scores
        """
        options_text = "\n".join(f"  {i}: {opt}" for i, opt in enumerate(options))

        sources_text = "\n".join(
            f"  - [{s.get('title', 'N/A')}]({s.get('url', '')}): {s.get('snippet', '')}"
            for s in evidence_package.get("sources", [])
        )

        chosen_outcome = evidence_package.get("outcome", "?")
        confidence = evidence_package.get("confidence", "?")
        reasoning = evidence_package.get("reasoning", "(none)")

        prompt = (
            "You are an expert auditor for a prediction market settlement "
            "protocol.\n\n"
            "INSTRUCTIONS:\n"
            "1. Read the worker's submission below.\n"
            "2. Use web search to INDEPENDENTLY verify the worker's claims "
            "and check if the cited sources are real.\n"
            "3. Cross-reference the worker's reasoning with additional "
            "sources you find.\n"
            "4. Score the submission on four dimensions.\n"
            "5. Be concise and factual. No filler.\n\n"
            f"MARKET QUESTION: {question}\n\n"
            f"OPTIONS:\n{options_text}\n\n"
            f"WORKER SUBMISSION:\n"
            f"  Chosen outcome: {chosen_outcome} (confidence: {confidence})\n"
            f"  Sources:\n{sources_text}\n"
            f"  Reasoning: {reasoning}\n\n"
            "Respond with ONLY valid JSON matching this schema:\n"
            "{\n"
            '  "accuracy": <int 0-100>,\n'
            '  "evidence_quality": <int 0-100>,\n'
            '  "source_diversity": <int 0-100>,\n'
            '  "reasoning_depth": <int 0-100>\n'
            "}\n\n"
            "Scoring guide:\n"
            "- accuracy: How likely is the chosen outcome correct given "
            "YOUR independent web research?\n"
            "- evidence_quality: Are the worker's sources real, credible, "
            "and relevant? Did you verify them?\n"
            "- source_diversity: Are multiple independent sources from "
            "different domains used?\n"
            "- reasoning_depth: Is the reasoning chain thorough, logical, "
            "and well-structured?"
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
            parsed = parse_response_output(response)

            # Attempt to parse structured JSON from the response text
            try:
                result = json.loads(parsed.text)
            except json.JSONDecodeError:
                result = self._extract_scores_from_text(parsed.text)

            scores = [
                int(result.get("accuracy", 50)),
                int(result.get("evidence_quality", 50)),
                int(result.get("source_diversity", 50)),
                int(result.get("reasoning_depth", 50)),
            ]

            logger.info(
                "auditor.responses_api.success",
                scores=scores,
                search_query_count=len(parsed.web_search_queries),
                reasoning_summary_len=len("\n".join(parsed.reasoning_summary)),
            )
            return scores

        except Exception:
            logger.exception("auditor.responses_api.call_failed")
            # Graceful fallback to heuristic
            return self._heuristic_audit(evidence_package)

    # ------------------------------------------------------------------
    # JSON extraction helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _extract_scores_from_text(text: str) -> dict[str, Any]:
        """Extract score JSON from text that may contain markdown fences.

        Tries in order:
        1. JSON inside ```json ... ``` fences
        2. Any JSON object containing ``accuracy``
        3. Fallback defaults (all 50)
        """
        # Try markdown-fenced JSON
        match = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.DOTALL)
        if match:
            try:
                return json.loads(match.group(1))
            except json.JSONDecodeError:
                pass

        # Try to find a bare JSON object with expected key
        match = re.search(r'\{[^{}]*"accuracy"\s*:[^{}]*\}', text)
        if match:
            try:
                return json.loads(match.group(0))
            except json.JSONDecodeError:
                pass

        logger.warning(
            "auditor.json_extraction_failed",
            raw_text=text[:300],
        )
        return {
            "accuracy": 50,
            "evidence_quality": 50,
            "source_diversity": 50,
            "reasoning_depth": 50,
        }
