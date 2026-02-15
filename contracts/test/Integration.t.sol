// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ChaosOracleRegistry} from "../src/ChaosOracleRegistry.sol";
import {PredictionSettlementLogic} from "../src/PredictionSettlementLogic.sol";
import {ExamplePredictionMarket} from "../src/example/ExamplePredictionMarket.sol";
import {MockChaosCore, MockStudioProxyFactory, MockStudioProxy} from "./mocks/MockChaosCore.sol";
import {IStudioProxy} from "@chaoschain/interfaces/IStudioProxy.sol";
import {MarketKey} from "../src/libraries/MarketKey.sol";

/// @title IntegrationTest
/// @notice Full lifecycle test: create market -> betting -> studio creation ->
///         CRE settles with outcome -> claim winnings
///
/// @dev Worker submission and verifier scoring are now handled natively by
///      StudioProxy (via the ChaosChain SDK + Gateway). Consensus computation
///      is performed off-chain by the CRE workflow. This test focuses on the
///      on-chain lifecycle that our contracts control.
contract IntegrationTest is Test {
    ChaosOracleRegistry registry;
    MockChaosCore chaosCore;
    MockStudioProxyFactory proxyFactory;
    PredictionSettlementLogic logic;
    ExamplePredictionMarket market;
    address creForwarder = address(0xC4E);
    address chaosChainRegistry = address(0xCC1);
    address rewardsDistributor = address(0x4E1);

    address alice = address(0xA11CE);   // Market creator
    address bob = address(0xB0B);       // Bettor (Yes)
    address charlie = address(0xCC);    // Bettor (No)

    function setUp() public {
        // Deploy protocol
        chaosCore = new MockChaosCore();
        proxyFactory = new MockStudioProxyFactory();
        logic = new PredictionSettlementLogic();

        registry = new ChaosOracleRegistry(
            address(chaosCore), address(logic), creForwarder,
            address(proxyFactory), chaosChainRegistry, rewardsDistributor
        );

        market = new ExamplePredictionMarket(address(registry));

        // Fund everyone
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);
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

        // canCloseStudio should return true (studio exists, not settled)
        assertTrue(registry.canCloseStudio(studioProxy));

        // Verify the studio was initialized with correct metadata
        (bool success, bytes memory data) = studioProxy.staticcall(
            abi.encodeWithSignature("question()")
        );
        assertTrue(success);
        assertEq(abi.decode(data, (string)), "Will ETH reach $10,000 by end of 2025?");

        (success, data) = studioProxy.staticcall(
            abi.encodeWithSignature("getOptionCount()")
        );
        assertTrue(success);
        assertEq(abi.decode(data, (uint256)), 2);

        // ========== Phase 4: Settlement (CRE computes consensus off-chain) ==========
        // In production, the CRE workflow would:
        //   1. Read WorkSubmitted + ScoreVectorSubmittedForWorker events from StudioProxy
        //   2. Fetch evidence from Arweave via HTTP
        //   3. Compute score-weighted consensus
        //   4. Call settleWithOutcome()
        //
        // Here we simulate the CRE calling settleWithOutcome directly with the
        // computed outcome (0 = Yes wins) and a proof hash.
        bytes32 proofHash = keccak256("QmYesEvidence1,QmYesEvidence2,QmNoEvidence1");

        vm.prank(creForwarder);
        registry.settleWithOutcome(studioProxy, 0, proofHash, creReport);

        // Verify settlement: Yes (outcome 0) should win
        (, , , , , uint8 outcome, bool settled) = market.getMarket(marketId);
        assertEq(outcome, 0); // Yes wins
        assertTrue(settled);

        // Active studios should be empty now
        activeStudios = registry.getActiveStudios();
        assertEq(activeStudios.length, 0);

        // canCloseStudio should return false (studio is settled)
        assertFalse(registry.canCloseStudio(studioProxy));

        // ========== Phase 5: Claim Winnings ==========
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
        vm.expectRevert(ExamplePredictionMarket.NoWinningBet.selector);
        market.claimWinnings(marketId);
    }

    function test_fullLifecycle_noWins() public {
        // Test settlement with outcome 1 (No wins)
        uint256 deadline = block.timestamp + 1 days;

        vm.prank(alice);
        uint256 marketId = market.createMarket{value: 10 ether}(
            "Will BTC crash?",
            deadline
        );

        vm.prank(bob);
        market.placeBet{value: 5 ether}(marketId, 0); // Yes

        vm.prank(charlie);
        market.placeBet{value: 3 ether}(marketId, 1); // No

        vm.warp(deadline + 1);

        bytes32 key = MarketKey.derive(address(market), marketId);
        bytes memory creReport = abi.encode(bytes32(0));

        vm.prank(creForwarder);
        registry.createStudioForMarket(key, creReport);

        address studioProxy = registry.keyToStudio(key);

        // CRE settles with outcome 1 (No wins)
        vm.prank(creForwarder);
        registry.settleWithOutcome(studioProxy, 1, bytes32(0), creReport);

        (, , , , , uint8 outcome, bool settled) = market.getMarket(marketId);
        assertEq(outcome, 1); // No wins
        assertTrue(settled);

        // Charlie (No) can claim
        uint256 charlieBefore = charlie.balance;
        vm.prank(charlie);
        market.claimWinnings(marketId);
        assertTrue(charlie.balance > charlieBefore);

        // Bob (Yes) cannot claim
        vm.prank(bob);
        vm.expectRevert(ExamplePredictionMarket.NoWinningBet.selector);
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

    function test_multipleMarkets_independentSettlement() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory creReport = abi.encode(bytes32(0));

        // Create two markets
        vm.prank(alice);
        uint256 id1 = market.createMarket{value: 5 ether}("Market 1?", deadline);

        vm.prank(alice);
        uint256 id2 = market.createMarket{value: 3 ether}("Market 2?", deadline);

        vm.warp(deadline + 1);

        // Create studios for both
        bytes32 key1 = MarketKey.derive(address(market), id1);
        bytes32 key2 = MarketKey.derive(address(market), id2);

        vm.prank(creForwarder);
        registry.createStudioForMarket(key1, creReport);
        vm.prank(creForwarder);
        registry.createStudioForMarket(key2, creReport);

        address studio1 = registry.keyToStudio(key1);
        address studio2 = registry.keyToStudio(key2);

        // Should have 2 active studios
        address[] memory activeStudios = registry.getActiveStudios();
        assertEq(activeStudios.length, 2);

        // Settle first market only
        vm.prank(creForwarder);
        registry.settleWithOutcome(studio1, 0, bytes32(0), creReport);

        // Should have 1 active studio
        activeStudios = registry.getActiveStudios();
        assertEq(activeStudios.length, 1);
        assertEq(activeStudios[0], studio2);

        // Settle second market
        vm.prank(creForwarder);
        registry.settleWithOutcome(studio2, 1, bytes32(0), creReport);

        // Should have 0 active studios
        activeStudios = registry.getActiveStudios();
        assertEq(activeStudios.length, 0);
    }

    /// @notice Full lifecycle including agent interactions via MockStudioProxy.
    ///         Simulates the complete flow: market → betting → studio → workers submit work →
    ///         verifiers submit scores → CRE settles → winners claim.
    function test_fullLifecycleWithAgentInteractions() public {
        // ========== Setup agents ==========
        address worker1 = makeAddr("worker1");
        address worker2 = makeAddr("worker2");
        address verifier1 = makeAddr("verifier1");
        address verifier2 = makeAddr("verifier2");

        // ========== Phase 1: Market Creation ==========
        uint256 deadline = block.timestamp + 1 days;

        vm.prank(alice);
        uint256 marketId = market.createMarket{value: 10 ether}(
            "Will ETH reach $10,000 by end of 2025?",
            deadline
        );

        // ========== Phase 2: Betting ==========
        vm.prank(bob);
        market.placeBet{value: 5 ether}(marketId, 0); // Yes

        vm.prank(charlie);
        market.placeBet{value: 3 ether}(marketId, 1); // No

        // ========== Phase 3: Studio Creation ==========
        vm.warp(deadline + 1);

        bytes32 key = MarketKey.derive(address(market), marketId);
        bytes memory creReport = abi.encode(bytes32(0));

        vm.prank(creForwarder);
        registry.createStudioForMarket(key, creReport);

        address studioAddr = registry.keyToStudio(key);
        MockStudioProxy studioProxy = MockStudioProxy(payable(studioAddr));

        // Verify reward deposited to studio
        assertEq(studioAddr.balance, 1 ether, "Studio should hold 1 ETH reward");

        // ========== Phase 4: Agent Registration ==========
        // Workers register with agentId (simulating ERC-8004 identity)
        vm.prank(worker1);
        studioProxy.registerAgent(101, 1); // agentId=101, role=worker

        vm.prank(worker2);
        studioProxy.registerAgent(102, 1); // agentId=102, role=worker

        // Verifiers register
        vm.prank(verifier1);
        studioProxy.registerAgent(201, 2); // agentId=201, role=verifier

        vm.prank(verifier2);
        studioProxy.registerAgent(202, 2); // agentId=202, role=verifier

        // Verify registration
        assertEq(studioProxy.agentIds(worker1), 101);
        assertEq(studioProxy.agentRoles(101), 1);
        assertEq(studioProxy.agentIds(verifier1), 201);
        assertEq(studioProxy.agentRoles(201), 2);

        // ========== Phase 5: Workers Submit Work ==========
        bytes32 dataHash1 = keccak256("worker1-prediction-yes-with-evidence");
        bytes32 threadRoot1 = keccak256("thread1");
        bytes32 evidenceRoot1 = keccak256("QmEvidenceWorker1");

        bytes32 dataHash2 = keccak256("worker2-prediction-no-with-evidence");
        bytes32 threadRoot2 = keccak256("thread2");
        bytes32 evidenceRoot2 = keccak256("QmEvidenceWorker2");

        // Expect WorkSubmitted events
        vm.expectEmit(true, true, false, true);
        emit MockStudioProxy.WorkSubmitted(101, dataHash1, threadRoot1, evidenceRoot1, block.timestamp);

        vm.prank(worker1);
        studioProxy.submitWork(dataHash1, threadRoot1, evidenceRoot1, "");

        vm.expectEmit(true, true, false, true);
        emit MockStudioProxy.WorkSubmitted(102, dataHash2, threadRoot2, evidenceRoot2, block.timestamp);

        vm.prank(worker2);
        studioProxy.submitWork(dataHash2, threadRoot2, evidenceRoot2, "");

        // Verify work recorded
        assertEq(studioProxy.getWorkSubmitter(dataHash1), worker1);
        assertEq(studioProxy.getWorkSubmitter(dataHash2), worker2);

        // ========== Phase 6: Verifiers Submit Scores ==========
        // Score vectors: [initiative, collaboration, reasoning, compliance, efficiency, accuracy, evidence, diversity, reasoning]
        bytes memory scores1 = abi.encode(uint8(85), uint8(70), uint8(80), uint8(90), uint8(75), uint8(95), uint8(88), uint8(72), uint8(80));
        bytes memory scores2 = abi.encode(uint8(60), uint8(65), uint8(70), uint8(80), uint8(70), uint8(55), uint8(60), uint8(50), uint8(65));

        // Verifier 1 scores both workers
        vm.expectEmit(true, true, false, true);
        emit MockStudioProxy.ScoreVectorSubmitted(201, dataHash1, scores1, block.timestamp);

        vm.prank(verifier1);
        studioProxy.submitScoreVector(dataHash1, scores1);

        vm.expectEmit(true, true, false, true);
        emit MockStudioProxy.ScoreVectorSubmitted(201, dataHash2, scores2, block.timestamp);

        vm.prank(verifier1);
        studioProxy.submitScoreVector(dataHash2, scores2);

        // Verifier 2 also scores both workers
        vm.prank(verifier2);
        studioProxy.submitScoreVector(dataHash1, scores1);

        vm.prank(verifier2);
        studioProxy.submitScoreVector(dataHash2, scores2);

        // ========== Phase 7: CRE Settles ==========
        // CRE computes weighted consensus from scores: worker1 scored higher → outcome 0 (Yes) wins
        bytes32 proofHash = keccak256("consensus-proof-from-agent-scores");

        vm.prank(creForwarder);
        registry.settleWithOutcome(studioAddr, 0, proofHash, creReport);

        // Verify settlement
        (, , , , , uint8 outcome, bool settled) = market.getMarket(marketId);
        assertEq(outcome, 0, "Yes should win based on agent consensus");
        assertTrue(settled, "Market should be settled");

        // ========== Phase 8: Claim Winnings ==========
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        market.claimWinnings(marketId);
        assertTrue(alice.balance > aliceBefore, "Alice should receive payout");

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        market.claimWinnings(marketId);
        assertTrue(bob.balance > bobBefore, "Bob should receive payout");

        // Charlie (No) cannot claim
        vm.prank(charlie);
        vm.expectRevert(ExamplePredictionMarket.NoWinningBet.selector);
        market.claimWinnings(marketId);

        console.log("=== Full lifecycle with agent interactions passed ===");
    }

    receive() external payable {}
}
