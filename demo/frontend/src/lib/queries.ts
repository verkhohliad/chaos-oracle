export const MARKETS_QUERY = `
  query Markets($limit: Int, $offset: Int) {
    Market(limit: $limit, offset: $offset, order_by: { createdAtTimestamp: desc }) {
      id
      marketId
      question
      deadline
      yesPool
      noPool
      outcome
      settled
      createdAtTimestamp
      studio {
        id
        settled
      }
    }
  }
`;

export const MARKET_DETAIL_QUERY = `
  query MarketDetail($id: String!) {
    Market_by_pk(id: $id) {
      id
      marketId
      creator
      question
      options
      deadline
      yesPool
      noPool
      outcome
      proofHash
      settled
      settlementReward
      registryKey
      createdAtTimestamp
      bets(order_by: { blockTimestamp: desc }) {
        id
        bettor
        option
        amount
        blockTimestamp
      }
      claims {
        id
        claimer
        amount
        blockTimestamp
      }
      studio {
        id
        studioId
        settled
        outcome
        proofHash
        createdAtTimestamp
        settledAtTimestamp
        agents(order_by: { role: asc, agentId: asc }) {
          id
          agentId
          agentAddress
          role
          stake
          blockTimestamp
        }
        workSubmissions(order_by: { timestamp: asc }) {
          id
          agentId
          agentAddress
          dataHash
          threadRoot
          evidenceRoot
          timestamp
          scoreVectors(order_by: { validatorAgentId: asc }) {
            id
            validatorAgentId
            validatorAddress
            worker
            scoreVector
            timestamp
          }
        }
        epochClose {
          id
          epoch
          workCount
          validatorCount
          blockTimestamp
          txHash
        }
      }
    }
  }
`;

// ============ Agent Queries ============

export const AGENTS_QUERY = `
  query Agents($limit: Int, $offset: Int) {
    StudioAgent(
      limit: $limit,
      offset: $offset,
      order_by: { blockTimestamp: desc }
    ) {
      id
      agentId
      agentAddress
      role
      stake
      blockTimestamp
      studio_id
    }
  }
`;

export const AGENT_DETAIL_QUERY = `
  query AgentDetail($agentAddress: String!) {
    StudioAgent(
      where: { agentAddress: { _eq: $agentAddress } }
      order_by: { blockTimestamp: desc }
    ) {
      id
      agentId
      agentAddress
      role
      stake
      blockTimestamp
      studio_id
    }
    WorkSubmission(
      where: { agentAddress: { _eq: $agentAddress } }
      order_by: { timestamp: desc }
    ) {
      id
      agentId
      agentAddress
      dataHash
      threadRoot
      evidenceRoot
      timestamp
      scoreVectors {
        id
        validatorAgentId
        validatorAddress
        scoreVector
        timestamp
      }
    }
    ScoreVector(
      where: { validatorAddress: { _eq: $agentAddress } }
      order_by: { timestamp: desc }
    ) {
      id
      validatorAgentId
      validatorAddress
      worker
      scoreVector
      timestamp
    }
  }
`;
