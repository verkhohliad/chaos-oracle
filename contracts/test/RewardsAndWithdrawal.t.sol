// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChaosOracleRegistry} from "../src/ChaosOracleRegistry.sol";
import {PredictionSettlementLogic} from "../src/PredictionSettlementLogic.sol";
import {ExamplePredictionMarket} from "../src/example/ExamplePredictionMarket.sol";
import {MockChaosCore, MockStudioProxyFactory, MockStudioProxy} from "./mocks/MockChaosCore.sol";
import {MockRewardsDistributor} from "./mocks/MockRewardsDistributor.sol";
import {MarketKey} from "../src/libraries/MarketKey.sol";

/// @title RewardsAndWithdrawalTest
/// @notice Comprehensive tests for consensus computation, budget split, reward distribution,
///         and the releaseFunds -> withdraw flow.
contract RewardsAndWithdrawalTest is Test {
    using MarketKey for address;

    // ============ Contracts ============
    ChaosOracleRegistry registry;
    MockChaosCore chaosCore;
    MockStudioProxyFactory proxyFactory;
    PredictionSettlementLogic logic;
    ExamplePredictionMarket market;
    MockRewardsDistributor rewardsDistributor;

    address creForwarder = address(0xC4E);
    address chaosChainRegistry = address(0xCC1);
    address orchestrator = address(0x04C);

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    // Agent addresses
    address worker1;
    address worker2;
    address verifier1;
    address verifier2;
    address verifier3;

    // Studio proxy deployed during setup
    MockStudioProxy studioProxy;
    bytes32 workDataHash;
    uint64 constant EPOCH = 0;

    function setUp() public {
        worker1 = makeAddr("worker1");
        worker2 = makeAddr("worker2");
        verifier1 = makeAddr("verifier1");
        verifier2 = makeAddr("verifier2");
        verifier3 = makeAddr("verifier3");

        chaosCore = new MockChaosCore();
        proxyFactory = new MockStudioProxyFactory();
        logic = new PredictionSettlementLogic();
        rewardsDistributor = new MockRewardsDistributor(orchestrator);

        registry = new ChaosOracleRegistry(
            address(chaosCore), address(logic), creForwarder,
            address(proxyFactory), chaosChainRegistry, address(rewardsDistributor)
        );

        market = new ExamplePredictionMarket(address(registry));

        // Fund accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(worker1, 10 ether);
        vm.deal(worker2, 10 ether);
        vm.deal(verifier1, 10 ether);
        vm.deal(verifier2, 10 ether);
        vm.deal(verifier3, 10 ether);
    }

    // ============ Helpers ============

    /// @dev Helper: create a market, bet, warp past deadline, create studio, and return the proxy
    function _createStudioWithFunds(uint256 fundAmount) internal returns (MockStudioProxy proxy, bytes32 key) {
        uint256 deadline = block.timestamp + 1 days;

        vm.prank(alice);
        uint256 marketId = market.createMarket{value: fundAmount}("Test?", deadline);

        vm.prank(bob);
        market.placeBet{value: 5 ether}(marketId, 0);

        vm.warp(deadline + 1);

        key = address(market).derive(marketId);
        bytes memory creReport = abi.encode(bytes32(0));
        vm.prank(creForwarder);
        registry.createStudioForMarket(key, creReport);

        proxy = MockStudioProxy(payable(registry.keyToStudio(key)));
    }

    /// @dev Helper: register agents, submit work, submit scores for a single worker
    function _setupSingleWorkerWithScores(
        MockStudioProxy proxy,
        bytes memory v1Scores,
        bytes memory v2Scores
    ) internal returns (bytes32 dataHash) {
        dataHash = keccak256("work-data-1");

        // Register agents
        vm.prank(worker1);
        proxy.registerAgent(101, 1); // worker

        vm.prank(verifier1);
        proxy.registerAgent(201, 2); // verifier

        vm.prank(verifier2);
        proxy.registerAgent(202, 2); // verifier

        // Submit work
        vm.prank(worker1);
        proxy.submitWork(dataHash, bytes32(0), bytes32(0), "");

        // Submit scores
        vm.prank(verifier1);
        proxy.submitScoreVector(dataHash, v1Scores);

        vm.prank(verifier2);
        proxy.submitScoreVector(dataHash, v2Scores);
    }

    // ============ Consensus Tests ============

    function test_consensus_unanimousValidators() public {
        (MockStudioProxy proxy,) = _createStudioWithFunds(10 ether);

        // Both validators give identical scores: [80, 90, 70]
        bytes memory scores = abi.encodePacked(uint8(80), uint8(90), uint8(70));
        bytes32 dataHash = _setupSingleWorkerWithScores(proxy, scores, scores);

        // Register work and close epoch
        rewardsDistributor.registerWork(address(proxy), EPOCH, dataHash);
        rewardsDistributor.closeEpoch(address(proxy), EPOCH);

        // Get consensus result
        MockRewardsDistributor.ConsensusResult memory result = rewardsDistributor.getConsensusResult(dataHash);

        assertTrue(result.finalized, "Consensus should be finalized");
        assertEq(result.consensusScores.length, 3, "Should have 3 dimensions");
        assertEq(result.consensusScores[0], 80, "Dimension 0 consensus should be 80");
        assertEq(result.consensusScores[1], 90, "Dimension 1 consensus should be 90");
        assertEq(result.consensusScores[2], 70, "Dimension 2 consensus should be 70");
    }

    function test_consensus_divergentValidators() public {
        (MockStudioProxy proxy,) = _createStudioWithFunds(10 ether);

        bytes32 dataHash = keccak256("work-divergent");

        // Register 3 validators with different scores
        vm.prank(worker1);
        proxy.registerAgent(101, 1);
        vm.prank(verifier1);
        proxy.registerAgent(201, 2);
        vm.prank(verifier2);
        proxy.registerAgent(202, 2);
        vm.prank(verifier3);
        proxy.registerAgent(203, 2);

        // Submit work
        vm.prank(worker1);
        proxy.submitWork(dataHash, bytes32(0), bytes32(0), "");

        // Validator 1: [80, 60]
        vm.prank(verifier1);
        proxy.submitScoreVector(dataHash, abi.encodePacked(uint8(80), uint8(60)));

        // Validator 2: [70, 90]
        vm.prank(verifier2);
        proxy.submitScoreVector(dataHash, abi.encodePacked(uint8(70), uint8(90)));

        // Validator 3: [90, 75]
        vm.prank(verifier3);
        proxy.submitScoreVector(dataHash, abi.encodePacked(uint8(90), uint8(75)));

        rewardsDistributor.registerWork(address(proxy), EPOCH, dataHash);
        rewardsDistributor.closeEpoch(address(proxy), EPOCH);

        MockRewardsDistributor.ConsensusResult memory result = rewardsDistributor.getConsensusResult(dataHash);

        assertTrue(result.finalized);
        assertEq(result.validatorCount, 3);
        // Average: dim0 = (80+70+90)/3 = 80, dim1 = (60+90+75)/3 = 75
        assertEq(result.consensusScores[0], 80, "Dim 0 avg should be 80");
        assertEq(result.consensusScores[1], 75, "Dim 1 avg should be 75");
    }

    function test_consensus_resultStoredAndQueryable() public {
        (MockStudioProxy proxy,) = _createStudioWithFunds(10 ether);

        bytes memory scores = abi.encodePacked(uint8(85));
        bytes32 dataHash = _setupSingleWorkerWithScores(proxy, scores, scores);

        rewardsDistributor.registerWork(address(proxy), EPOCH, dataHash);
        rewardsDistributor.closeEpoch(address(proxy), EPOCH);

        MockRewardsDistributor.ConsensusResult memory result = rewardsDistributor.getConsensusResult(dataHash);

        assertTrue(result.finalized, "Should be finalized");
        assertEq(result.dataHash, dataHash, "DataHash should match");
        assertTrue(result.timestamp > 0, "Timestamp should be set");
        assertEq(result.validatorCount, 2, "Should have 2 validators");
    }

    // ============ Work/Score Correctness Tests ============

    function test_workParticipants_singleWorker() public {
        (MockStudioProxy proxy,) = _createStudioWithFunds(10 ether);

        bytes32 dataHash = keccak256("single-worker-test");

        vm.prank(worker1);
        proxy.registerAgent(101, 1);

        vm.prank(worker1);
        proxy.submitWork(dataHash, bytes32(0), bytes32(0), "");

        address[] memory participants = proxy.getWorkParticipants(dataHash);
        assertEq(participants.length, 1, "Should have 1 participant");
        assertEq(participants[0], worker1, "Participant should be worker1");

        uint16 weight = proxy.getContributionWeight(dataHash, worker1);
        assertEq(weight, 10000, "Single worker should have 100% weight (10000 bps)");
    }

    function test_workParticipants_multiAgent() public {
        (MockStudioProxy proxy,) = _createStudioWithFunds(10 ether);

        bytes32 dataHash = keccak256("multi-agent-test");

        vm.prank(worker1);
        proxy.registerAgent(101, 1);
        vm.prank(worker2);
        proxy.registerAgent(102, 1);

        // Submit multi-agent work: 70/30 split
        address[] memory participants = new address[](2);
        participants[0] = worker1;
        participants[1] = worker2;
        uint16[] memory weights = new uint16[](2);
        weights[0] = 7000;
        weights[1] = 3000;

        vm.prank(worker1);
        proxy.submitWorkMultiAgent(dataHash, participants, weights);

        address[] memory storedParticipants = proxy.getWorkParticipants(dataHash);
        assertEq(storedParticipants.length, 2, "Should have 2 participants");

        uint16 w1Weight = proxy.getContributionWeight(dataHash, worker1);
        uint16 w2Weight = proxy.getContributionWeight(dataHash, worker2);
        assertEq(w1Weight, 7000, "Worker1 should have 70% weight");
        assertEq(w2Weight, 3000, "Worker2 should have 30% weight");
        assertEq(uint256(w1Weight) + uint256(w2Weight), 10000, "Weights should sum to 10000");
    }

    function test_scoreVectors_storedPerWorkerPerValidator() public {
        (MockStudioProxy proxy,) = _createStudioWithFunds(10 ether);

        bytes32 dataHash = keccak256("score-storage-test");

        vm.prank(worker1);
        proxy.registerAgent(101, 1);
        vm.prank(verifier1);
        proxy.registerAgent(201, 2);
        vm.prank(verifier2);
        proxy.registerAgent(202, 2);

        vm.prank(worker1);
        proxy.submitWork(dataHash, bytes32(0), bytes32(0), "");

        bytes memory scores1 = abi.encodePacked(uint8(80), uint8(75));
        bytes memory scores2 = abi.encodePacked(uint8(90), uint8(85));

        vm.prank(verifier1);
        proxy.submitScoreVector(dataHash, scores1);

        vm.prank(verifier2);
        proxy.submitScoreVector(dataHash, scores2);

        // Get score vectors for worker1
        (address[] memory validators, bytes[] memory vectors) = proxy.getScoreVectorsForWorker(dataHash, worker1);

        assertEq(validators.length, 2, "Should have 2 validator scores");
        assertEq(vectors.length, 2, "Should have 2 score vectors");

        // Verify stored validators
        address[] memory allValidators = proxy.getValidators(dataHash);
        assertEq(allValidators.length, 2, "Should track 2 validators");
    }

    // ============ Budget Split Tests ============

    function test_budgetSplit_workerGets85Percent() public {
        (MockStudioProxy proxy,) = _createStudioWithFunds(10 ether);

        // Perfect scores -> quality scalar = 100%
        bytes memory scores = abi.encodePacked(uint8(100));
        bytes32 dataHash = _setupSingleWorkerWithScores(proxy, scores, scores);

        rewardsDistributor.registerWork(address(proxy), EPOCH, dataHash);
        rewardsDistributor.closeEpoch(address(proxy), EPOCH);

        uint256 totalEscrow = proxy.getTotalEscrow();
        uint256 workerReward = rewardsDistributor.lastReleasedTo(worker1);

        // Worker should get 85% of escrow (with 100% quality)
        uint256 expected85Pct = (totalEscrow * 8500) / 10000;
        assertEq(workerReward, expected85Pct, "Worker should get 85% of escrow with perfect scores");
    }

    function test_budgetSplit_validatorGets10Percent() public {
        (MockStudioProxy proxy,) = _createStudioWithFunds(10 ether);

        // Both validators give same scores -> no error -> equal split of 10%
        bytes memory scores = abi.encodePacked(uint8(100));
        bytes32 dataHash = _setupSingleWorkerWithScores(proxy, scores, scores);

        rewardsDistributor.registerWork(address(proxy), EPOCH, dataHash);
        rewardsDistributor.closeEpoch(address(proxy), EPOCH);

        uint256 totalEscrow = proxy.getTotalEscrow();
        uint256 v1Reward = rewardsDistributor.lastReleasedTo(verifier1);
        uint256 v2Reward = rewardsDistributor.lastReleasedTo(verifier2);
        uint256 totalValidatorRewards = v1Reward + v2Reward;

        // Validators should split 10% of escrow
        uint256 expected10Pct = (totalEscrow * 1000) / 10000;
        assertEq(totalValidatorRewards, expected10Pct, "Validators should share 10% of escrow");
        assertEq(v1Reward, v2Reward, "Equal scores -> equal rewards");
    }

    function test_budgetSplit_totalDoesNotExceedEscrow() public {
        (MockStudioProxy proxy,) = _createStudioWithFunds(10 ether);

        bytes memory scores = abi.encodePacked(uint8(80));
        bytes32 dataHash = _setupSingleWorkerWithScores(proxy, scores, scores);

        rewardsDistributor.registerWork(address(proxy), EPOCH, dataHash);
        rewardsDistributor.closeEpoch(address(proxy), EPOCH);

        uint256 totalEscrow = proxy.getTotalEscrow();

        // Sum all releases
        uint256 orchestratorReward = rewardsDistributor.lastReleasedTo(orchestrator);
        uint256 workerReward = rewardsDistributor.lastReleasedTo(worker1);
        uint256 v1Reward = rewardsDistributor.lastReleasedTo(verifier1);
        uint256 v2Reward = rewardsDistributor.lastReleasedTo(verifier2);

        uint256 totalReleased = orchestratorReward + workerReward + v1Reward + v2Reward;

        assertLe(totalReleased, totalEscrow, "Total released must not exceed escrow");
        assertTrue(orchestratorReward > 0, "Orchestrator should receive something");
    }

    // ============ Worker Reward Distribution Tests ============

    function test_workerRewards_singleWorkerGetsFullPool() public {
        (MockStudioProxy proxy,) = _createStudioWithFunds(10 ether);

        bytes memory scores = abi.encodePacked(uint8(100));
        bytes32 dataHash = _setupSingleWorkerWithScores(proxy, scores, scores);

        rewardsDistributor.registerWork(address(proxy), EPOCH, dataHash);
        rewardsDistributor.closeEpoch(address(proxy), EPOCH);

        uint256 totalEscrow = proxy.getTotalEscrow();
        uint256 workerReward = rewardsDistributor.lastReleasedTo(worker1);

        // With perfect scores and 100% weight, worker gets entire 85% pool
        assertEq(workerReward, (totalEscrow * 8500) / 10000, "Single worker gets full 85% pool");
    }

    function test_workerRewards_proportionalToScores() public {
        // This test verifies quality scalar affects reward amount
        // Worker with score 50 should get half the reward of worker with score 100

        // Test 1: Perfect scores (100)
        (MockStudioProxy proxy1,) = _createStudioWithFunds(10 ether);
        bytes memory perfectScores = abi.encodePacked(uint8(100));
        bytes32 dh1 = _setupSingleWorkerWithScores(proxy1, perfectScores, perfectScores);
        rewardsDistributor.registerWork(address(proxy1), EPOCH, dh1);
        rewardsDistributor.closeEpoch(address(proxy1), EPOCH);
        uint256 perfectReward = rewardsDistributor.lastReleasedTo(worker1);

        // Test 2: Half scores (50) — need a fresh setup
        // We create a new RD to reset lastReleasedTo tracking
        MockRewardsDistributor rd2 = new MockRewardsDistributor(orchestrator);
        (MockStudioProxy proxy2,) = _createStudioWithFunds(10 ether);
        bytes memory halfScores = abi.encodePacked(uint8(50));

        bytes32 dh2 = keccak256("work-data-1");
        vm.prank(worker1);
        proxy2.registerAgent(101, 1);
        vm.prank(verifier1);
        proxy2.registerAgent(201, 2);
        vm.prank(verifier2);
        proxy2.registerAgent(202, 2);
        vm.prank(worker1);
        proxy2.submitWork(dh2, bytes32(0), bytes32(0), "");
        vm.prank(verifier1);
        proxy2.submitScoreVector(dh2, halfScores);
        vm.prank(verifier2);
        proxy2.submitScoreVector(dh2, halfScores);

        rd2.registerWork(address(proxy2), EPOCH, dh2);
        rd2.closeEpoch(address(proxy2), EPOCH);
        uint256 halfReward = rd2.lastReleasedTo(worker1);

        // Half scores -> half the effective pool -> half the reward
        assertEq(halfReward * 2, perfectReward, "Score 50 should give half the reward of score 100");
    }

    function test_workerRewards_equalScoresEqualRewards() public {
        (MockStudioProxy proxy,) = _createStudioWithFunds(10 ether);

        bytes32 dataHash = keccak256("equal-workers");

        vm.prank(worker1);
        proxy.registerAgent(101, 1);
        vm.prank(worker2);
        proxy.registerAgent(102, 1);
        vm.prank(verifier1);
        proxy.registerAgent(201, 2);

        // Two workers with equal 50/50 weights
        address[] memory participants = new address[](2);
        participants[0] = worker1;
        participants[1] = worker2;
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5000;
        weights[1] = 5000;

        vm.prank(worker1);
        proxy.submitWorkMultiAgent(dataHash, participants, weights);

        // Score from verifier
        bytes memory scores = abi.encodePacked(uint8(80));
        vm.prank(verifier1);
        proxy.submitScoreVector(dataHash, scores);

        rewardsDistributor.registerWork(address(proxy), EPOCH, dataHash);
        rewardsDistributor.closeEpoch(address(proxy), EPOCH);

        uint256 w1Reward = rewardsDistributor.lastReleasedTo(worker1);
        uint256 w2Reward = rewardsDistributor.lastReleasedTo(worker2);

        assertEq(w1Reward, w2Reward, "Equal weights -> equal rewards");
        assertTrue(w1Reward > 0, "Rewards should be non-zero");
    }

    function test_workerRewards_proportionalToContributionWeights() public {
        (MockStudioProxy proxy,) = _createStudioWithFunds(10 ether);

        bytes32 dataHash = keccak256("weighted-workers");

        vm.prank(worker1);
        proxy.registerAgent(101, 1);
        vm.prank(worker2);
        proxy.registerAgent(102, 1);
        vm.prank(verifier1);
        proxy.registerAgent(201, 2);

        // 70/30 weight split
        address[] memory participants = new address[](2);
        participants[0] = worker1;
        participants[1] = worker2;
        uint16[] memory weights = new uint16[](2);
        weights[0] = 7000;
        weights[1] = 3000;

        vm.prank(worker1);
        proxy.submitWorkMultiAgent(dataHash, participants, weights);

        bytes memory scores = abi.encodePacked(uint8(100));
        vm.prank(verifier1);
        proxy.submitScoreVector(dataHash, scores);

        rewardsDistributor.registerWork(address(proxy), EPOCH, dataHash);
        rewardsDistributor.closeEpoch(address(proxy), EPOCH);

        uint256 w1Reward = rewardsDistributor.lastReleasedTo(worker1);
        uint256 w2Reward = rewardsDistributor.lastReleasedTo(worker2);

        // Ratio should be 7:3
        // Using approximate comparison due to integer division
        assertApproxEqRel(
            w1Reward * 3,
            w2Reward * 7,
            0.01e18, // 1% tolerance
            "Worker1 (70%) should get ~2.33x more than Worker2 (30%)"
        );
    }

    // ============ Validator Reward Distribution Tests ============

    function test_validatorRewards_singleValidatorGetsFullPool() public {
        (MockStudioProxy proxy,) = _createStudioWithFunds(10 ether);

        bytes32 dataHash = keccak256("single-validator");

        vm.prank(worker1);
        proxy.registerAgent(101, 1);
        vm.prank(verifier1);
        proxy.registerAgent(201, 2);

        vm.prank(worker1);
        proxy.submitWork(dataHash, bytes32(0), bytes32(0), "");

        bytes memory scores = abi.encodePacked(uint8(80));
        vm.prank(verifier1);
        proxy.submitScoreVector(dataHash, scores);

        rewardsDistributor.registerWork(address(proxy), EPOCH, dataHash);
        rewardsDistributor.closeEpoch(address(proxy), EPOCH);

        uint256 totalEscrow = proxy.getTotalEscrow();
        uint256 v1Reward = rewardsDistributor.lastReleasedTo(verifier1);

        // Single validator gets entire 10% pool
        assertEq(v1Reward, (totalEscrow * 1000) / 10000, "Single validator gets full 10% pool");
    }

    function test_validatorRewards_accurateValidatorGetsMore() public {
        (MockStudioProxy proxy,) = _createStudioWithFunds(10 ether);

        bytes32 dataHash = keccak256("accurate-validator");

        vm.prank(worker1);
        proxy.registerAgent(101, 1);
        vm.prank(verifier1);
        proxy.registerAgent(201, 2);
        vm.prank(verifier2);
        proxy.registerAgent(202, 2);

        vm.prank(worker1);
        proxy.submitWork(dataHash, bytes32(0), bytes32(0), "");

        // Verifier1 scores close to consensus (80), Verifier2 diverges significantly (40)
        // Consensus will be avg: (80+40)/2 = 60
        // Verifier1 error: |80-60| = 20, Verifier2 error: |40-60| = 20
        // Equal error -> equal rewards (both deviate same amount from average)

        // Better test: 3 validators where 2 agree and 1 diverges
        vm.prank(verifier3);
        proxy.registerAgent(203, 2);

        // V1: 80, V2: 82, V3: 40 -> consensus ≈ (80+82+40)/3 = 67
        // V1 error: 13, V2 error: 15, V3 error: 27
        // V1 should get more than V3
        vm.prank(verifier1);
        proxy.submitScoreVector(dataHash, abi.encodePacked(uint8(80)));
        vm.prank(verifier2);
        proxy.submitScoreVector(dataHash, abi.encodePacked(uint8(82)));
        vm.prank(verifier3);
        proxy.submitScoreVector(dataHash, abi.encodePacked(uint8(40)));

        rewardsDistributor.registerWork(address(proxy), EPOCH, dataHash);
        rewardsDistributor.closeEpoch(address(proxy), EPOCH);

        uint256 v1Reward = rewardsDistributor.lastReleasedTo(verifier1);
        uint256 v3Reward = rewardsDistributor.lastReleasedTo(verifier3);

        assertTrue(v1Reward > v3Reward, "Accurate validator (V1) should get more than divergent (V3)");
    }

    // ============ releaseFunds -> withdraw Flow Tests ============

    function test_releaseFunds_updatesWithdrawableBalance() public {
        (MockStudioProxy proxy,) = _createStudioWithFunds(10 ether);

        bytes memory scores = abi.encodePacked(uint8(100));
        bytes32 dataHash = _setupSingleWorkerWithScores(proxy, scores, scores);

        rewardsDistributor.registerWork(address(proxy), EPOCH, dataHash);
        rewardsDistributor.closeEpoch(address(proxy), EPOCH);

        uint256 workerBalance = proxy.getWithdrawableBalance(worker1);
        assertTrue(workerBalance > 0, "Worker should have withdrawable balance after closeEpoch");

        uint256 v1Balance = proxy.getWithdrawableBalance(verifier1);
        assertTrue(v1Balance > 0, "Verifier should have withdrawable balance after closeEpoch");

        uint256 orchBalance = proxy.getWithdrawableBalance(orchestrator);
        assertTrue(orchBalance > 0, "Orchestrator should have withdrawable balance after closeEpoch");
    }

    function test_withdraw_sendsETH() public {
        (MockStudioProxy proxy,) = _createStudioWithFunds(10 ether);

        // Fund the proxy with enough ETH for withdrawals
        vm.deal(address(proxy), 100 ether);

        bytes memory scores = abi.encodePacked(uint8(100));
        bytes32 dataHash = _setupSingleWorkerWithScores(proxy, scores, scores);

        rewardsDistributor.registerWork(address(proxy), EPOCH, dataHash);
        rewardsDistributor.closeEpoch(address(proxy), EPOCH);

        uint256 workerBalanceBefore = worker1.balance;
        uint256 withdrawableAmount = proxy.getWithdrawableBalance(worker1);
        assertTrue(withdrawableAmount > 0, "Should have withdrawable balance");

        vm.prank(worker1);
        proxy.withdraw();

        assertEq(worker1.balance - workerBalanceBefore, withdrawableAmount, "Worker should receive exact withdrawable amount");
        assertEq(proxy.getWithdrawableBalance(worker1), 0, "Withdrawable should be 0 after withdrawal");
    }

    function test_withdraw_multipleAgentsIndependently() public {
        (MockStudioProxy proxy,) = _createStudioWithFunds(10 ether);

        // Fund proxy for withdrawals
        vm.deal(address(proxy), 100 ether);

        bytes memory scores = abi.encodePacked(uint8(100));
        bytes32 dataHash = _setupSingleWorkerWithScores(proxy, scores, scores);

        rewardsDistributor.registerWork(address(proxy), EPOCH, dataHash);
        rewardsDistributor.closeEpoch(address(proxy), EPOCH);

        // Record balances
        uint256 w1Before = worker1.balance;
        uint256 v1Before = verifier1.balance;
        uint256 v2Before = verifier2.balance;

        uint256 w1Withdrawable = proxy.getWithdrawableBalance(worker1);
        uint256 v1Withdrawable = proxy.getWithdrawableBalance(verifier1);
        uint256 v2Withdrawable = proxy.getWithdrawableBalance(verifier2);

        // All agents withdraw independently
        vm.prank(worker1);
        proxy.withdraw();

        vm.prank(verifier1);
        proxy.withdraw();

        vm.prank(verifier2);
        proxy.withdraw();

        assertEq(worker1.balance - w1Before, w1Withdrawable, "Worker1 received correct amount");
        assertEq(verifier1.balance - v1Before, v1Withdrawable, "Verifier1 received correct amount");
        assertEq(verifier2.balance - v2Before, v2Withdrawable, "Verifier2 received correct amount");
    }

    function test_withdraw_revertsIfNothingToWithdraw() public {
        (MockStudioProxy proxy,) = _createStudioWithFunds(10 ether);

        // Worker has no rewards — never submitted work
        vm.prank(worker1);
        vm.expectRevert("Nothing to withdraw");
        proxy.withdraw();
    }

    function test_withdraw_doubleWithdrawReverts() public {
        (MockStudioProxy proxy,) = _createStudioWithFunds(10 ether);
        vm.deal(address(proxy), 100 ether);

        bytes memory scores = abi.encodePacked(uint8(100));
        bytes32 dataHash = _setupSingleWorkerWithScores(proxy, scores, scores);

        rewardsDistributor.registerWork(address(proxy), EPOCH, dataHash);
        rewardsDistributor.closeEpoch(address(proxy), EPOCH);

        // First withdrawal succeeds
        vm.prank(worker1);
        proxy.withdraw();

        // Second withdrawal reverts
        vm.prank(worker1);
        vm.expectRevert("Nothing to withdraw");
        proxy.withdraw();
    }

    // ============ End-to-End Test ============

    function test_fullRewardsLifecycle() public {
        // ========== Phase 1: Create market + studio ==========
        (MockStudioProxy proxy,) = _createStudioWithFunds(10 ether);
        vm.deal(address(proxy), 100 ether); // Fund for withdrawals

        uint256 totalEscrow = proxy.getTotalEscrow();
        assertTrue(totalEscrow > 0, "Studio should have escrow");

        // ========== Phase 2: Register agents ==========
        vm.prank(worker1);
        proxy.registerAgent(101, 1);
        vm.prank(worker2);
        proxy.registerAgent(102, 1);
        vm.prank(verifier1);
        proxy.registerAgent(201, 2);
        vm.prank(verifier2);
        proxy.registerAgent(202, 2);

        // ========== Phase 3: Submit multi-agent work ==========
        bytes32 dataHash = keccak256("full-lifecycle-work");

        address[] memory participants = new address[](2);
        participants[0] = worker1;
        participants[1] = worker2;
        uint16[] memory weights = new uint16[](2);
        weights[0] = 6000; // 60%
        weights[1] = 4000; // 40%

        vm.prank(worker1);
        proxy.submitWorkMultiAgent(dataHash, participants, weights);

        // ========== Phase 4: Submit scores ==========
        // Both verifiers score for worker1 (primary)
        bytes memory v1Scores = abi.encodePacked(uint8(85), uint8(90), uint8(80));
        bytes memory v2Scores = abi.encodePacked(uint8(80), uint8(88), uint8(82));

        vm.prank(verifier1);
        proxy.submitScoreVector(dataHash, v1Scores);

        vm.prank(verifier2);
        proxy.submitScoreVector(dataHash, v2Scores);

        // ========== Phase 5: Close epoch ==========
        rewardsDistributor.registerWork(address(proxy), EPOCH, dataHash);
        rewardsDistributor.closeEpoch(address(proxy), EPOCH);

        // ========== Phase 6: Verify consensus ==========
        MockRewardsDistributor.ConsensusResult memory result = rewardsDistributor.getConsensusResult(dataHash);

        assertTrue(result.finalized, "Consensus should be finalized");
        assertEq(result.consensusScores.length, 3, "Should have 3 dimensions");
        // Avg: dim0=(85+80)/2=82, dim1=(90+88)/2=89, dim2=(80+82)/2=81
        assertEq(result.consensusScores[0], 82, "Dim 0 consensus");
        assertEq(result.consensusScores[1], 89, "Dim 1 consensus");
        assertEq(result.consensusScores[2], 81, "Dim 2 consensus");

        // ========== Phase 7: Verify all balances ==========
        uint256 w1Balance = proxy.getWithdrawableBalance(worker1);
        uint256 w2Balance = proxy.getWithdrawableBalance(worker2);
        uint256 v1Balance = proxy.getWithdrawableBalance(verifier1);
        uint256 v2Balance = proxy.getWithdrawableBalance(verifier2);
        uint256 orchBalance = proxy.getWithdrawableBalance(orchestrator);

        assertTrue(w1Balance > 0, "Worker1 should have rewards");
        assertTrue(w2Balance > 0, "Worker2 should have rewards");
        assertTrue(v1Balance > 0, "Verifier1 should have rewards");
        assertTrue(v2Balance > 0, "Verifier2 should have rewards");
        assertTrue(orchBalance > 0, "Orchestrator should have rewards");

        // Worker1 (60%) should get more than Worker2 (40%)
        assertTrue(w1Balance > w2Balance, "Worker1 (60%) > Worker2 (40%)");

        // Total should not exceed escrow
        uint256 totalDistributed = w1Balance + w2Balance + v1Balance + v2Balance + orchBalance;
        assertLe(totalDistributed, totalEscrow, "Total distributed <= escrow");

        // ========== Phase 8: All agents withdraw ==========
        uint256 w1Before = worker1.balance;
        uint256 w2Before = worker2.balance;
        uint256 v1Before = verifier1.balance;
        uint256 v2Before = verifier2.balance;

        vm.prank(worker1);
        proxy.withdraw();
        vm.prank(worker2);
        proxy.withdraw();
        vm.prank(verifier1);
        proxy.withdraw();
        vm.prank(verifier2);
        proxy.withdraw();

        // ========== Phase 9: Verify ETH balances ==========
        assertEq(worker1.balance - w1Before, w1Balance, "Worker1 ETH correct");
        assertEq(worker2.balance - w2Before, w2Balance, "Worker2 ETH correct");
        assertEq(verifier1.balance - v1Before, v1Balance, "Verifier1 ETH correct");
        assertEq(verifier2.balance - v2Before, v2Balance, "Verifier2 ETH correct");

        // All withdrawable balances should be 0
        assertEq(proxy.getWithdrawableBalance(worker1), 0, "Worker1 withdrawable should be 0");
        assertEq(proxy.getWithdrawableBalance(worker2), 0, "Worker2 withdrawable should be 0");
        assertEq(proxy.getWithdrawableBalance(verifier1), 0, "Verifier1 withdrawable should be 0");
        assertEq(proxy.getWithdrawableBalance(verifier2), 0, "Verifier2 withdrawable should be 0");
    }

    // ============ Receive ETH ============
    receive() external payable {}
}
