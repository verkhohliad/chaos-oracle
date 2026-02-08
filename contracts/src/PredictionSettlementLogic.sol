// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LogicModule} from "@chaoschain/base/LogicModule.sol";
import {IChaosOracleSettleable} from "./interfaces/IChaosOracleSettleable.sol";
import {IChaosOracleRegistry} from "./interfaces/IChaosOracleRegistry.sol";

/// @title PredictionSettlementLogic
/// @notice ChaosChain LogicModule for ChaosOracle prediction market settlement.
///         Deployed once, used by many StudioProxy instances via delegatecall.
///
/// @dev Workers submit outcome predictions with evidence CIDs. Verifiers score workers.
///      On epoch close, consensus is computed via score-weighted majority voting,
///      and the prediction market is settled with the winning outcome.
///
///      Storage layout: LogicModule base storage first, then ChaosOracle-specific storage.
///      Since this runs via delegatecall from StudioProxy, all state lives in the proxy's storage.
contract PredictionSettlementLogic is LogicModule {
    // ============ ChaosOracle-Specific Storage ============
    // CRITICAL: These come AFTER LogicModule's storage slots

    /// @notice ChaosOracleRegistry address
    address public oracleRegistry;

    /// @notice Target prediction market contract
    address public predictionMarket;

    /// @notice Market ID within the prediction market contract
    uint256 public marketId;

    /// @notice The market question
    string public question;

    /// @notice The possible outcome options
    string[] public options;

    /// @notice Worker submission data
    struct WorkSubmission {
        uint8 outcome;
        string evidenceCID;
        uint256 timestamp;
    }

    /// @notice Worker address => their submission
    mapping(address => WorkSubmission) public submissions;

    /// @notice Worker address => registered flag
    mapping(address => bool) public isWorkerRegistered;

    /// @notice Verifier address => registered flag
    mapping(address => bool) public isVerifierRegistered;

    /// @notice List of registered workers
    address[] public workerList;

    /// @notice List of registered verifiers
    address[] public verifierList;

    /// @notice Verifier => Worker => scores [accuracy, evidence, diversity, reasoning]
    mapping(address => mapping(address => uint8[4])) public verifierScores;

    /// @notice Worker => number of verifiers who have scored them
    mapping(address => uint256) public scoreCount;

    /// @notice Whether the epoch has been closed
    bool public epochClosed;

    /// @notice Whether this module has been initialized
    bool public initialized;

    // ============ Constants ============

    uint256 public constant MIN_WORKERS = 3;
    uint256 public constant MIN_VERIFIERS = 2;
    uint256 public constant MIN_SCORES_PER_WORKER = 2;
    uint256 public constant WORKER_STAKE = 0.001 ether;
    uint256 public constant VERIFIER_STAKE = 0.001 ether;

    // ============ Events ============

    event WorkerRegistered(address indexed worker);
    event VerifierRegistered(address indexed verifier);
    event WorkSubmitted(address indexed worker, uint8 outcome, string evidenceCID);
    event ScoresSubmitted(address indexed verifier, address indexed worker, uint8[4] scores);
    event EpochClosed(uint8 winningOutcome, bytes32 proofHash);

    // ============ LogicModule Overrides ============

    /// @inheritdoc LogicModule
    function initialize(bytes calldata params) external override {
        require(!initialized, "PredictionSettlementLogic: already initialized");
        initialized = true;

        (
            address _registry,
            address _market,
            uint256 _marketId,
            string memory _question,
            string[] memory _options
        ) = abi.decode(params, (address, address, uint256, string, string[]));

        oracleRegistry = _registry;
        predictionMarket = _market;
        marketId = _marketId;
        question = _question;

        for (uint256 i = 0; i < _options.length; i++) {
            options.push(_options[i]);
        }
    }

    /// @inheritdoc LogicModule
    function getStudioType() external pure override returns (string memory) {
        return "prediction-settlement";
    }

    /// @inheritdoc LogicModule
    function getVersion() external pure override returns (string memory) {
        return "1.0.0";
    }

    /// @inheritdoc LogicModule
    function getScoringCriteria() external pure override returns (
        string[] memory names,
        uint16[] memory weights
    ) {
        // 5 universal PoA + 4 prediction-settlement specific = 9 dimensions
        names = new string[](9);
        weights = new uint16[](9);

        // Universal PoA dimensions (REQUIRED)
        names[0] = "Initiative";
        names[1] = "Collaboration";
        names[2] = "Reasoning Depth";
        names[3] = "Compliance";
        names[4] = "Efficiency";

        // ChaosOracle prediction-specific dimensions
        names[5] = "Accuracy";
        names[6] = "Evidence Quality";
        names[7] = "Source Diversity";
        names[8] = "Reasoning Depth";

        // Weights (100 = 1.0x baseline)
        weights[0] = 100;  // Initiative: 1.0x
        weights[1] = 100;  // Collaboration: 1.0x
        weights[2] = 100;  // Reasoning Depth: 1.0x
        weights[3] = 100;  // Compliance: 1.0x
        weights[4] = 100;  // Efficiency: 1.0x
        weights[5] = 200;  // Accuracy: 2.0x (MOST CRITICAL)
        weights[6] = 150;  // Evidence Quality: 1.5x
        weights[7] = 120;  // Source Diversity: 1.2x
        weights[8] = 130;  // Reasoning Depth: 1.3x
    }

    // ============ Domain Functions ============

    /// @notice Register as a worker agent for this settlement studio
    /// @dev Requires WORKER_STAKE in msg.value
    function registerAsWorker() external payable {
        require(!epochClosed, "PredictionSettlementLogic: epoch closed");
        require(!isWorkerRegistered[msg.sender], "PredictionSettlementLogic: already registered");
        require(msg.value >= WORKER_STAKE, "PredictionSettlementLogic: insufficient stake");

        isWorkerRegistered[msg.sender] = true;
        workerList.push(msg.sender);

        // Record stake in escrow (LogicModule base)
        _addEscrow(msg.sender, msg.value);

        emit WorkerRegistered(msg.sender);
        emit LogicExecuted("registerAsWorker", msg.sender, "");
    }

    /// @notice Register as a verifier agent for this settlement studio
    /// @dev Requires VERIFIER_STAKE in msg.value
    function registerAsVerifier() external payable {
        require(!epochClosed, "PredictionSettlementLogic: epoch closed");
        require(!isVerifierRegistered[msg.sender], "PredictionSettlementLogic: already registered");
        require(!isWorkerRegistered[msg.sender], "PredictionSettlementLogic: workers cannot verify");
        require(msg.value >= VERIFIER_STAKE, "PredictionSettlementLogic: insufficient stake");

        isVerifierRegistered[msg.sender] = true;
        verifierList.push(msg.sender);

        _addEscrow(msg.sender, msg.value);

        emit VerifierRegistered(msg.sender);
        emit LogicExecuted("registerAsVerifier", msg.sender, "");
    }

    /// @notice Submit a work outcome prediction with evidence
    /// @param outcome The predicted outcome index (0-based, matching options array)
    /// @param evidenceCID The IPFS/Arweave CID pointing to evidence package
    function submitWork(uint8 outcome, string calldata evidenceCID) external {
        require(!epochClosed, "PredictionSettlementLogic: epoch closed");
        require(isWorkerRegistered[msg.sender], "PredictionSettlementLogic: not registered worker");
        require(submissions[msg.sender].timestamp == 0, "PredictionSettlementLogic: already submitted");
        require(outcome < options.length, "PredictionSettlementLogic: invalid outcome");
        require(bytes(evidenceCID).length > 0, "PredictionSettlementLogic: empty evidence");

        submissions[msg.sender] = WorkSubmission({
            outcome: outcome,
            evidenceCID: evidenceCID,
            timestamp: block.timestamp
        });

        // Also record in StudioProxy's work tracking via LogicModule base
        bytes32 dataHash = keccak256(abi.encodePacked(msg.sender, outcome, evidenceCID));
        _recordWork(dataHash, msg.sender);

        emit WorkSubmitted(msg.sender, outcome, evidenceCID);
        emit LogicExecuted("submitWork", msg.sender, abi.encode(outcome));
    }

    /// @notice Verifier submits scores for a worker's submission
    /// @param worker The worker address being scored
    /// @param scores [accuracy, evidenceQuality, sourceDiversity, reasoningDepth] each 0-100
    function submitScores(address worker, uint8[4] calldata scores) external {
        require(!epochClosed, "PredictionSettlementLogic: epoch closed");
        require(isVerifierRegistered[msg.sender], "PredictionSettlementLogic: not registered verifier");
        require(submissions[worker].timestamp > 0, "PredictionSettlementLogic: worker has no submission");
        require(verifierScores[msg.sender][worker][0] == 0 && verifierScores[msg.sender][worker][1] == 0,
            "PredictionSettlementLogic: already scored");

        // Validate score ranges
        for (uint256 i = 0; i < 4; i++) {
            require(scores[i] <= 100, "PredictionSettlementLogic: score > 100");
        }

        verifierScores[msg.sender][worker] = scores;
        scoreCount[worker]++;

        // Record in StudioProxy's score tracking
        bytes32 dataHash = keccak256(abi.encodePacked(worker, submissions[worker].outcome, submissions[worker].evidenceCID));
        _recordScoreVector(dataHash, msg.sender, abi.encode(scores));

        emit ScoresSubmitted(msg.sender, worker, scores);

        // Notify the registry about score progress
        IChaosOracleRegistry(oracleRegistry).onScoresSubmitted(
            workerList.length,
            _totalScoreCount()
        );
    }

    /// @notice Close the epoch, compute consensus, and settle the prediction market
    /// @dev Only callable by the ChaosOracleRegistry
    function closeEpoch() external {
        require(msg.sender == oracleRegistry, "PredictionSettlementLogic: only registry");
        require(!epochClosed, "PredictionSettlementLogic: already closed");
        require(_canCloseInternal(), "PredictionSettlementLogic: thresholds not met");

        epochClosed = true;

        // Compute consensus via score-weighted majority voting
        (uint8 winningOutcome, bytes32 proofHash) = _computeConsensus();

        // Settle the prediction market
        IChaosOracleSettleable(predictionMarket).onSettlement(marketId, winningOutcome, proofHash);

        // Notify registry
        IChaosOracleRegistry(oracleRegistry).onStudioSettled(winningOutcome, proofHash);

        emit EpochClosed(winningOutcome, proofHash);
        emit LogicExecuted("closeEpoch", msg.sender, abi.encode(winningOutcome, proofHash));
    }

    /// @notice Check if the studio meets minimum thresholds to close
    /// @return ready True if minimums are met
    function canClose() external view returns (bool ready) {
        return _canCloseInternal();
    }

    // ============ View Helpers ============

    /// @notice Get the number of registered workers
    function getWorkerCount() external view returns (uint256) {
        return workerList.length;
    }

    /// @notice Get the number of registered verifiers
    function getVerifierCount() external view returns (uint256) {
        return verifierList.length;
    }

    /// @notice Get the number of outcome options
    function getOptionCount() external view returns (uint256) {
        return options.length;
    }

    /// @notice Get a specific option string
    function getOption(uint256 index) external view returns (string memory) {
        return options[index];
    }

    // ============ Internal ============

    function _canCloseInternal() internal view returns (bool) {
        if (epochClosed) return false;
        if (workerList.length < MIN_WORKERS) return false;
        if (verifierList.length < MIN_VERIFIERS) return false;

        // Check that enough workers have been scored
        uint256 sufficientlyScored = 0;
        for (uint256 i = 0; i < workerList.length; i++) {
            if (submissions[workerList[i]].timestamp > 0 && scoreCount[workerList[i]] >= MIN_SCORES_PER_WORKER) {
                sufficientlyScored++;
            }
        }
        return sufficientlyScored >= MIN_WORKERS;
    }

    /// @dev Score-weighted majority voting:
    ///      1. For each outcome, sum the average verifier scores of workers who chose it
    ///      2. Highest total weight wins
    ///      3. proofHash = keccak256(concatenated evidence CIDs)
    function _computeConsensus() internal view returns (uint8 winningOutcome, bytes32 proofHash) {
        uint256 optCount = options.length;
        uint256[] memory outcomeWeights = new uint256[](optCount);

        // Accumulate evidence CIDs for proof hash
        bytes memory allEvidence;

        for (uint256 i = 0; i < workerList.length; i++) {
            address worker = workerList[i];
            WorkSubmission storage sub = submissions[worker];

            // Skip workers who haven't submitted or haven't been scored enough
            if (sub.timestamp == 0 || scoreCount[worker] < MIN_SCORES_PER_WORKER) continue;

            // Calculate average score across all verifiers for this worker
            uint256 totalScore = 0;
            uint256 numScorers = 0;
            for (uint256 j = 0; j < verifierList.length; j++) {
                address verifier = verifierList[j];
                uint8[4] storage vs = verifierScores[verifier][worker];
                // Check if this verifier scored this worker (any non-zero dimension)
                if (vs[0] > 0 || vs[1] > 0 || vs[2] > 0 || vs[3] > 0) {
                    // Average of 4 dimensions
                    totalScore += uint256(vs[0]) + uint256(vs[1]) + uint256(vs[2]) + uint256(vs[3]);
                    numScorers++;
                }
            }

            if (numScorers == 0) continue;

            // Average score for this worker (0-400 range / numScorers)
            uint256 avgScore = totalScore / numScorers;

            // Add to the weight of the outcome this worker chose
            outcomeWeights[sub.outcome] += avgScore;

            // Accumulate evidence for proof
            allEvidence = abi.encodePacked(allEvidence, sub.evidenceCID);
        }

        // Find winning outcome (highest weight)
        uint256 maxWeight = 0;
        for (uint256 i = 0; i < optCount; i++) {
            if (outcomeWeights[i] > maxWeight) {
                maxWeight = outcomeWeights[i];
                winningOutcome = uint8(i);
            }
        }

        proofHash = keccak256(allEvidence);
    }

    /// @dev Count total individual verifier-worker score entries
    function _totalScoreCount() internal view returns (uint256 total) {
        for (uint256 i = 0; i < workerList.length; i++) {
            total += scoreCount[workerList[i]];
        }
    }
}
