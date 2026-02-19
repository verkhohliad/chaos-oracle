"""
Evidence auditor for ChaosOracle verifier agents.

Evaluates worker evidence packages and produces score vectors across
dynamic scoring dimensions read from the on-chain ``getScoringCriteria()``
contract call.

Uses the OpenAI Responses API with **web search** to independently verify
worker claims, and **reasoning** (o4-mini / o3) for chain-of-thought scoring.

Scoring criteria are dynamic — the 5 universal PoA dimensions plus any
studio-specific dimensions are read from the contract and used to build
the audit prompt and response schema.
"""

from __future__ import annotations

import json
import re
from typing import Any

import structlog

from shared.openai_client import (
    ParsedResponse,
    create_async_client,
    is_reasoning_model,
    stream_responses_with_logging,
)

logger = structlog.get_logger(__name__)

# ── Default scoring criteria (backward compatibility) ────────────────
DEFAULT_SCORING_CRITERIA = [
    {"name": "Accuracy", "weight": 200},
    {"name": "Evidence Quality", "weight": 150},
    {"name": "Source Diversity", "weight": 120},
    {"name": "Reasoning Depth", "weight": 130},
]


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
        scoring_criteria: list[dict] | None = None,
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
        scoring_criteria:
            List of ``{"name": str, "weight": int}`` dicts from on-chain
            ``getScoringCriteria()``.  Falls back to defaults if not provided.

        Returns
        -------
        list[int]
            Scores for each dimension, each in the range 0-100.
        """
        # Normalize scoring criteria
        if scoring_criteria is None:
            criteria = DEFAULT_SCORING_CRITERIA
        else:
            criteria = [
                {"name": c.name, "weight": c.weight}
                if hasattr(c, "name")
                else c
                for c in scoring_criteria
            ]

        logger.info(
            "auditor.audit.start",
            question=question[:120],
            worker_outcome=evidence_package.get("outcome"),
            scoring_dimensions=[c["name"] for c in criteria],
        )

        if self._client:
            scores = await self._llm_audit(
                evidence_package, question, options, criteria,
            )
        else:
            scores = self._heuristic_audit(evidence_package, criteria)

        # Clamp all scores to [0, 100]
        scores = [max(0, min(100, s)) for s in scores]

        # Ensure correct length
        while len(scores) < len(criteria):
            scores.append(50)
        scores = scores[:len(criteria)]

        logger.info(
            "auditor.audit.done",
            scores=scores,
            dimensions=[c["name"] for c in criteria],
            dimension_scores=dict(zip([c["name"] for c in criteria], scores)),
        )
        return scores

    # ------------------------------------------------------------------
    # LLM-based audit (Responses API with web search)
    # ------------------------------------------------------------------

    async def _llm_audit(
        self,
        evidence_package: dict[str, Any],
        question: str,
        options: list[str],
        criteria: list[dict],
    ) -> list[int]:
        """Use the Responses API with web search to independently verify
        worker claims and score the evidence.

        The model:
        1. Reads the worker's submission
        2. Searches the web to verify cited sources and claims
        3. Cross-references with additional sources
        4. Looks for contradictory evidence
        5. Produces structured scores for each scoring dimension
        """
        options_text = "\n".join(f"  {i}: {opt}" for i, opt in enumerate(options))

        sources_text = "\n".join(
            f"  - [{s.get('title', 'N/A')}]({s.get('url', '')}): "
            f"{s.get('snippet', '')}"
            for s in evidence_package.get("sources", [])
        )

        chosen_outcome = evidence_package.get("outcome", "?")
        confidence = evidence_package.get("confidence", "?")
        reasoning = evidence_package.get("reasoning", "(none)")

        # Build dynamic dimension text and JSON schema from criteria
        dimensions_text = "\n".join(
            f"  - {c['name']} (weight: {c['weight']}): Score 0-100"
            for c in criteria
        )

        json_schema = (
            "{\n"
            + ",\n".join(f'  "{c["name"]}": <int 0-100>' for c in criteria)
            + "\n}"
        )

        # Outcome label for display
        try:
            outcome_label = options[int(chosen_outcome)]
        except (ValueError, TypeError, IndexError):
            outcome_label = "?"

        prompt = (
            "You are an expert auditor for a prediction market settlement "
            "protocol.\n\n"
            "INSTRUCTIONS:\n"
            "1. Read the worker's submission below carefully.\n"
            "2. Use web search to INDEPENDENTLY verify the worker's claims "
            "and check if the cited sources are real and accessible.\n"
            "3. Cross-reference the worker's reasoning with additional "
            "sources you find independently.\n"
            "4. Look for contradictory evidence that might disprove the "
            "worker's conclusion.\n"
            "5. Assess the overall quality of the submission.\n"
            "6. Score the submission on the dimensions listed below.\n"
            "7. Be concise and factual. No filler.\n\n"
            f"MARKET QUESTION: {question}\n\n"
            f"OPTIONS:\n{options_text}\n\n"
            f"WORKER SUBMISSION:\n"
            f"  Chosen outcome: {chosen_outcome} ({outcome_label})\n"
            f"  Confidence: {confidence}\n"
            f"  Sources:\n{sources_text}\n"
            f"  Reasoning: {reasoning}\n\n"
            f"SCORING DIMENSIONS:\n{dimensions_text}\n\n"
            f"Respond with ONLY valid JSON matching this schema:\n"
            f"{json_schema}\n\n"
            "Scoring guide:\n"
            "- 0-20: Very poor, major issues (fabricated sources, wrong "
            "conclusion)\n"
            "- 21-40: Below average, significant problems\n"
            "- 41-60: Average, meets minimum requirements\n"
            "- 61-80: Good, solid evidence and reasoning\n"
            "- 81-100: Excellent, outstanding quality\n\n"
            "Be fair but rigorous. Base scores on evidence from your own "
            "independent verification, not assumptions."
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
                self._client, caller="auditor", **kwargs,
            )

            # Attempt to parse structured JSON from the response text
            try:
                result = json.loads(parsed.text)
            except json.JSONDecodeError:
                result = self._extract_json_from_text(parsed.text)

            if result:
                scores = self._extract_scores_from_dict(result, criteria)
            else:
                # No JSON found — retry with a formatting-only call
                logger.warning(
                    "auditor.no_json_found",
                    msg="No JSON in response; retrying with format-only call.",
                    text_preview=parsed.text[:200],
                )
                scores = await self._retry_format_scores(
                    parsed.text, criteria, json_schema,
                )

            logger.info(
                "auditor.responses_api.success",
                scores=scores,
                search_query_count=len(parsed.web_search_queries),
                reasoning_summary_len=len("\n".join(parsed.reasoning_summary)),
                dimensions=[c["name"] for c in criteria],
            )
            return scores

        except Exception:
            logger.exception("auditor.responses_api.call_failed")
            # Graceful fallback to heuristic
            return self._heuristic_audit(evidence_package, criteria)

    # ------------------------------------------------------------------
    # JSON formatting retry (when model returns prose instead of JSON)
    # ------------------------------------------------------------------

    async def _retry_format_scores(
        self,
        prose_text: str,
        criteria: list[dict],
        json_schema: str,
    ) -> list[int]:
        """Make a cheap follow-up call to extract scores as JSON from prose.

        When the initial web-search-enabled call returns prose analysis
        instead of JSON (common with gpt-4.1), this method sends the prose
        to the model WITHOUT web_search and asks it to output just JSON.
        Falls back to ``_parse_scores()`` if the retry also fails.
        """
        retry_prompt = (
            "The following is an audit analysis of a prediction market "
            "worker submission. Extract the scores and respond with "
            "ONLY valid JSON — no explanation, no markdown, just the "
            "JSON object.\n\n"
            f"Required JSON schema:\n{json_schema}\n\n"
            "Each value must be an integer from 0 to 100.\n\n"
            f"Audit analysis:\n{prose_text[:4000]}"
        )

        try:
            logger.info("auditor.retry_format_scores", msg="Retrying with format-only call.")
            response = await self._client.responses.create(
                model=self._model,
                input=retry_prompt,
            )

            # Extract text from response
            retry_text = ""
            for item in response.output:
                if getattr(item, "type", None) == "message":
                    for block in getattr(item, "content", []):
                        if getattr(block, "type", None) == "output_text":
                            retry_text += getattr(block, "text", "")

            # Try to parse JSON from retry response
            try:
                result = json.loads(retry_text)
            except json.JSONDecodeError:
                result = self._extract_json_from_text(retry_text)

            if result:
                scores = self._extract_scores_from_dict(result, criteria)
                logger.info(
                    "auditor.retry_format_scores.success",
                    scores=scores,
                )
                return scores

        except Exception:
            logger.exception("auditor.retry_format_scores.failed")

        # Final fallback: try prose extraction from original text
        return self._parse_scores(prose_text, criteria)

    # ------------------------------------------------------------------
    # Heuristic fallback (no LLM)
    # ------------------------------------------------------------------

    def _heuristic_audit(
        self,
        evidence_package: dict[str, Any],
        criteria: list[dict] | None = None,
    ) -> list[int]:
        """Simple rule-based audit when no LLM is available.

        Produces scores matching the criteria dimension count.
        Maps dimension names to heuristic formulas via keyword matching.
        """
        logger.warning(
            "auditor.heuristic_fallback",
            msg="No LLM available; using heuristics.",
        )

        if criteria is None:
            criteria = DEFAULT_SCORING_CRITERIA

        sources = evidence_package.get("sources", [])
        reasoning = evidence_package.get("reasoning", "")
        confidence = evidence_package.get("confidence", 0.5)
        web_queries = evidence_package.get("web_search_queries", [])

        # Base scores from evidence quality signals
        source_count = len(sources)
        reasoning_length = len(reasoning)
        query_count = len(web_queries)

        base_accuracy = int(confidence * 80) + (10 if source_count > 2 else 0)
        base_quality = min(100, source_count * 15 + reasoning_length // 20)
        base_diversity = min(100, len(set(
            s.get("url", "").split("://")[-1].split("/")[0]
            for s in sources if s.get("url")
        )) * 25)
        base_reasoning = min(100, reasoning_length // 10 + query_count * 5)

        # Map to dimension count via keyword matching
        scores = []
        for c in criteria:
            name_lower = c["name"].lower()
            if "accuracy" in name_lower:
                scores.append(base_accuracy)
            elif "evidence" in name_lower or "quality" in name_lower:
                scores.append(base_quality)
            elif "diversity" in name_lower or "source" in name_lower:
                scores.append(base_diversity)
            elif "reasoning" in name_lower or "depth" in name_lower:
                scores.append(base_reasoning)
            elif "initiative" in name_lower:
                scores.append(min(100, source_count * 10 + query_count * 10))
            elif "collaboration" in name_lower:
                scores.append(50)  # Can't assess collaboration heuristically
            elif "compliance" in name_lower:
                scores.append(70 if sources else 30)
            elif "efficiency" in name_lower:
                scores.append(60)
            else:
                scores.append(50)  # Unknown dimension default

        return scores

    # ------------------------------------------------------------------
    # Score parsing helpers
    # ------------------------------------------------------------------

    def _parse_scores(
        self,
        text: str,
        criteria: list[dict],
    ) -> list[int]:
        """Parse scores from LLM response text.

        Tries JSON parsing first, then balanced-brace scan, then
        dimension-name matching, then raw number extraction.
        """
        # Try direct JSON parse
        try:
            data = json.loads(text)
            return self._extract_scores_from_dict(data, criteria)
        except (json.JSONDecodeError, ValueError):
            pass

        # Try balanced-brace JSON extraction
        objs = self._find_json_objects(text)
        if objs:
            best = max(objs, key=lambda o: len(o))
            try:
                return self._extract_scores_from_dict(best, criteria)
            except (ValueError, TypeError):
                pass

        # Try dimension-name matching: "Accuracy: 75" or "Accuracy = 75"
        scores: list[int] = []
        for c in criteria:
            name = c["name"]
            # Match patterns like "Accuracy: 75", "Accuracy = 82", "Accuracy - 90"
            pattern = re.escape(name) + r'\s*[:\-=]\s*(\d{1,3})'
            match = re.search(pattern, text, re.IGNORECASE)
            if match:
                val = int(match.group(1))
                if 0 <= val <= 100:
                    scores.append(val)
                    continue
            scores.append(-1)  # Sentinel for "not found"

        found_count = sum(1 for s in scores if s >= 0)
        if found_count >= len(criteria) // 2:
            # Got at least half the dimensions — fill missing with 50
            logger.info(
                "auditor.prose_score_extraction",
                found=found_count,
                total=len(criteria),
            )
            return [s if s >= 0 else 50 for s in scores]

        # Last resort: extract all plausible score numbers
        logger.warning("auditor.score_parse_fallback", raw_text=text[:300])
        numbers = re.findall(r'\b(\d{1,3})\b', text)
        raw_scores = [int(n) for n in numbers if 0 <= int(n) <= 100]

        # Pad or truncate to match criteria length
        while len(raw_scores) < len(criteria):
            raw_scores.append(50)
        return raw_scores[:len(criteria)]

    @staticmethod
    def _extract_scores_from_dict(
        data: dict[str, Any],
        criteria: list[dict],
    ) -> list[int]:
        """Extract scores from a parsed JSON dict matching criteria names."""
        scores = []
        for c in criteria:
            name = c["name"]
            # Try exact match first, then case-insensitive, then snake_case
            if name in data:
                scores.append(int(data[name]))
            else:
                found = False
                name_lower = name.lower()
                name_snake = name.lower().replace(" ", "_")
                for key, val in data.items():
                    if key.lower() == name_lower or key.lower() == name_snake:
                        scores.append(int(val))
                        found = True
                        break
                if not found:
                    scores.append(50)  # Default for missing dimension

        return scores

    # ------------------------------------------------------------------
    # JSON extraction helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _find_json_objects(text: str) -> list[dict[str, Any]]:
        """Find all valid JSON objects in text using balanced-brace scanning.

        Handles nested objects and arrays, unlike simple ``\\{[^{}]*\\}`` regex.
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
        2. All balanced JSON objects in the text — return the largest one
        3. Fallback: empty dict (caller should try _parse_scores)
        """
        # Try markdown-fenced JSON (use balanced-brace scan on fenced content)
        fence_match = re.search(r"```(?:json)?\s*(\{.+)\s*```", text, re.DOTALL)
        if fence_match:
            fenced = fence_match.group(1)
            objs = Auditor._find_json_objects(fenced)
            if objs:
                return objs[0]

        # Scan full text for JSON objects, return the largest
        objs = Auditor._find_json_objects(text)
        if objs:
            # Prefer the object with the most keys (most likely the scores)
            return max(objs, key=lambda o: len(o))

        logger.warning(
            "auditor.json_extraction_failed",
            raw_text=text[:300],
        )
        return {}
