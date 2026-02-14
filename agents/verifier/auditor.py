"""
Evidence auditor for ChaosOracle verifier agents.

Evaluates worker evidence packages and produces score vectors across
four dimensions matching the ``PredictionSettlementLogic.submitScores``
contract interface:

- **Accuracy** (0-100): How likely is the chosen outcome to be correct?
- **Evidence Quality** (0-100): Are the cited sources credible and relevant?
- **Source Diversity** (0-100): Are multiple independent sources used?
- **Reasoning Depth** (0-100): Is the reasoning chain thorough and logical?

.. note::
    The LLM-based audit is a placeholder implementation that shows the
    expected interface.  Replace with real API calls before production use.
"""

from __future__ import annotations

from typing import Any

import aiohttp
import structlog

logger = structlog.get_logger(__name__)


class Auditor:
    """Audits worker evidence packages and produces score vectors.

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
            "auditor.initialized",
            has_api_key=bool(openai_api_key),
            model=openai_model,
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
            The full evidence package fetched from Arweave.
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

        if self._api_key:
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
    # LLM-based audit
    # ------------------------------------------------------------------

    async def _llm_audit(
        self,
        evidence_package: dict[str, Any],
        question: str,
        options: list[str],
    ) -> list[int]:
        """Use an LLM to evaluate the evidence package quality.

        Sends the evidence package to the LLM and requests structured
        JSON scores.

        Returns
        -------
        list[int]
            ``[accuracy, evidence_quality, source_diversity, reasoning_depth]``
        """
        options_text = "\n".join(f"  {i}: {opt}" for i, opt in enumerate(options))

        sources_text = "\n".join(
            f"  - [{s.get('title', 'N/A')}]({s.get('url', '')}): {s.get('snippet', '')}"
            for s in evidence_package.get("sources", [])
        )

        chosen_outcome = evidence_package.get("outcome", "?")
        confidence = evidence_package.get("confidence", "?")
        reasoning = evidence_package.get("reasoning", "(none)")

        system_prompt = (
            "You are an expert auditor for a prediction market settlement protocol. "
            "Evaluate the following worker submission and score it on four dimensions. "
            "Respond ONLY with valid JSON matching this schema:\n"
            "{\n"
            '  "accuracy": <int 0-100>,\n'
            '  "evidence_quality": <int 0-100>,\n'
            '  "source_diversity": <int 0-100>,\n'
            '  "reasoning_depth": <int 0-100>\n'
            "}\n\n"
            "Scoring guide:\n"
            "- accuracy: How likely is the chosen outcome correct given the evidence?\n"
            "- evidence_quality: Are sources credible, relevant, and properly cited?\n"
            "- source_diversity: Are multiple independent sources from different domains used?\n"
            "- reasoning_depth: Is the reasoning chain thorough, logical, and well-structured?"
        )

        user_prompt = (
            f"Market Question: {question}\n\n"
            f"Options:\n{options_text}\n\n"
            f"Worker chose outcome: {chosen_outcome} "
            f"(confidence: {confidence})\n\n"
            f"Sources provided:\n{sources_text}\n\n"
            f"Reasoning:\n{reasoning}\n\n"
            "Please evaluate and score this submission."
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
                        logger.error("auditor.openai.error", status=resp.status, body=body[:500])
                        raise RuntimeError(f"OpenAI API error: {resp.status}")

                    data = await resp.json()
                    content = data["choices"][0]["message"]["content"]

                    import json
                    result = json.loads(content)

                    scores = [
                        int(result.get("accuracy", 50)),
                        int(result.get("evidence_quality", 50)),
                        int(result.get("source_diversity", 50)),
                        int(result.get("reasoning_depth", 50)),
                    ]

                    logger.info("auditor.openai.success", scores=scores)
                    return scores

        except Exception:
            logger.exception("auditor.openai.call_failed")
            # Graceful fallback to heuristic
            return self._heuristic_audit(evidence_package)
