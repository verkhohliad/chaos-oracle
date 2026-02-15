// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IMockStudioProxy
/// @notice Interface for the subset of MockStudioProxy functions used by MockRewardsDistributor
interface IMockStudioProxy {
    function getTotalEscrow() external view returns (uint256);
    function getWorkParticipants(bytes32 dataHash) external view returns (address[] memory);
    function getContributionWeight(bytes32 dataHash, address participant) external view returns (uint16);
    function getScoreVectorsForWorker(bytes32 dataHash, address worker) external view returns (address[] memory validators, bytes[] memory vectors);
    function getValidators(bytes32 dataHash) external view returns (address[] memory);
    function releaseFunds(address to, uint256 amount, bytes32 dataHash) external;
    function getAgentId(address agent) external view returns (uint256);
}

/// @title MockRewardsDistributor
/// @notice Simplified mock implementing the core closeEpoch flow with budget split.
///         Uses simple average consensus (real one uses MAD-based — tested in ScoringLibrary.t.sol).
/// @dev Budget split: 5% orchestrator, 10% validator, 85% worker
contract MockRewardsDistributor {
    // ============ Constants ============

    uint256 public constant ORCHESTRATOR_BPS = 500;   // 5%
    uint256 public constant VALIDATOR_BPS = 1000;      // 10%
    uint256 public constant WORKER_BPS = 8500;         // 85%
    uint256 public constant BPS_DENOMINATOR = 10000;

    // ============ Structs ============

    struct ConsensusResult {
        bytes32 dataHash;
        uint8[] consensusScores;
        uint256 totalStake;
        uint256 validatorCount;
        uint256 timestamp;
        bool finalized;
    }

    struct EpochWork {
        bytes32[] dataHashes;
        bool closed;
    }

    // ============ Events ============

    event EpochClosed(address indexed studio, uint64 indexed epoch, uint256 workCount, uint256 validatorCount);
    event ConsensusReached(bytes32 indexed dataHash, uint8[] consensusScores, uint256 totalStake);
    event WorkerRewarded(address indexed studio, uint256 indexed agentId, bytes32 indexed dataHash, uint256 amount);
    event ValidatorRewarded(uint256 indexed validatorAgentId, bytes32 indexed dataHash, uint256 reward, uint256 performanceScore);

    // ============ State ============

    address public owner;
    address public orchestrator;

    /// @dev studio => epoch => EpochWork
    mapping(address => mapping(uint64 => EpochWork)) public epochWorks;

    /// @dev dataHash => ConsensusResult
    mapping(bytes32 => ConsensusResult) public consensusResults;

    /// @dev Track total released per closeEpoch call (for assertions)
    uint256 public lastTotalReleased;

    /// @dev Track individual releases for test assertions
    mapping(address => uint256) public lastReleasedTo;

    // ============ Constructor ============

    constructor(address _orchestrator) {
        owner = msg.sender;
        orchestrator = _orchestrator;
    }

    // ============ Registration ============

    /// @notice Register work for an epoch
    function registerWork(address studio, uint64 epoch, bytes32 dataHash) external {
        epochWorks[studio][epoch].dataHashes.push(dataHash);
    }

    // ============ Core: closeEpoch ============

    /// @notice Close an epoch and distribute rewards based on budget split.
    /// @dev Simplified flow:
    ///      1. Get totalBudget from studio escrow
    ///      2. Split: 5% orchestrator, 10% validators, 85% workers
    ///      3. For each work: compute simple consensus, distribute rewards
    function closeEpoch(address studio, uint64 epoch) external {
        EpochWork storage ew = epochWorks[studio][epoch];
        require(!ew.closed, "Epoch already closed");
        require(ew.dataHashes.length > 0, "No work in epoch");

        ew.closed = true;

        IMockStudioProxy proxy = IMockStudioProxy(studio);
        uint256 totalBudget = proxy.getTotalEscrow();
        require(totalBudget > 0, "No budget");

        uint256 orchestratorShare = (totalBudget * ORCHESTRATOR_BPS) / BPS_DENOMINATOR;
        uint256 validatorPool = (totalBudget * VALIDATOR_BPS) / BPS_DENOMINATOR;
        uint256 workerPool = (totalBudget * WORKER_BPS) / BPS_DENOMINATOR;

        uint256 totalReleased = 0;

        // Pay orchestrator
        if (orchestrator != address(0)) {
            proxy.releaseFunds(orchestrator, orchestratorShare, bytes32(0));
            lastReleasedTo[orchestrator] += orchestratorShare;
            totalReleased += orchestratorShare;
        }

        // Process each work submission
        uint256 workCount = ew.dataHashes.length;
        uint256 workerPoolPerWork = workerPool / workCount;
        uint256 validatorPoolPerWork = validatorPool / workCount;
        uint256 totalValidatorCount = 0;

        for (uint256 w = 0; w < workCount; w++) {
            bytes32 dataHash = ew.dataHashes[w];

            // ---- Consensus ----
            address[] memory participants = proxy.getWorkParticipants(dataHash);
            require(participants.length > 0, "No participants for work");

            // Compute consensus for primary worker (simplified: average of validator scores)
            address primaryWorker = participants[0];
            (address[] memory validators, bytes[] memory vectors) = proxy.getScoreVectorsForWorker(dataHash, primaryWorker);

            uint8[] memory consensus;
            if (validators.length > 0) {
                consensus = _calculateSimpleConsensus(vectors);
                totalValidatorCount += validators.length;
            } else {
                // No validators: default perfect scores (100 on each dimension)
                consensus = new uint8[](1);
                consensus[0] = 100;
            }

            consensusResults[dataHash] = ConsensusResult({
                dataHash: dataHash,
                consensusScores: consensus,
                totalStake: validators.length * 1 ether, // Simplified: equal stake
                validatorCount: validators.length,
                timestamp: block.timestamp,
                finalized: true
            });

            emit ConsensusReached(dataHash, consensus, validators.length * 1 ether);

            // ---- Worker Rewards ----
            // Quality scalar = average consensus score / 100 (normalize to [0, 1] in BPS)
            uint256 qualityBps = _averageScore(consensus) * 100; // score 0-100 → 0-10000 bps
            uint256 effectiveWorkerPool = (workerPoolPerWork * qualityBps) / BPS_DENOMINATOR;

            for (uint256 p = 0; p < participants.length; p++) {
                uint16 weight = proxy.getContributionWeight(dataHash, participants[p]);
                uint256 workerReward = (effectiveWorkerPool * uint256(weight)) / BPS_DENOMINATOR;

                if (workerReward > 0) {
                    proxy.releaseFunds(participants[p], workerReward, dataHash);
                    lastReleasedTo[participants[p]] += workerReward;
                    totalReleased += workerReward;

                    uint256 agentId = proxy.getAgentId(participants[p]);
                    emit WorkerRewarded(studio, agentId, dataHash, workerReward);
                }
            }

            // ---- Validator Rewards ----
            if (validators.length > 0) {
                _distributeValidatorRewards(
                    proxy, studio, dataHash, validators, vectors, consensus, validatorPoolPerWork
                );
                // Count total released for validators
                for (uint256 v = 0; v < validators.length; v++) {
                    // Already tracked in _distributeValidatorRewards via lastReleasedTo
                }
            }
        }

        // Note: totalReleased might not include validator rewards counted separately
        lastTotalReleased = totalReleased;

        emit EpochClosed(studio, epoch, workCount, totalValidatorCount);
    }

    // ============ Internal ============

    /// @dev Simple consensus: average of validator scores per dimension
    function _calculateSimpleConsensus(bytes[] memory vectors) internal pure returns (uint8[] memory consensus) {
        require(vectors.length > 0, "No vectors");

        // Decode first vector to get dimension count
        uint8[] memory first = _decodeScoreVector(vectors[0]);
        uint256 dims = first.length;

        uint256[] memory sums = new uint256[](dims);
        for (uint256 v = 0; v < vectors.length; v++) {
            uint8[] memory scores = _decodeScoreVector(vectors[v]);
            require(scores.length == dims, "Dimension mismatch");
            for (uint256 d = 0; d < dims; d++) {
                sums[d] += uint256(scores[d]);
            }
        }

        consensus = new uint8[](dims);
        for (uint256 d = 0; d < dims; d++) {
            consensus[d] = uint8(sums[d] / vectors.length);
        }
    }

    /// @dev Decode a bytes score vector into uint8 array
    function _decodeScoreVector(bytes memory data) internal pure returns (uint8[] memory scores) {
        scores = new uint8[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            scores[i] = uint8(data[i]);
        }
    }

    /// @dev Average of uint8 array scores
    function _averageScore(uint8[] memory scores) internal pure returns (uint256) {
        if (scores.length == 0) return 0;
        uint256 sum = 0;
        for (uint256 i = 0; i < scores.length; i++) {
            sum += uint256(scores[i]);
        }
        return sum / scores.length;
    }

    /// @dev Distribute validator rewards inversely proportional to error from consensus
    function _distributeValidatorRewards(
        IMockStudioProxy proxy,
        address studio,
        bytes32 dataHash,
        address[] memory validators,
        bytes[] memory vectors,
        uint8[] memory consensus,
        uint256 validatorPoolForWork
    ) internal {
        uint256 n = validators.length;

        // Calculate error for each validator
        uint256[] memory errors = new uint256[](n);
        uint256 totalInverseError = 0;

        for (uint256 v = 0; v < n; v++) {
            uint8[] memory scores = _decodeScoreVector(vectors[v]);
            uint256 err = 0;
            for (uint256 d = 0; d < consensus.length; d++) {
                uint256 diff = scores[d] > consensus[d]
                    ? uint256(scores[d]) - uint256(consensus[d])
                    : uint256(consensus[d]) - uint256(scores[d]);
                err += diff;
            }
            errors[v] = err;
            // Inverse error: max possible error per dimension is 100, so use (100 * dims + 1) - error
            uint256 maxError = 100 * consensus.length;
            totalInverseError += (maxError + 1) - err;
        }

        // Distribute proportionally to inverse error
        for (uint256 v = 0; v < n; v++) {
            uint256 maxError = 100 * consensus.length;
            uint256 inverseError = (maxError + 1) - errors[v];
            uint256 validatorReward = (validatorPoolForWork * inverseError) / totalInverseError;

            if (validatorReward > 0) {
                proxy.releaseFunds(validators[v], validatorReward, dataHash);
                lastReleasedTo[validators[v]] += validatorReward;
                lastTotalReleased += validatorReward;

                uint256 agentId = proxy.getAgentId(validators[v]);
                uint256 performance = (inverseError * BPS_DENOMINATOR) / (maxError + 1);
                emit ValidatorRewarded(agentId, dataHash, validatorReward, performance);
            }
        }
    }

    // ============ View Functions ============

    /// @notice Get consensus result for a work submission
    function getConsensusResult(bytes32 dataHash) external view returns (ConsensusResult memory) {
        return consensusResults[dataHash];
    }

    /// @notice Get work hashes registered for an epoch
    function getEpochWorkHashes(address studio, uint64 epoch) external view returns (bytes32[] memory) {
        return epochWorks[studio][epoch].dataHashes;
    }

    /// @notice Check if an epoch was closed
    function isEpochClosed(address studio, uint64 epoch) external view returns (bool) {
        return epochWorks[studio][epoch].closed;
    }
}
