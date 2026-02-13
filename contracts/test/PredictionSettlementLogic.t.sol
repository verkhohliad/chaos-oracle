// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PredictionSettlementLogic} from "../src/PredictionSettlementLogic.sol";
import {ChaosOracleRegistry} from "../src/ChaosOracleRegistry.sol";
import {MockChaosCore, MockStudioProxyFactory} from "./mocks/MockChaosCore.sol";
import {MockPredictionMarket} from "./mocks/MockPredictionMarket.sol";
import {MarketKey} from "../src/libraries/MarketKey.sol";

contract PredictionSettlementLogicTest is Test {
    ChaosOracleRegistry registry;
    MockChaosCore chaosCore;
    MockStudioProxyFactory proxyFactory;
    PredictionSettlementLogic logic;
    MockPredictionMarket predMarket;
    address creForwarder = address(0xC4E);
    address chaosChainRegistry = address(0xCC1);
    address rewardsDistributor = address(0x4E1);

    // Studio proxy created during setup
    address studioProxy;

    address worker1 = address(0xD1);
    address worker2 = address(0xD2);
    address worker3 = address(0xD3);
    address verifier1 = address(0xF1);
    address verifier2 = address(0xF2);

    function setUp() public {
        chaosCore = new MockChaosCore();
        proxyFactory = new MockStudioProxyFactory();
        logic = new PredictionSettlementLogic();

        registry = new ChaosOracleRegistry(
            address(chaosCore), address(logic), creForwarder,
            address(proxyFactory), chaosChainRegistry, rewardsDistributor
        );

        predMarket = new MockPredictionMarket(address(registry));

        // Fund the mock market so it can send ETH during registerForSettlement
        vm.deal(address(predMarket), 10 ether);

        // Register a market
        string[] memory opts = new string[](2);
        opts[0] = "Yes";
        opts[1] = "No";
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(address(predMarket));
        registry.registerForSettlement{value: 1 ether}(1, "Will ETH hit $5000?", opts, deadline);

        // Warp past deadline and create studio
        vm.warp(deadline + 1);
        bytes32 key = MarketKey.derive(address(predMarket), 1);
        bytes memory creReport = abi.encode(bytes32(0));
        vm.prank(creForwarder);
        registry.createStudioForMarket(key, creReport);

        studioProxy = registry.keyToStudio(key);

        // Fund test accounts
        vm.deal(worker1, 10 ether);
        vm.deal(worker2, 10 ether);
        vm.deal(worker3, 10 ether);
        vm.deal(verifier1, 10 ether);
        vm.deal(verifier2, 10 ether);
    }

    // ============ Helper to call logic via proxy ============

    function _registerWorker(address worker) internal {
        vm.prank(worker);
        (bool success,) = studioProxy.call{value: 0.001 ether}(
            abi.encodeWithSignature("registerAsWorker()")
        );
        assertTrue(success, "registerAsWorker failed");
    }

    function _registerVerifier(address verifier) internal {
        vm.prank(verifier);
        (bool success,) = studioProxy.call{value: 0.001 ether}(
            abi.encodeWithSignature("registerAsVerifier()")
        );
        assertTrue(success, "registerAsVerifier failed");
    }

    function _submitWork(address worker, uint8 outcome, string memory cid) internal {
        vm.prank(worker);
        (bool success,) = studioProxy.call(
            abi.encodeWithSignature("submitWork(uint8,string)", outcome, cid)
        );
        assertTrue(success, "submitWork failed");
    }

    function _submitScores(address verifier, address worker, uint8[4] memory scores) internal {
        vm.prank(verifier);
        (bool success,) = studioProxy.call(
            abi.encodeWithSignature("submitScores(address,uint8[4])", worker, scores)
        );
        assertTrue(success, "submitScores failed");
    }

    function _canClose() internal returns (bool) {
        (bool success, bytes memory data) = studioProxy.call(
            abi.encodeWithSignature("canClose()")
        );
        assertTrue(success, "canClose call failed");
        return abi.decode(data, (bool));
    }

    // ============ Initialize Tests ============

    function test_initialize_setsFields() public {
        // The studio was initialized during setUp via registry.createStudioForMarket
        (bool success, bytes memory data) = studioProxy.staticcall(
            abi.encodeWithSignature("question()")
        );
        assertTrue(success);
        string memory q = abi.decode(data, (string));
        assertEq(q, "Will ETH hit $5000?");

        (success, data) = studioProxy.staticcall(
            abi.encodeWithSignature("getOptionCount()")
        );
        assertTrue(success);
        uint256 optCount = abi.decode(data, (uint256));
        assertEq(optCount, 2);
    }

    function test_initialize_cannotReinitialize() public {
        bytes memory initData = abi.encodeWithSignature(
            "initialize(bytes)",
            abi.encode(address(registry), address(predMarket), uint256(1), "Q2?", new string[](2))
        );
        (bool success,) = studioProxy.call(initData);
        assertFalse(success); // Should revert: already initialized
    }

    // ============ Worker Registration Tests ============

    function test_registerAsWorker() public {
        _registerWorker(worker1);

        (bool success, bytes memory data) = studioProxy.staticcall(
            abi.encodeWithSignature("isWorkerRegistered(address)", worker1)
        );
        assertTrue(success);
        assertTrue(abi.decode(data, (bool)));

        (success, data) = studioProxy.staticcall(
            abi.encodeWithSignature("getWorkerCount()")
        );
        assertTrue(success);
        assertEq(abi.decode(data, (uint256)), 1);
    }

    function test_registerAsWorker_revertsInsufficientStake() public {
        vm.prank(worker1);
        (bool success,) = studioProxy.call{value: 0.0001 ether}(
            abi.encodeWithSignature("registerAsWorker()")
        );
        assertFalse(success);
    }

    function test_registerAsWorker_revertsAlreadyRegistered() public {
        _registerWorker(worker1);

        vm.prank(worker1);
        (bool success,) = studioProxy.call{value: 0.001 ether}(
            abi.encodeWithSignature("registerAsWorker()")
        );
        assertFalse(success);
    }

    // ============ Verifier Registration Tests ============

    function test_registerAsVerifier() public {
        _registerVerifier(verifier1);

        (bool success, bytes memory data) = studioProxy.staticcall(
            abi.encodeWithSignature("isVerifierRegistered(address)", verifier1)
        );
        assertTrue(success);
        assertTrue(abi.decode(data, (bool)));
    }

    function test_registerAsVerifier_revertsIfWorker() public {
        _registerWorker(worker1);

        vm.prank(worker1);
        (bool success,) = studioProxy.call{value: 0.001 ether}(
            abi.encodeWithSignature("registerAsVerifier()")
        );
        assertFalse(success); // workers can't verify
    }

    // ============ Work Submission Tests ============

    function test_submitWork() public {
        _registerWorker(worker1);
        _submitWork(worker1, 0, "QmEvidence1");

        (bool success, bytes memory data) = studioProxy.staticcall(
            abi.encodeWithSignature("submissions(address)", worker1)
        );
        assertTrue(success);
        (uint8 outcome, string memory cid, uint256 timestamp) = abi.decode(data, (uint8, string, uint256));
        assertEq(outcome, 0);
        assertEq(cid, "QmEvidence1");
        assertTrue(timestamp > 0);
    }

    function test_submitWork_revertsNotRegistered() public {
        vm.prank(worker1);
        (bool success,) = studioProxy.call(
            abi.encodeWithSignature("submitWork(uint8,string)", uint8(0), "QmEvidence")
        );
        assertFalse(success);
    }

    function test_submitWork_revertsInvalidOutcome() public {
        _registerWorker(worker1);

        vm.prank(worker1);
        (bool success,) = studioProxy.call(
            abi.encodeWithSignature("submitWork(uint8,string)", uint8(5), "QmEvidence")
        );
        assertFalse(success);
    }

    function test_submitWork_revertsDoubleSubmission() public {
        _registerWorker(worker1);
        _submitWork(worker1, 0, "QmEvidence1");

        vm.prank(worker1);
        (bool success,) = studioProxy.call(
            abi.encodeWithSignature("submitWork(uint8,string)", uint8(1), "QmEvidence2")
        );
        assertFalse(success);
    }

    // ============ Score Submission Tests ============

    function test_submitScores() public {
        _registerWorker(worker1);
        _submitWork(worker1, 0, "QmEvidence1");
        _registerVerifier(verifier1);

        uint8[4] memory scores = [uint8(80), uint8(70), uint8(60), uint8(90)];
        _submitScores(verifier1, worker1, scores);

        // Check score count
        (bool success, bytes memory data) = studioProxy.staticcall(
            abi.encodeWithSignature("scoreCount(address)", worker1)
        );
        assertTrue(success);
        assertEq(abi.decode(data, (uint256)), 1);
    }

    function test_submitScores_revertsNotVerifier() public {
        _registerWorker(worker1);
        _submitWork(worker1, 0, "QmEvidence1");

        uint8[4] memory scores = [uint8(80), uint8(70), uint8(60), uint8(90)];

        vm.prank(worker2); // Not registered as verifier
        (bool success,) = studioProxy.call(
            abi.encodeWithSignature("submitScores(address,uint8[4])", worker1, scores)
        );
        assertFalse(success);
    }

    function test_submitScores_revertsScoreTooHigh() public {
        _registerWorker(worker1);
        _submitWork(worker1, 0, "QmEvidence1");
        _registerVerifier(verifier1);

        uint8[4] memory scores = [uint8(101), uint8(70), uint8(60), uint8(90)]; // 101 > 100

        vm.prank(verifier1);
        (bool success,) = studioProxy.call(
            abi.encodeWithSignature("submitScores(address,uint8[4])", worker1, scores)
        );
        assertFalse(success);
    }

    // ============ canClose Tests ============

    function test_canClose_falseWithNoWorkers() public {
        assertFalse(_canClose());
    }

    function test_canClose_falseWithInsufficientWorkers() public {
        _registerWorker(worker1);
        _submitWork(worker1, 0, "QmEvidence1");
        _registerVerifier(verifier1);
        _registerVerifier(verifier2);

        uint8[4] memory scores = [uint8(80), uint8(70), uint8(60), uint8(90)];
        _submitScores(verifier1, worker1, scores);
        _submitScores(verifier2, worker1, scores);

        // Only 1 worker with sufficient scores, need MIN_WORKERS=3
        assertFalse(_canClose());
    }

    function test_canClose_trueWhenThresholdsMet() public {
        // Register 3 workers
        _registerWorker(worker1);
        _registerWorker(worker2);
        _registerWorker(worker3);

        // Submit work
        _submitWork(worker1, 0, "QmEvidence1");
        _submitWork(worker2, 0, "QmEvidence2");
        _submitWork(worker3, 1, "QmEvidence3");

        // Register 2 verifiers
        _registerVerifier(verifier1);
        _registerVerifier(verifier2);

        // Each verifier scores each worker (need MIN_SCORES_PER_WORKER=2)
        uint8[4] memory scores = [uint8(80), uint8(70), uint8(60), uint8(90)];
        _submitScores(verifier1, worker1, scores);
        _submitScores(verifier1, worker2, scores);
        _submitScores(verifier1, worker3, scores);
        _submitScores(verifier2, worker1, scores);
        _submitScores(verifier2, worker2, scores);
        _submitScores(verifier2, worker3, scores);

        assertTrue(_canClose());
    }

    // ============ Epoch Close & Consensus Tests ============

    function test_closeEpoch_consensusYesWins() public {
        // Setup full scenario: 2 workers say Yes, 1 says No
        _registerWorker(worker1);
        _registerWorker(worker2);
        _registerWorker(worker3);

        _submitWork(worker1, 0, "QmYes1");  // Yes
        _submitWork(worker2, 0, "QmYes2");  // Yes
        _submitWork(worker3, 1, "QmNo1");   // No

        _registerVerifier(verifier1);
        _registerVerifier(verifier2);

        // High scores for Yes workers, lower for No worker
        uint8[4] memory highScores = [uint8(90), uint8(85), uint8(80), uint8(95)];
        uint8[4] memory lowScores = [uint8(40), uint8(30), uint8(35), uint8(45)];

        _submitScores(verifier1, worker1, highScores);
        _submitScores(verifier1, worker2, highScores);
        _submitScores(verifier1, worker3, lowScores);
        _submitScores(verifier2, worker1, highScores);
        _submitScores(verifier2, worker2, highScores);
        _submitScores(verifier2, worker3, lowScores);

        // Close epoch via registry
        bytes memory creReport = abi.encode(bytes32(0));
        vm.prank(creForwarder);
        registry.closeStudioEpoch(studioProxy, creReport);

        // Verify market was settled with outcome 0 (Yes)
        assertTrue(predMarket.wasSettled(1));
        MockPredictionMarket.SettlementRecord memory record = predMarket.getSettlement(1);
        assertEq(record.outcome, 0); // Yes wins (higher weighted scores)
    }

    function test_closeEpoch_consensusNoWins() public {
        _registerWorker(worker1);
        _registerWorker(worker2);
        _registerWorker(worker3);

        _submitWork(worker1, 1, "QmNo1");   // No
        _submitWork(worker2, 1, "QmNo2");   // No
        _submitWork(worker3, 0, "QmYes1");  // Yes

        _registerVerifier(verifier1);
        _registerVerifier(verifier2);

        uint8[4] memory highScores = [uint8(90), uint8(85), uint8(80), uint8(95)];
        uint8[4] memory lowScores = [uint8(40), uint8(30), uint8(35), uint8(45)];

        _submitScores(verifier1, worker1, highScores);
        _submitScores(verifier1, worker2, highScores);
        _submitScores(verifier1, worker3, lowScores);
        _submitScores(verifier2, worker1, highScores);
        _submitScores(verifier2, worker2, highScores);
        _submitScores(verifier2, worker3, lowScores);

        bytes memory creReport = abi.encode(bytes32(0));
        vm.prank(creForwarder);
        registry.closeStudioEpoch(studioProxy, creReport);

        assertTrue(predMarket.wasSettled(1));
        MockPredictionMarket.SettlementRecord memory record = predMarket.getSettlement(1);
        assertEq(record.outcome, 1); // No wins
    }

    function test_closeEpoch_revertsNotRegistry() public {
        // Try to call closeEpoch directly (not from registry)
        (bool success,) = studioProxy.call(
            abi.encodeWithSignature("closeEpoch()")
        );
        assertFalse(success);
    }

    function test_closeEpoch_revertsThresholdsNotMet() public {
        // Only 1 worker - not enough
        _registerWorker(worker1);
        _submitWork(worker1, 0, "QmEvidence1");

        bytes memory creReport = abi.encode(bytes32(0));
        vm.prank(creForwarder);
        vm.expectRevert("ChaosOracleRegistry: closeEpoch failed");
        registry.closeStudioEpoch(studioProxy, creReport);
    }

    // ============ getStudioType / getVersion Tests ============

    function test_getStudioType() public {
        (bool success, bytes memory data) = studioProxy.staticcall(
            abi.encodeWithSignature("getStudioType()")
        );
        assertTrue(success);
        assertEq(abi.decode(data, (string)), "prediction-settlement");
    }

    function test_getVersion() public {
        (bool success, bytes memory data) = studioProxy.staticcall(
            abi.encodeWithSignature("getVersion()")
        );
        assertTrue(success);
        assertEq(abi.decode(data, (string)), "1.0.0");
    }

    // ============ getScoringCriteria Tests ============

    function test_getScoringCriteria() public {
        (bool success, bytes memory data) = studioProxy.staticcall(
            abi.encodeWithSignature("getScoringCriteria()")
        );
        assertTrue(success);
        (string[] memory names, uint16[] memory weights) = abi.decode(data, (string[], uint16[]));
        assertEq(names.length, 9);
        assertEq(weights.length, 9);
        assertEq(names[0], "Initiative");
        assertEq(names[5], "Accuracy");
        assertEq(weights[5], 200); // 2.0x for Accuracy
    }

    receive() external payable {}
}
