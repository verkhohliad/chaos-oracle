"""
ChaosOracle Worker Agent -- autonomous event loop.

Polls the ChaosOracleRegistry for active studios, researches each market
question, builds evidence packages, uploads them to Arweave, and submits
the predicted outcome on-chain via the ChaosChain Gateway.

Usage::

    python -m worker.main
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
from worker.config import WorkerConfig
from worker.evidence import EvidenceBuilder
from worker.researcher import Researcher

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

logger = structlog.get_logger("worker.main")

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
        logger.warning("worker.unknown_network", name=name, fallback="ETHEREUM_SEPOLIA")
        return NetworkConfig.ETHEREUM_SEPOLIA


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------


async def run(config: WorkerConfig) -> NoReturn:
    """Main worker agent loop.

    1. Initialise SDK client and auto-register ERC-8004 identity.
    2. Poll the registry every ``config.poll_interval_seconds``.
    3. For each new active studio:
       a. Read the market question and options.
       b. Research the question via :class:`Researcher`.
       c. Build an evidence package via :class:`EvidenceBuilder`.
       d. Upload evidence to Arweave.
       e. Register as worker and submit the outcome on-chain.
    4. Track participated studios to avoid duplicate work.
    """

    # -- Components ---------------------------------------------------------
    if config.chaoschain_mode == "local":
        logger.info("worker.mode.local", msg="Using DirectSubmitter (no Gateway)")
        sdk_client = create_sdk_client(
            mode="local",
            private_key=config.worker_private_key,
            rpc_url=config.sepolia_rpc_url,
        )
    else:
        from chaoschain_sdk import AgentRole

        logger.info("worker.mode.gateway", msg="Using ChaosChain Gateway")
        network = _resolve_network(config.chaoschain_network)
        sdk_client = create_sdk_client(
            mode="gateway",
            private_key=config.worker_private_key,
            network=network,
            gateway_url=config.chaoschain_gateway_url,
            agent_name="ChaosOracle-Worker",
            agent_domain="worker.chaosoracle.example.com",
            agent_role=AgentRole.WORKER,
        )

    registry = RegistryReader(
        rpc_url=config.sepolia_rpc_url,
        registry_address=config.chaos_oracle_registry_address,
    )

    researcher = Researcher(
        openai_api_key=config.openai_api_key,
        openai_model=config.openai_model,
    )

    evidence_builder = EvidenceBuilder()

    arweave = ArweaveClient(
        wallet_path=config.arweave_wallet_path or None,
    )

    # -- Identity registration -----------------------------------------------
    agent_id = await sdk_client.auto_register()
    logger.info("worker.identity_ready", agent_id=agent_id, wallet=sdk_client.wallet_address)

    # -- State ---------------------------------------------------------------
    participated_studios: set[str] = set()

    # -- Poll loop -----------------------------------------------------------
    logger.info("worker.loop.start", poll_interval=config.poll_interval_seconds)

    while True:
        try:
            studios = registry.get_active_studios()

            for studio_address in studios:
                if studio_address in participated_studios:
                    continue

                logger.info("worker.new_studio", studio=studio_address)

                try:
                    # 1. Read studio details
                    details = registry.get_studio_details(studio_address)
                    if details.epoch_closed:
                        logger.info("worker.studio_closed_skipping", studio=studio_address)
                        participated_studios.add(studio_address)
                        continue

                    # 2. Research the question
                    result = await researcher.research(details.question, details.options)

                    # 3. Build evidence package
                    evidence_package = evidence_builder.build(
                        question=details.question,
                        outcome=result.outcome_index,
                        confidence=result.confidence,
                        sources=result.sources,
                        reasoning=result.reasoning,
                    )

                    # 4. Upload to Arweave
                    evidence_cid = await arweave.upload_evidence(evidence_package)
                    logger.info("worker.evidence_uploaded", cid=evidence_cid)

                    # 5. Submit work on-chain
                    await sdk_client.submit_work(
                        studio_address=studio_address,
                        outcome=result.outcome_index,
                        evidence_cid=evidence_cid,
                    )

                    participated_studios.add(studio_address)
                    logger.info(
                        "worker.submission_complete",
                        studio=studio_address,
                        outcome=result.outcome_index,
                        confidence=result.confidence,
                    )

                except Exception:
                    logger.exception("worker.studio_processing_error", studio=studio_address)
                    # Do not add to participated so we retry next cycle.

        except Exception:
            logger.exception("worker.poll_cycle_error")

        await asyncio.sleep(config.poll_interval_seconds)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main() -> None:
    """Parse config, wire signal handlers, and launch the async loop."""
    config = WorkerConfig()  # type: ignore[call-arg]

    loop = asyncio.new_event_loop()

    # Graceful shutdown on SIGTERM / SIGINT
    shutdown_event = asyncio.Event()

    def _signal_handler(sig: signal.Signals, _frame: object) -> None:  # noqa: N803
        logger.info("worker.signal_received", signal=sig.name)
        shutdown_event.set()

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, _signal_handler)

    async def _run_until_shutdown() -> None:
        task = asyncio.create_task(run(config))
        await shutdown_event.wait()
        logger.info("worker.shutting_down")
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        logger.info("worker.shutdown_complete")

    try:
        loop.run_until_complete(_run_until_shutdown())
    except KeyboardInterrupt:
        logger.info("worker.keyboard_interrupt")
    finally:
        loop.close()


if __name__ == "__main__":
    main()
