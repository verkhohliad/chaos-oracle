import {
  ExamplePredictionMarket,
  ChaosOracleRegistry,
  RewardsDistributor,
  StudioProxy,
} from "../generated";

// ---------------------------------------------------------------------------
// ExamplePredictionMarket handlers
// ---------------------------------------------------------------------------

ExamplePredictionMarket.MarketCreated.handler(async ({ event, context }) => {
  const id = event.params.marketId.toString();

  context.Market.set({
    id,
    marketId: event.params.marketId,
    creator: event.params.creator,
    question: event.params.question,
    options: ["Yes", "No"],
    deadline: event.params.deadline,
    yesPool: 0n,
    noPool: 0n,
    outcome: undefined,
    proofHash: undefined,
    settled: false,
    settlementReward: event.params.settlementReward,
    registryKey: "",
    studio_id: undefined,
    createdAtBlock: BigInt(event.block.number),
    createdAtTimestamp: BigInt(event.block.timestamp),
  });
});

ExamplePredictionMarket.BetPlaced.handler(async ({ event, context }) => {
  const betId = `${event.transaction.hash}-${event.logIndex}`;
  const marketId = event.params.marketId.toString();

  context.Bet.set({
    id: betId,
    market_id: marketId,
    bettor: event.params.bettor,
    option: Number(event.params.option),
    amount: event.params.amount,
    blockTimestamp: BigInt(event.block.timestamp),
  });

  // Update pool totals on the market
  const market = await context.Market.get(marketId);
  if (market) {
    if (Number(event.params.option) === 0) {
      context.Market.set({
        ...market,
        yesPool: market.yesPool + event.params.amount,
      });
    } else {
      context.Market.set({
        ...market,
        noPool: market.noPool + event.params.amount,
      });
    }
  }
});

ExamplePredictionMarket.MarketSettled.handler(async ({ event, context }) => {
  const marketId = event.params.marketId.toString();
  const market = await context.Market.get(marketId);
  if (market) {
    context.Market.set({
      ...market,
      outcome: Number(event.params.outcome),
      proofHash: event.params.proofHash,
      settled: true,
    });
  }
});

ExamplePredictionMarket.WinningsClaimed.handler(async ({ event, context }) => {
  const claimId = `${event.transaction.hash}-${event.logIndex}`;
  const marketId = event.params.marketId.toString();

  context.Claim.set({
    id: claimId,
    market_id: marketId,
    claimer: event.params.claimer,
    amount: event.params.amount,
    blockTimestamp: BigInt(event.block.timestamp),
  });
});

// ---------------------------------------------------------------------------
// ChaosOracleRegistry handlers
// ---------------------------------------------------------------------------

ChaosOracleRegistry.MarketRegistered.handler(async ({ event, context }) => {
  const marketId = event.params.marketId.toString();
  const market = await context.Market.get(marketId);
  if (market) {
    context.Market.set({
      ...market,
      registryKey: event.params.key,
      options: event.params.options,
      settlementReward: event.params.reward,
    });
  }
});

// Dynamic contract registration: register new StudioProxy for indexing
ChaosOracleRegistry.StudioCreated.contractRegister(({ event, context }) => {
  context.addStudioProxy(event.params.studio);
});

ChaosOracleRegistry.StudioCreated.handler(async ({ event, context }) => {
  const studioAddr = event.params.studio.toLowerCase();
  const marketId = event.params.marketId.toString();

  context.Studio.set({
    id: studioAddr,
    market_id: marketId,
    studioId: event.params.studioId,
    registryKey: event.params.key,
    settled: false,
    outcome: undefined,
    proofHash: undefined,
    epochClose_id: undefined,
    createdAtBlock: BigInt(event.block.number),
    createdAtTimestamp: BigInt(event.block.timestamp),
    settledAtTimestamp: undefined,
  });

  // Link the studio to the market
  const market = await context.Market.get(marketId);
  if (market) {
    context.Market.set({
      ...market,
      studio_id: studioAddr,
    });
  }
});

