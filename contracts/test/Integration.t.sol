// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ChaosOracleRegistry} from "../src/ChaosOracleRegistry.sol";
import {PredictionSettlementLogic} from "../src/PredictionSettlementLogic.sol";
import {ExamplePredictionMarket} from "../src/example/ExamplePredictionMarket.sol";
import {MockChaosCore} from "./mocks/MockChaosCore.sol";
import {MarketKey} from "../src/libraries/MarketKey.sol";

/// @title IntegrationTest
/// @notice Full lifecycle test: create market -> register -> studio creation ->
///         workers submit -> verifiers score -> settlement -> claim winnings
contract IntegrationTest is Test {
    ChaosOracleRegistry registry;
    MockChaosCore chaosCore;
    PredictionSettlementLogic logic;
    ExamplePredictionMarket market;
    address creForwarder = address(0xC4E);

    address alice = address(0xA11CE);   // Market creator
    address bob = address(0xB0B);       // Bettor (Yes)
    address charlie = address(0xCC);    // Bettor (No)
    address worker1 = address(0xD1);
    address worker2 = address(0xD2);
    address worker3 = address(0xD3);
    address verifier1 = address(0xE1);
    address verifier2 = address(0xE2);

    function setUp() public {
        // Deploy protocol
        chaosCore = new MockChaosCore();
        logic = new PredictionSettlementLogic();
        chaosCore.registerLogicModule(address(logic), "PredictionSettlement");

        registry = new ChaosOracleRegistry(
            address(chaosCore), address(logic), creForwarder
        );

        market = new ExamplePredictionMarket(address(registry));

        // Fund everyone
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);
        vm.deal(worker1, 10 ether);
        vm.deal(worker2, 10 ether);
        vm.deal(worker3, 10 ether);
        vm.deal(verifier1, 10 ether);
        vm.deal(verifier2, 10 ether);
    }

    function test_fullLifecycle() public {
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

        // ========== Phase 3: Studio Creation (CRE triggers) ==========
        vm.warp(deadline + 1);

        // CRE checks for ready markets
        bytes32[] memory readyKeys = registry.getMarketsReadyForSettlement();
        assertEq(readyKeys.length, 1);

        bytes32 key = readyKeys[0];
        assertEq(key, MarketKey.derive(address(market), marketId));

        // CRE creates studio
        bytes memory creReport = abi.encode(bytes32(0));
        vm.prank(creForwarder);
        registry.createStudioForMarket(key, creReport);

        address studioProxy = registry.keyToStudio(key);
        assertTrue(studioProxy != address(0));

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
        assertTrue(success);

        vm.prank(worker2);
        (success,) = studioProxy.call{value: 0.001 ether}(
            abi.encodeWithSignature("registerAsWorker()")
        );
        assertTrue(success);

        vm.prank(worker3);
        (success,) = studioProxy.call{value: 0.001 ether}(
            abi.encodeWithSignature("registerAsWorker()")
        );
        assertTrue(success);

        vm.prank(worker1);
        (success,) = studioProxy.call(
            abi.encodeWithSignature("submitWork(uint8,string)", uint8(0), "QmYesEvidence1")
        );
        assertTrue(success);

        vm.prank(worker2);
        (success,) = studioProxy.call(
            abi.encodeWithSignature("submitWork(uint8,string)", uint8(0), "QmYesEvidence2")
        );
        assertTrue(success);

        vm.prank(worker3);
        (success,) = studioProxy.call(
            abi.encodeWithSignature("submitWork(uint8,string)", uint8(1), "QmNoEvidence1")
        );
        assertTrue(success);

        // ========== Phase 5: Verifiers Score ==========
        vm.prank(verifier1);
        (success,) = studioProxy.call{value: 0.001 ether}(
            abi.encodeWithSignature("registerAsVerifier()")
        );
        assertTrue(success);

        vm.prank(verifier2);
        (success,) = studioProxy.call{value: 0.001 ether}(
            abi.encodeWithSignature("registerAsVerifier()")
        );
        assertTrue(success);

        // High scores for Yes workers, lower for No worker
        uint8[4] memory highScores = [uint8(90), uint8(85), uint8(80), uint8(95)];
        uint8[4] memory lowScores = [uint8(40), uint8(30), uint8(35), uint8(45)];

        // Verifier 1 scores all workers
        vm.prank(verifier1);
        (success,) = studioProxy.call(
            abi.encodeWithSignature("submitScores(address,uint8[4])", worker1, highScores)
        );
        assertTrue(success);

        vm.prank(verifier1);
        (success,) = studioProxy.call(
            abi.encodeWithSignature("submitScores(address,uint8[4])", worker2, highScores)
        );
        assertTrue(success);

        vm.prank(verifier1);
        (success,) = studioProxy.call(
            abi.encodeWithSignature("submitScores(address,uint8[4])", worker3, lowScores)
        );
        assertTrue(success);

        // Verifier 2 scores all workers
        vm.prank(verifier2);
        (success,) = studioProxy.call(
            abi.encodeWithSignature("submitScores(address,uint8[4])", worker1, highScores)
        );
        assertTrue(success);

        vm.prank(verifier2);
        (success,) = studioProxy.call(
            abi.encodeWithSignature("submitScores(address,uint8[4])", worker2, highScores)
        );
        assertTrue(success);

        vm.prank(verifier2);
        (success,) = studioProxy.call(
            abi.encodeWithSignature("submitScores(address,uint8[4])", worker3, lowScores)
        );
        assertTrue(success);

        // ========== Phase 6: Check canClose & Close Epoch ==========
        assertTrue(registry.canCloseStudio(studioProxy));

        vm.prank(creForwarder);
        registry.closeStudioEpoch(studioProxy, creReport);

        // Verify settlement: Yes (outcome 0) should win
        (, , , , , uint8 outcome, bool settled) = market.getMarket(marketId);
        assertEq(outcome, 0); // Yes wins
        assertTrue(settled);

        // Active studios should be empty now
        activeStudios = registry.getActiveStudios();
        assertEq(activeStudios.length, 0);

        // ========== Phase 7: Claim Winnings ==========
        // Total pool = 14 (Yes) + 3 (No) = 17 ETH
        // Alice: 9 ETH on Yes -> (9/14) * 17 = 10.928... ETH
        // Bob: 5 ETH on Yes -> (5/14) * 17 = 6.071... ETH

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        market.claimWinnings(marketId);
        uint256 alicePayout = alice.balance - aliceBefore;

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        market.claimWinnings(marketId);
        uint256 bobPayout = bob.balance - bobBefore;

        // Alice bet 9 ETH on Yes. Total pool = 14 + 3 = 17 ETH. Yes pool = 14.
        // Alice share = (9 * 17) / 14 = 10.928... ETH
        uint256 aliceBet = 9 ether;
        uint256 bobBet = 5 ether;
        uint256 totalPool = 17 ether;
        uint256 yesPoolSize = 14 ether;
        assertEq(alicePayout, (aliceBet * totalPool) / yesPoolSize);
        assertEq(bobPayout, (bobBet * totalPool) / yesPoolSize);

        // Charlie had No bets - should revert
        vm.prank(charlie);
        vm.expectRevert("ExamplePredictionMarket: no winning bet");
        market.claimWinnings(marketId);
    }

    function test_multipleMarkets() public {
        uint256 deadline1 = block.timestamp + 1 days;
        uint256 deadline2 = block.timestamp + 2 days;

        // Create two markets
        vm.prank(alice);
        uint256 id1 = market.createMarket{value: 5 ether}("Market 1?", deadline1);

        vm.prank(alice);
        uint256 id2 = market.createMarket{value: 3 ether}("Market 2?", deadline2);

        assertEq(id1, 0);
        assertEq(id2, 1);

        // Warp past first deadline
        vm.warp(deadline1 + 1);
        bytes32[] memory readyKeys = registry.getMarketsReadyForSettlement();
        assertEq(readyKeys.length, 1); // Only first market

        // Warp past second deadline
        vm.warp(deadline2 + 1);
        readyKeys = registry.getMarketsReadyForSettlement();
        assertEq(readyKeys.length, 2); // Both markets
    }

    receive() external payable {}
}
