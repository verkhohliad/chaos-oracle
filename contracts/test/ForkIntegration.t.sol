// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ChaosOracleRegistry} from "../src/ChaosOracleRegistry.sol";
import {PredictionSettlementLogic} from "../src/PredictionSettlementLogic.sol";
import {ExamplePredictionMarket} from "../src/example/ExamplePredictionMarket.sol";
import {MarketKey} from "../src/libraries/MarketKey.sol";

/// @title ForkIntegrationTest
/// @notice Full lifecycle test running against a Sepolia fork with REAL ChaosChain infrastructure.
///         Unlike Integration.t.sol (which uses MockStudioProxyFactory), this test deploys
///         StudioProxy instances through the real StudioProxyFactory on Sepolia.
///
/// Run with:
///   forge test --match-contract ForkIntegrationTest --fork-url $SEPOLIA_RPC -vvv
contract ForkIntegrationTest is Test {
    // ── Real ChaosChain addresses on Sepolia ──
    address constant CHAOS_CORE = 0xF6a57f04736A52a38b273b0204d636506a780E67;
    address constant STUDIO_PROXY_FACTORY = 0x230e76a105A9737Ea801BB7d0624D495506EE257;
    address constant CHAOSCHAIN_REGISTRY = 0x7F38C1aFFB24F30500d9174ed565110411E42d50;
    address constant REWARDS_DISTRIBUTOR = 0x0549772a3fF4F095C57AEFf655B3ed97B7925C19;

    ChaosOracleRegistry registry;
    PredictionSettlementLogic logic;
    ExamplePredictionMarket market;

    // creForwarder is address(this) so we can call onlyCRE functions directly
    address creForwarder;

    address alice = address(0xA11CE);   // Market creator
    address bob = address(0xB0B);       // Bettor (Yes)
    address charlie = address(0xCC);    // Bettor (No)
    address worker1 = address(0xD1);
    address worker2 = address(0xD2);
    address worker3 = address(0xD3);
    address verifier1 = address(0xE1);
    address verifier2 = address(0xE2);

    function setUp() public {
        // The test contract itself acts as the CRE forwarder
        creForwarder = address(this);

        // Deploy ChaosOracle contracts on the fork with REAL ChaosChain addresses
        logic = new PredictionSettlementLogic();

        registry = new ChaosOracleRegistry(
            CHAOS_CORE,
            address(logic),
            creForwarder,          // address(this) - so we can call onlyCRE functions
            STUDIO_PROXY_FACTORY,  // REAL factory on Sepolia
            CHAOSCHAIN_REGISTRY,   // REAL registry on Sepolia
            REWARDS_DISTRIBUTOR    // REAL distributor on Sepolia
        );

        market = new ExamplePredictionMarket(address(registry));

        // Fund test accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);
        vm.deal(worker1, 10 ether);
        vm.deal(worker2, 10 ether);
        vm.deal(worker3, 10 ether);
        vm.deal(verifier1, 10 ether);
        vm.deal(verifier2, 10 ether);
    }

    function test_fullLifecycleOnFork() public {
        // ========== Phase 1: Market Creation ==========
        uint256 deadline = block.timestamp + 1 days;

        vm.prank(alice);
        uint256 marketId = market.createMarket{value: 10 ether}(
            "Will ETH reach $10,000 by end of 2025?",
            deadline
        );
        assertEq(marketId, 0);

        // Verify registry received 10% (1 ETH)
        assertEq(address(registry).balance, 1 ether);

        // ========== Phase 2: Betting ==========
        vm.prank(bob);
        market.placeBet{value: 5 ether}(marketId, 0); // Yes

        vm.prank(charlie);
        market.placeBet{value: 3 ether}(marketId, 1); // No

        // Check pools: Yes = 9 + 5 = 14, No = 3
        (, , , uint256 yesPool, uint256 noPool, , ) = market.getMarket(marketId);
        assertEq(yesPool, 14 ether);
        assertEq(noPool, 3 ether);

        // ========== Phase 3: Studio Creation (via REAL StudioProxyFactory) ==========
        vm.warp(deadline + 1);

        // Check for ready markets
        bytes32[] memory readyKeys = registry.getMarketsReadyForSettlement();
        assertEq(readyKeys.length, 1);

        bytes32 key = readyKeys[0];
        assertEq(key, MarketKey.derive(address(market), marketId));

        // Create studio — this goes through the REAL StudioProxyFactory on Sepolia
        // authorizedWorkflowId is bytes32(0) (never set), so the onlyCRE modifier
        // skips the workflowId check. We only need msg.sender == creForwarder.
        bytes memory creReport = abi.encode(bytes32(0));
        registry.createStudioForMarket(key, creReport);

        address studioProxy = registry.keyToStudio(key);
        assertTrue(studioProxy != address(0), "Studio proxy should be deployed");
        console.log("Real StudioProxy deployed at:", studioProxy);

        // No more ready markets
        bytes32[] memory readyKeysAfter = registry.getMarketsReadyForSettlement();
        assertEq(readyKeysAfter.length, 0);

        // Active studios should have one
        address[] memory activeStudios = registry.getActiveStudios();
        assertEq(activeStudios.length, 1);
        assertEq(activeStudios[0], studioProxy);

        // ========== Phase 4: Workers Submit ==========
        // Worker 1 & 2 say Yes (outcome 0), Worker 3 says No (outcome 1)
        vm.prank(worker1);
        (bool success,) = studioProxy.call{value: 0.001 ether}(
            abi.encodeWithSignature("registerAsWorker()")
        );
        assertTrue(success, "Worker 1 register failed");

        vm.prank(worker2);
        (success,) = studioProxy.call{value: 0.001 ether}(
            abi.encodeWithSignature("registerAsWorker()")
        );
        assertTrue(success, "Worker 2 register failed");

        vm.prank(worker3);
        (success,) = studioProxy.call{value: 0.001 ether}(
            abi.encodeWithSignature("registerAsWorker()")
        );
        assertTrue(success, "Worker 3 register failed");

        vm.prank(worker1);
        (success,) = studioProxy.call(
            abi.encodeWithSignature("submitWork(uint8,string)", uint8(0), "QmYesEvidence1")
        );
        assertTrue(success, "Worker 1 submit failed");

        vm.prank(worker2);
        (success,) = studioProxy.call(
            abi.encodeWithSignature("submitWork(uint8,string)", uint8(0), "QmYesEvidence2")
        );
        assertTrue(success, "Worker 2 submit failed");

        vm.prank(worker3);
        (success,) = studioProxy.call(
            abi.encodeWithSignature("submitWork(uint8,string)", uint8(1), "QmNoEvidence1")
        );
        assertTrue(success, "Worker 3 submit failed");

        // ========== Phase 5: Verifiers Score ==========
        vm.prank(verifier1);
        (success,) = studioProxy.call{value: 0.001 ether}(
            abi.encodeWithSignature("registerAsVerifier()")
        );
        assertTrue(success, "Verifier 1 register failed");

        vm.prank(verifier2);
        (success,) = studioProxy.call{value: 0.001 ether}(
            abi.encodeWithSignature("registerAsVerifier()")
        );
        assertTrue(success, "Verifier 2 register failed");

        // High scores for Yes workers, lower for No worker
        uint8[4] memory highScores = [uint8(90), uint8(85), uint8(80), uint8(95)];
        uint8[4] memory lowScores = [uint8(40), uint8(30), uint8(35), uint8(45)];

        // Verifier 1 scores all workers
        vm.prank(verifier1);
        (success,) = studioProxy.call(
            abi.encodeWithSignature("submitScores(address,uint8[4])", worker1, highScores)
        );
        assertTrue(success, "V1 score W1 failed");

        vm.prank(verifier1);
        (success,) = studioProxy.call(
            abi.encodeWithSignature("submitScores(address,uint8[4])", worker2, highScores)
        );
        assertTrue(success, "V1 score W2 failed");

        vm.prank(verifier1);
        (success,) = studioProxy.call(
            abi.encodeWithSignature("submitScores(address,uint8[4])", worker3, lowScores)
        );
        assertTrue(success, "V1 score W3 failed");

        // Verifier 2 scores all workers
        vm.prank(verifier2);
        (success,) = studioProxy.call(
            abi.encodeWithSignature("submitScores(address,uint8[4])", worker1, highScores)
        );
        assertTrue(success, "V2 score W1 failed");

        vm.prank(verifier2);
        (success,) = studioProxy.call(
            abi.encodeWithSignature("submitScores(address,uint8[4])", worker2, highScores)
        );
        assertTrue(success, "V2 score W2 failed");

        vm.prank(verifier2);
        (success,) = studioProxy.call(
            abi.encodeWithSignature("submitScores(address,uint8[4])", worker3, lowScores)
        );
        assertTrue(success, "V2 score W3 failed");

        // ========== Phase 6: Check canClose & Close Epoch ==========
        assertTrue(registry.canCloseStudio(studioProxy), "Studio should be closeable");

        registry.closeStudioEpoch(studioProxy, creReport);

        // Verify settlement: Yes (outcome 0) should win
        (, , , , , uint8 outcome, bool settled) = market.getMarket(marketId);
        assertEq(outcome, 0, "Yes should win");
        assertTrue(settled, "Market should be settled");

        // Active studios should be empty now
        activeStudios = registry.getActiveStudios();
        assertEq(activeStudios.length, 0, "No active studios after settlement");

        console.log("=== Fork Integration Test Passed ===");
        console.log("Real StudioProxy deployed and settled successfully");

        // ========== Phase 7: Claim Winnings ==========
        // Total pool = 14 (Yes) + 3 (No) = 17 ETH
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        market.claimWinnings(marketId);
        uint256 alicePayout = alice.balance - aliceBefore;

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        market.claimWinnings(marketId);
        uint256 bobPayout = bob.balance - bobBefore;

        // Alice: 9 ETH on Yes, Bob: 5 ETH on Yes. Total pool 17 ETH, Yes pool 14 ETH
        uint256 totalPool = 17 ether;
        uint256 yesPoolSize = 14 ether;
        assertEq(alicePayout, (9 ether * totalPool) / yesPoolSize);
        assertEq(bobPayout, (5 ether * totalPool) / yesPoolSize);

        // Charlie (No) should fail
        vm.prank(charlie);
        vm.expectRevert("ExamplePredictionMarket: no winning bet");
        market.claimWinnings(marketId);

        console.log("Alice payout:", alicePayout);
        console.log("Bob payout:", bobPayout);
    }

    receive() external payable {}
}