ChaosOracleRegistry.StudioSettled.handler(async ({ event, context }) => {
  const studioAddr = event.params.studio.toLowerCase();
  const studio = await context.Studio.get(studioAddr);
  if (studio) {
    context.Studio.set({
      ...studio,
      settled: true,
      outcome: Number(event.params.outcome),
      proofHash: event.params.proofHash,
      settledAtTimestamp: BigInt(event.block.timestamp),
    });
  }
});

// ---------------------------------------------------------------------------
// StudioProxy handlers (dynamic contracts)
// ---------------------------------------------------------------------------

StudioProxy.AgentRegistered.handler(async ({ event, context }) => {
  const studioAddr = event.srcAddress.toLowerCase();
  const agentId = `${studioAddr}-${event.params.agentId.toString()}`;

  context.StudioAgent.set({
    id: agentId,
    studio_id: studioAddr,
    agentId: event.params.agentId,
    agentAddress: event.params.agentAddress.toLowerCase(),
    role: Number(event.params.role),
    stake: event.params.stake,
    blockTimestamp: BigInt(event.block.timestamp),
  });
});

StudioProxy.WorkSubmitted.handler(async ({ event, context }) => {
  const studioAddr = event.srcAddress.toLowerCase();
  const dataHash = event.params.dataHash;
  const submissionId = `${studioAddr}-${dataHash}`;

  // Resolve agent address from StudioAgent entity
  const agentEntityId = `${studioAddr}-${event.params.agentId.toString()}`;
  const agent = await context.StudioAgent.get(agentEntityId);

  context.WorkSubmission.set({
    id: submissionId,
    studio_id: studioAddr,
    agentId: event.params.agentId,
    agentAddress: agent ? agent.agentAddress : undefined,
    dataHash,
    threadRoot: event.params.threadRoot,
    evidenceRoot: event.params.evidenceRoot,
    timestamp: event.params.timestamp,
  });
});

StudioProxy.ScoreVectorSubmittedForWorker.handler(
  async ({ event, context }) => {
    const studioAddr = event.srcAddress.toLowerCase();
    const dataHash = event.params.dataHash;
    const validatorId = event.params.validatorAgentId.toString();
    const scoreId = `${studioAddr}-${dataHash}-${validatorId}`;
    const workSubmissionId = `${studioAddr}-${dataHash}`;

    // Resolve validator address
    const validatorEntityId = `${studioAddr}-${validatorId}`;
    const validator = await context.StudioAgent.get(validatorEntityId);

    context.ScoreVector.set({
      id: scoreId,
      studio_id: studioAddr,
      workSubmission_id: workSubmissionId,
      validatorAgentId: event.params.validatorAgentId,
      validatorAddress: validator ? validator.agentAddress : undefined,
      worker: event.params.worker.toLowerCase(),
      scoreVector: event.params.scoreVector,
      timestamp: event.params.timestamp,
    });
  },
);

// ---------------------------------------------------------------------------
// RewardsDistributor handlers
// ---------------------------------------------------------------------------

RewardsDistributor.EpochClosed.handler(async ({ event, context }) => {
  const studioAddr = event.params.studio.toLowerCase();
  const epochCloseId = `${event.transaction.hash}-${event.logIndex}`;

  context.EpochClose.set({
    id: epochCloseId,
    studio_id: studioAddr,
    epoch: event.params.epoch,
    workCount: event.params.workCount,
    validatorCount: event.params.validatorCount,
    blockTimestamp: BigInt(event.block.timestamp),
    txHash: event.transaction.hash,
  });

  // Link epoch close to studio
  const studio = await context.Studio.get(studioAddr);
  if (studio) {
    context.Studio.set({
      ...studio,
      epochClose_id: epochCloseId,
    });
  }
});
