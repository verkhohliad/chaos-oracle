"""
ChaosOracle Verifier Agent -- autonomous event loop.

Polls the ChaosOracleRegistry for active studios with unscored submissions,
fetches worker evidence from Arweave, audits each submission, and submits
scores on-chain via the ChaosChain Gateway.

Usage::

    python -m verifier.main
"""

from __future__ import annotations

import asyncio
import signal
import sys
from typing import NoReturn

import structlog

from shared.arweave_client import ArweaveClient
from shared.registry_reader import RegistryReader
from shared.sdk_client import create_sdk_client
from verifier.auditor import Auditor
from verifier.config import VerifierConfig

# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------

structlog.configure(
    processors=[
        structlog.contextvars.merge_contextvars,
        structlog.processors.add_log_level,
        structlog.processors.StackInfoRenderer(),
        structlog.dev.set_exc_info,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.dev.ConsoleRenderer(),
    ],
    wrapper_class=structlog.make_filtering_bound_logger(0),
    context_class=dict,
    logger_factory=structlog.PrintLoggerFactory(),
    cache_logger_on_first_use=True,
)

logger = structlog.get_logger("verifier.main")

# ---------------------------------------------------------------------------
# Network config mapping (gateway mode only)
# ---------------------------------------------------------------------------


def _resolve_network(name: str):
    """Map a config string to a :class:`NetworkConfig` value.

    Only imported when running in gateway mode (requires chaoschain_sdk).
    """
    from chaoschain_sdk import NetworkConfig

    _map: dict[str, NetworkConfig] = {
        "ethereum_sepolia": NetworkConfig.ETHEREUM_SEPOLIA,
    }
    try:
        return _map[name.lower()]
    except KeyError:
        logger.warning("verifier.unknown_network", name=name, fallback="ETHEREUM_SEPOLIA")
        return NetworkConfig.ETHEREUM_SEPOLIA


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------


async def run(config: VerifierConfig) -> NoReturn:
    """Main verifier agent loop.

    1. Initialise SDK client and auto-register ERC-8004 identity.
    2. Poll the registry every ``config.poll_interval_seconds``.
    3. For each active studio with unscored worker submissions:
       a. Fetch the worker's evidence package from Arweave.
       b. Audit the evidence via :class:`Auditor`.
       c. Register as verifier and submit scores on-chain.
    4. Track scored ``(studio, worker)`` pairs to avoid duplicates.
    """

    # -- Components ---------------------------------------------------------
    if config.chaoschain_mode == "local":
        logger.info("verifier.mode.local", msg="Using DirectSubmitter (no Gateway)")
        sdk_client = create_sdk_client(
            mode="local",
            private_key=config.verifier_private_key,
            rpc_url=config.sepolia_rpc_url,
        )
    else:
        from chaoschain_sdk import AgentRole

        logger.info("verifier.mode.gateway", msg="Using ChaosChain Gateway")
        network = _resolve_network(config.chaoschain_network)
        sdk_client = create_sdk_client(
            mode="gateway",
            private_key=config.verifier_private_key,
            network=network,
            gateway_url=config.chaoschain_gateway_url,
            agent_name="ChaosOracle-Verifier",
            agent_domain="verifier.chaosoracle.example.com",
            agent_role=AgentRole.VERIFIER,
        )

    registry = RegistryReader(
        rpc_url=config.sepolia_rpc_url,
        registry_address=config.chaos_oracle_registry_address,
    )

    auditor = Auditor(
        openai_api_key=config.openai_api_key,
        openai_model=config.openai_model,
    )

    arweave = ArweaveClient()

    # -- Identity registration -----------------------------------------------
    agent_id = await sdk_client.auto_register()
    logger.info("verifier.identity_ready", agent_id=agent_id, wallet=sdk_client.wallet_address)

    # -- State ---------------------------------------------------------------
    # Tracks (studio_address, worker_address) pairs we have already scored.
    scored_pairs: set[tuple[str, str]] = set()

    # Studios where we have already registered as a verifier.
    registered_studios: set[str] = set()

    # -- Poll loop -----------------------------------------------------------
    logger.info("verifier.loop.start", poll_interval=config.poll_interval_seconds)

    while True:
        try:
            studios = registry.get_active_studios()

            for studio_address in studios:
                try:
                    # Fetch studio details to check if epoch is still open
                    details = registry.get_studio_details(studio_address)
                    if details.epoch_closed:
                        continue

                    # Only look at studios that have at least one worker submission
                    if details.worker_count == 0:
                        continue

                    # Get submissions not yet scored by this verifier
                    unscored = registry.get_unscored_submissions(
                        studio_address=studio_address,
                        verifier_address=sdk_client.wallet_address,
                    )

                    for submission in unscored:
                        pair = (studio_address, submission.worker_address)
                        if pair in scored_pairs:
                            continue

                        logger.info(
                            "verifier.auditing_submission",
                            studio=studio_address,
                            worker=submission.worker_address,
                            evidence_cid=submission.evidence_cid,
                        )

                        try:
                            # 1. Fetch evidence from Arweave
                            evidence_package = await arweave.fetch_evidence(
                                submission.evidence_cid,
                            )

                            # 2. Audit the evidence
                            scores = await auditor.audit(
                                evidence_package=evidence_package,
                                question=details.question,
                                options=details.options,
                            )

                            # 3. Submit scores on-chain
                            await sdk_client.submit_scores(
                                studio_address=studio_address,
                                worker_address=submission.worker_address,
                                scores=scores,
                            )

                            scored_pairs.add(pair)
                            logger.info(
                                "verifier.scores_submitted",
                                studio=studio_address,
                                worker=submission.worker_address,
                                scores=scores,
                            )

                        except Exception:
                            logger.exception(
                                "verifier.submission_audit_error",
                                studio=studio_address,
                                worker=submission.worker_address,
                            )
                            # Do not add to scored_pairs -- retry next cycle.

                except Exception:
                    logger.exception("verifier.studio_processing_error", studio=studio_address)

        except Exception:
            logger.exception("verifier.poll_cycle_error")

        await asyncio.sleep(config.poll_interval_seconds)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main() -> None:
    """Parse config, wire signal handlers, and launch the async loop."""
    config = VerifierConfig()  # type: ignore[call-arg]

    loop = asyncio.new_event_loop()

    shutdown_event = asyncio.Event()

    def _signal_handler(sig: signal.Signals, _frame: object) -> None:  # noqa: N803
        logger.info("verifier.signal_received", signal=sig.name)
        shutdown_event.set()

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, _signal_handler)

    async def _run_until_shutdown() -> None:
        task = asyncio.create_task(run(config))
        await shutdown_event.wait()
        logger.info("verifier.shutting_down")
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        logger.info("verifier.shutdown_complete")

    try:
        loop.run_until_complete(_run_until_shutdown())
    except KeyboardInterrupt:
        logger.info("verifier.keyboard_interrupt")
    finally:
        loop.close()


if __name__ == "__main__":
    main()
