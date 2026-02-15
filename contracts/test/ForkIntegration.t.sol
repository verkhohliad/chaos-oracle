// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ChaosOracleRegistry} from "../src/ChaosOracleRegistry.sol";
import {PredictionSettlementLogic} from "../src/PredictionSettlementLogic.sol";
import {ExamplePredictionMarket} from "../src/example/ExamplePredictionMarket.sol";
import {IStudioProxy} from "@chaoschain/interfaces/IStudioProxy.sol";
import {MarketKey} from "../src/libraries/MarketKey.sol";

/// @title ForkIntegrationTest
/// @notice Full lifecycle test running against a Sepolia fork with REAL ChaosChain infrastructure.
///         Unlike Integration.t.sol (which uses MockStudioProxyFactory), this test deploys
///         StudioProxy instances through the real StudioProxyFactory on Sepolia.
///
/// @dev Worker/verifier interactions are now handled natively by StudioProxy via the
///      ChaosChain SDK + Gateway. Consensus is computed off-chain by CRE. This test
///      verifies that our contracts integrate correctly with real ChaosChain infrastructure.
///
/// Run with:
///   forge test --match-contract ForkIntegrationTest --fork-url $SEPOLIA_RPC -vvv
contract ForkIntegrationTest is Test {
    // -- Real ChaosChain addresses on Sepolia --
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

        // Create studio -- this goes through the REAL StudioProxyFactory on Sepolia
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

        // Verify the studio was initialized with metadata
        (bool success, bytes memory data) = studioProxy.staticcall(
            abi.encodeWithSignature("question()")
        );
        assertTrue(success, "question() call should succeed");
        assertEq(abi.decode(data, (string)), "Will ETH reach $10,000 by end of 2025?");

        (success, data) = studioProxy.staticcall(
            abi.encodeWithSignature("getStudioType()")
        );
        assertTrue(success, "getStudioType() call should succeed");
        assertEq(abi.decode(data, (string)), "prediction-settlement");

        // ========== Phase 4: Settlement (CRE settles with off-chain computed outcome) ==========
        bytes32 proofHash = keccak256("fork-test-proof");
        registry.settleWithOutcome(studioProxy, 0, proofHash, creReport);

        // Verify settlement: Yes (outcome 0) should win
        (, , , , , uint8 outcome, bool settled) = market.getMarket(marketId);
        assertEq(outcome, 0, "Yes should win");
        assertTrue(settled, "Market should be settled");

        // Active studios should be empty now
        activeStudios = registry.getActiveStudios();
        assertEq(activeStudios.length, 0, "No active studios after settlement");

        console.log("=== Fork Integration Test Passed ===");
        console.log("Real StudioProxy deployed and settled successfully");

        // ========== Phase 5: Claim Winnings ==========
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
        vm.expectRevert(ExamplePredictionMarket.NoWinningBet.selector);
        market.claimWinnings(marketId);

        console.log("Alice payout:", alicePayout);
        console.log("Bob payout:", bobPayout);
    }

    /// @notice Test agent interactions on a REAL StudioProxy deployed via the real factory.
    ///         Workers submit work, verifiers submit scores, then CRE settles.
    function test_studioAgentInteractionsOnFork() public {
        // ========== Setup ==========
        address worker1 = makeAddr("forkWorker1");
        address worker2 = makeAddr("forkWorker2");
        address verifier1 = makeAddr("forkVerifier1");
        address verifier2 = makeAddr("forkVerifier2");
        vm.deal(worker1, 10 ether);
        vm.deal(worker2, 10 ether);
        vm.deal(verifier1, 10 ether);
        vm.deal(verifier2, 10 ether);

        uint256 deadline = block.timestamp + 1 days;

        vm.prank(alice);
        uint256 marketId = market.createMarket{value: 10 ether}(
            "Fork agent test: Will BTC reach $200k?",
            deadline
        );

        vm.prank(bob);
        market.placeBet{value: 5 ether}(marketId, 0); // Yes

        vm.warp(deadline + 1);

        bytes32 key = MarketKey.derive(address(market), marketId);
        bytes memory creReport = abi.encode(bytes32(0));
        registry.createStudioForMarket(key, creReport);

        address studioProxy = registry.keyToStudio(key);
        assertTrue(studioProxy != address(0), "Studio proxy should be deployed");

        // Verify reward deposited
        assertEq(studioProxy.balance, 1 ether, "Studio should hold 1 ETH reward");
        console.log("Real StudioProxy for agent test:", studioProxy);

        // ========== Register agents via REAL ERC-8004 Identity Registry ==========
        // Each agent mints a real ERC-8004 identity NFT on Sepolia, then registers on StudioProxy
        uint256 worker1AgentId = _registerAgentViaERC8004(studioProxy, worker1, 1); // WORKER
        uint256 worker2AgentId = _registerAgentViaERC8004(studioProxy, worker2, 1); // WORKER
        uint256 verifier1AgentId = _registerAgentViaERC8004(studioProxy, verifier1, 2); // VERIFIER
        uint256 verifier2AgentId = _registerAgentViaERC8004(studioProxy, verifier2, 2); // VERIFIER

        console.log("Worker1 agentId (real ERC-8004):", worker1AgentId);
        console.log("Worker2 agentId (real ERC-8004):", worker2AgentId);
        console.log("Verifier1 agentId (real ERC-8004):", verifier1AgentId);
        console.log("Verifier2 agentId (real ERC-8004):", verifier2AgentId);

        // ========== Workers Submit Work ==========
        bytes32 dataHash1 = keccak256("fork-worker1-yes-evidence");
        bytes32 threadRoot1 = keccak256("fork-thread1");
        bytes32 evidenceRoot1 = keccak256("QmForkEvidence1");

        bytes32 dataHash2 = keccak256("fork-worker2-no-evidence");
        bytes32 threadRoot2 = keccak256("fork-thread2");
        bytes32 evidenceRoot2 = keccak256("QmForkEvidence2");

        vm.prank(worker1);
        (bool w1ok,) = studioProxy.call(
            abi.encodeWithSelector(
                IStudioProxy.submitWork.selector,
                dataHash1, threadRoot1, evidenceRoot1, ""
            )
        );
        assertTrue(w1ok, "Worker1 submitWork must succeed");
        console.log("Worker1 submitWork succeeded on real StudioProxy");

        // Verify work submitter
        address submitter = IStudioProxy(studioProxy).getWorkSubmitter(dataHash1);
        assertEq(submitter, worker1, "Worker1 should be recorded as submitter");

        vm.prank(worker2);
        (bool w2ok,) = studioProxy.call(
            abi.encodeWithSelector(
                IStudioProxy.submitWork.selector,
                dataHash2, threadRoot2, evidenceRoot2, ""
            )
        );
        assertTrue(w2ok, "Worker2 submitWork must succeed");

        // ========== Verifiers Submit Scores ==========
        // 5 universal dimensions (real StudioProxy expects exactly 5 + custom)
        // Use abi.encode(uint8,uint8,uint8,uint8,uint8) for 160 bytes (RD _decodeScoreVector format)
        bytes memory scoreVector1 = abi.encode(
            uint8(85), uint8(70), uint8(80), uint8(90), uint8(75)
        );

        vm.prank(verifier1);
        (bool v1ok,) = studioProxy.call(
            abi.encodeWithSelector(
                IStudioProxy.submitScoreVector.selector,
                dataHash1, scoreVector1
            )
        );
        assertTrue(v1ok, "Verifier1 submitScoreVector must succeed");
        console.log("Verifier1 submitScoreVector succeeded");

        vm.prank(verifier2);
        (bool v2ok,) = studioProxy.call(
            abi.encodeWithSelector(
                IStudioProxy.submitScoreVector.selector,
                dataHash2, scoreVector1
            )
        );
        assertTrue(v2ok, "Verifier2 submitScoreVector must succeed");

        // ========== Settle ==========
        bytes32 proofHash = keccak256("fork-agent-test-proof");
        registry.settleWithOutcome(studioProxy, 0, proofHash, creReport);

        (, , , , , uint8 outcome, bool settled) = market.getMarket(marketId);
        assertEq(outcome, 0, "Yes should win");
        assertTrue(settled, "Market should be settled");

        console.log("=== Fork Agent Interaction Test Passed ===");
    }

    /// @notice Full RewardsDistributor lifecycle on a Sepolia fork.
    ///         Exercises the REAL closeEpoch flow: register agents via real registerAgent(),
    ///         submit work/scores on the real StudioProxy, register work/validators on the real RD,
    ///         call closeEpoch, then verify consensus results, agent balances, and withdrawal.
    function test_rewardsDistributorOnFork() public {
        // ========== Phase 1: Setup & create studio ==========
        uint256 deadline = block.timestamp + 1 days;

        vm.prank(alice);
        uint256 marketId = market.createMarket{value: 10 ether}(
            "RD test: Will SOL flip ETH?",
            deadline
        );

        vm.prank(bob);
        market.placeBet{value: 5 ether}(marketId, 0);

        vm.warp(deadline + 1);

        bytes32 key = MarketKey.derive(address(market), marketId);
        bytes memory creReport = abi.encode(bytes32(0));
        registry.createStudioForMarket(key, creReport);

        address studioProxy = registry.keyToStudio(key);
        assertTrue(studioProxy != address(0), "Studio proxy should be deployed");
        assertEq(studioProxy.balance, 1 ether, "Studio should hold 1 ETH reward");
        console.log("Real StudioProxy for RD test:", studioProxy);

        // ========== Phase 2: Verify RD contract exists ==========
        assertTrue(REWARDS_DISTRIBUTOR.code.length > 0, "RewardsDistributor must have code on Sepolia");
        console.log("RewardsDistributor code size:", REWARDS_DISTRIBUTOR.code.length);

        // ========== Phase 3: Register agents via REAL ERC-8004 Identity Registry ==========
        address worker1 = makeAddr("forkRDworker1");
        address verifier1 = makeAddr("forkRDverifier1");
        address verifier2 = makeAddr("forkRDverifier2");
        vm.deal(worker1, 10 ether);
        vm.deal(verifier1, 10 ether);
        vm.deal(verifier2, 10 ether);

        // Each agent mints a real ERC-8004 identity NFT, then registers on StudioProxy
        uint256 workerAgentId = _registerAgentViaERC8004(studioProxy, worker1, 1); // WORKER
        uint256 verifier1AgentId = _registerAgentViaERC8004(studioProxy, verifier1, 2); // VERIFIER
        uint256 verifier2AgentId = _registerAgentViaERC8004(studioProxy, verifier2, 2); // VERIFIER

        console.log("Worker agentId (real ERC-8004):", workerAgentId);
        console.log("Verifier1 agentId (real ERC-8004):", verifier1AgentId);
        console.log("Verifier2 agentId (real ERC-8004):", verifier2AgentId);
        console.log("Agent registration via real ERC-8004 + registerAgent() succeeded");

        // ========== Phase 4: Submit work on real StudioProxy ==========
        bytes32 dataHash = keccak256("rd-fork-work-1");
        bytes32 threadRoot = keccak256("rd-fork-thread");
        bytes32 evidenceRoot = keccak256("rd-fork-evidence");

        vm.prank(worker1);
        (bool workOk,) = studioProxy.call(
            abi.encodeWithSelector(IStudioProxy.submitWork.selector, dataHash, threadRoot, evidenceRoot, "")
        );
        assertTrue(workOk, "Worker submitWork must succeed");
        console.log("Worker1 submitWork succeeded");

        // ========== Phase 5: Submit score vectors via submitScoreVectorForWorker ==========
        // RD.closeEpoch reads per-worker scores via getScoreVectorsForWorker(dataHash, worker)
        // which reads from _scoreVectorsPerWorker, so verifiers must use submitScoreVectorForWorker()
        // 5 universal dimensions, abi.encode format for RD _decodeScoreVector (160 bytes)
        //
        // IMPORTANT: Both validators must submit identical scores. The RD's validator reward
        // formula uses integer division: weight = PRECISION / (PRECISION + errorSquared).
        // Since PRECISION = 1e6, any non-zero error makes the denominator > numerator,
        // causing weight to floor to 0. Only validators with exactly 0 error get rewards.
        bytes memory validatorScores = abi.encode(
            uint8(85), uint8(80), uint8(90), uint8(75), uint8(88)
        );

        vm.prank(verifier1);
        (bool sv1ok,) = studioProxy.call(
            abi.encodeWithSignature(
                "submitScoreVectorForWorker(bytes32,address,bytes)",
                dataHash, worker1, validatorScores
            )
        );
        assertTrue(sv1ok, "Verifier1 submitScoreVectorForWorker must succeed");

        vm.prank(verifier2);
        (bool sv2ok,) = studioProxy.call(
            abi.encodeWithSignature(
                "submitScoreVectorForWorker(bytes32,address,bytes)",
                dataHash, worker1, validatorScores
            )
        );
        assertTrue(sv2ok, "Verifier2 submitScoreVectorForWorker must succeed");
        console.log("Both verifiers submitted per-worker scores");

        // ========== Phase 6: Register work & validators on real RD ==========
        address rdOwner = _getRDOwner();
        assertTrue(rdOwner != address(0), "RD owner must be non-zero");
        vm.deal(rdOwner, 10 ether);

        // registerWork(studio, epoch, dataHash) - onlyOwner
        vm.prank(rdOwner);
        (bool rwOk,) = REWARDS_DISTRIBUTOR.call(
            abi.encodeWithSignature("registerWork(address,uint64,bytes32)", studioProxy, uint64(0), dataHash)
        );
        assertTrue(rwOk, "registerWork on real RD must succeed");

        // registerValidator(dataHash, validator) - onlyOwner
        vm.startPrank(rdOwner);
        (bool rv1ok,) = REWARDS_DISTRIBUTOR.call(
            abi.encodeWithSignature("registerValidator(bytes32,address)", dataHash, verifier1)
        );
        assertTrue(rv1ok, "registerValidator(verifier1) on real RD must succeed");

        (bool rv2ok,) = REWARDS_DISTRIBUTOR.call(
            abi.encodeWithSignature("registerValidator(bytes32,address)", dataHash, verifier2)
        );
        assertTrue(rv2ok, "registerValidator(verifier2) on real RD must succeed");
        vm.stopPrank();
        console.log("Work and validators registered on real RD");

        // ========== Phase 7: Call closeEpoch on the REAL RewardsDistributor ==========
        vm.prank(rdOwner);
        (bool epochOk,) = REWARDS_DISTRIBUTOR.call(
            abi.encodeWithSignature("closeEpoch(address,uint64)", studioProxy, uint64(0))
        );
        assertTrue(epochOk, "closeEpoch on real RD must succeed");
        console.log("closeEpoch SUCCEEDED on real RewardsDistributor!");

        // ========== Phase 8: Verify consensus results ==========
        // RD stores per-worker consensus at keccak256(abi.encodePacked(dataHash, worker))
        bytes32 workerDataHash = keccak256(abi.encodePacked(dataHash, worker1));
        (bool crOk, bytes memory crData) = REWARDS_DISTRIBUTOR.staticcall(
            abi.encodeWithSignature("getConsensusResult(bytes32)", workerDataHash)
        );
        assertTrue(crOk, "getConsensusResult must succeed");
        assertTrue(crData.length > 64, "Consensus result must have meaningful data");
        console.log("Consensus result retrieved from real RD");

        // ========== Phase 9: Verify agent withdrawable balances ==========
        (bool wbOk, bytes memory wbData) = studioProxy.staticcall(
            abi.encodeWithSignature("getWithdrawableBalance(address)", worker1)
        );
        assertTrue(wbOk, "getWithdrawableBalance must succeed for worker");
        uint256 workerWithdrawable = abi.decode(wbData, (uint256));
        assertTrue(workerWithdrawable > 0, "Worker must have withdrawable balance after closeEpoch");
        console.log("Worker withdrawable balance:", workerWithdrawable);

        // Verify budget split: worker pool = 85% of getTotalEscrow()
        // getTotalEscrow() includes 1 ETH reward + agent stakes (0.3 ETH) = 1.3 ETH
        // Actual worker reward = workerPool * contributionWeight * qualityScalar / (10000 * 100)
        // With identical high scores, qualityScalar should be close to the universal avg
        uint256 fullEscrow = 1 ether + 0.3 ether; // reward + 3 agent stakes
        assertTrue(
            workerWithdrawable <= (fullEscrow * 8500) / 10000,
            "Worker reward must not exceed 85% of total escrow"
        );

        (bool vbOk, bytes memory vbData) = studioProxy.staticcall(
            abi.encodeWithSignature("getWithdrawableBalance(address)", verifier1)
        );
        assertTrue(vbOk, "getWithdrawableBalance must succeed for verifier1");
        uint256 verifier1Withdrawable = abi.decode(vbData, (uint256));
        assertTrue(verifier1Withdrawable > 0, "Verifier1 must have withdrawable balance after closeEpoch");
        console.log("Verifier1 withdrawable balance:", verifier1Withdrawable);

        // Both verifiers submitted identical scores -> both have 0 error -> equal rewards
        (, bytes memory v2bData) = studioProxy.staticcall(
            abi.encodeWithSignature("getWithdrawableBalance(address)", verifier2)
        );
        uint256 verifier2Withdrawable = abi.decode(v2bData, (uint256));
        assertTrue(verifier2Withdrawable > 0, "Verifier2 must have withdrawable balance after closeEpoch");
        assertEq(verifier1Withdrawable, verifier2Withdrawable, "Both verifiers must get equal rewards (identical scores)");
        console.log("Verifier2 withdrawable balance:", verifier2Withdrawable);

        // ========== Phase 10: Verify withdrawal ==========
        uint256 workerBalBefore = worker1.balance;
        vm.prank(worker1);
        (bool withdrawOk,) = studioProxy.call(
            abi.encodeWithSignature("withdraw()")
        );
        assertTrue(withdrawOk, "Worker withdraw must succeed");

        uint256 workerGain = worker1.balance - workerBalBefore;
        assertTrue(workerGain > 0, "Worker must receive ETH from withdrawal");
        assertEq(workerGain, workerWithdrawable, "Worker must receive exact withdrawable amount");
        console.log("Worker withdrew:", workerGain);

        // Verify balance is 0 after withdrawal
        (, bytes memory postData) = studioProxy.staticcall(
            abi.encodeWithSignature("getWithdrawableBalance(address)", worker1)
        );
        assertEq(abi.decode(postData, (uint256)), 0, "Worker withdrawable must be 0 after withdrawal");

        // Verifier1 withdraws
        uint256 verifier1BalBefore = verifier1.balance;
        vm.prank(verifier1);
        (bool v1WithdrawOk,) = studioProxy.call(
            abi.encodeWithSignature("withdraw()")
        );
        assertTrue(v1WithdrawOk, "Verifier1 withdraw must succeed");

        uint256 verifier1Gain = verifier1.balance - verifier1BalBefore;
        assertTrue(verifier1Gain > 0, "Verifier1 must receive ETH from withdrawal");
        assertEq(verifier1Gain, verifier1Withdrawable, "Verifier1 must receive exact withdrawable amount");
        console.log("Verifier1 withdrew:", verifier1Gain);

        // Verifier2 withdraws
        uint256 verifier2BalBefore = verifier2.balance;
        vm.prank(verifier2);
        (bool v2WithdrawOk,) = studioProxy.call(
            abi.encodeWithSignature("withdraw()")
        );
        assertTrue(v2WithdrawOk, "Verifier2 withdraw must succeed");
        assertEq(verifier2.balance - verifier2BalBefore, verifier2Withdrawable, "Verifier2 must receive exact withdrawable amount");
        console.log("Verifier2 withdrew:", verifier2.balance - verifier2BalBefore);

        // ========== Settle the market ==========
        registry.settleWithOutcome(studioProxy, 0, keccak256("rd-test-proof"), creReport);

        (, , , , , uint8 outcome, bool settled) = market.getMarket(marketId);
        assertEq(outcome, 0, "Yes should win");
        assertTrue(settled, "Market should be settled");

        console.log("=== RewardsDistributor Fork Test Passed ===");
    }

    /// @notice Focused test on the agent withdrawal flow after closeEpoch.
    ///         Verifies each agent can withdraw independently after the RD processes rewards.
    function test_agentWithdrawOnFork() public {
        // ========== Setup: create studio ==========
        uint256 deadline = block.timestamp + 1 days;

        vm.prank(alice);
        uint256 marketId = market.createMarket{value: 20 ether}(
            "Withdraw test: Will DOGE hit $1?",
            deadline
        );

        vm.warp(deadline + 1);

        bytes32 key = MarketKey.derive(address(market), marketId);
        bytes memory creReport = abi.encode(bytes32(0));
        registry.createStudioForMarket(key, creReport);

        address studioProxy = registry.keyToStudio(key);
        assertTrue(studioProxy != address(0), "Studio proxy must be deployed");
        assertEq(studioProxy.balance, 2 ether, "Studio should hold 2 ETH reward");

        // ========== Register agents via REAL ERC-8004 Identity Registry ==========
        address worker = makeAddr("withdrawWorker");
        address verifier = makeAddr("withdrawVerifier");
        vm.deal(worker, 10 ether);
        vm.deal(verifier, 10 ether);

        // Each agent mints a real ERC-8004 identity NFT, then registers on StudioProxy
        uint256 workerId = _registerAgentViaERC8004(studioProxy, worker, 1); // WORKER
        uint256 verifierId = _registerAgentViaERC8004(studioProxy, verifier, 2); // VERIFIER
        console.log("Worker agentId (real ERC-8004):", workerId);
        console.log("Verifier agentId (real ERC-8004):", verifierId);

        // ========== Submit work ==========
        bytes32 dataHash = keccak256("withdraw-fork-work");
        bytes32 threadRoot = keccak256("withdraw-thread");
        bytes32 evidenceRoot = keccak256("withdraw-evidence");

        vm.prank(worker);
        (bool workOk,) = studioProxy.call(
            abi.encodeWithSelector(IStudioProxy.submitWork.selector, dataHash, threadRoot, evidenceRoot, "")
        );
        assertTrue(workOk, "Worker submitWork must succeed");

        // Submit per-worker scores (RD reads from _scoreVectorsPerWorker)
        bytes memory scores = abi.encode(
            uint8(90), uint8(85), uint8(88), uint8(80), uint8(92)
        );
        vm.prank(verifier);
        (bool scoreOk,) = studioProxy.call(
            abi.encodeWithSignature(
                "submitScoreVectorForWorker(bytes32,address,bytes)",
                dataHash, worker, scores
            )
        );
        assertTrue(scoreOk, "Verifier submitScoreVectorForWorker must succeed");

        // ========== Register on RD and close epoch ==========
        address rdOwner = _getRDOwner();
        assertTrue(rdOwner != address(0), "RD owner must be non-zero");
        vm.deal(rdOwner, 10 ether);

        vm.startPrank(rdOwner);
        (bool rwOk,) = REWARDS_DISTRIBUTOR.call(
            abi.encodeWithSignature("registerWork(address,uint64,bytes32)", studioProxy, uint64(0), dataHash)
        );
        assertTrue(rwOk, "registerWork on real RD must succeed");

        (bool rvOk,) = REWARDS_DISTRIBUTOR.call(
            abi.encodeWithSignature("registerValidator(bytes32,address)", dataHash, verifier)
        );
        assertTrue(rvOk, "registerValidator on real RD must succeed");
        vm.stopPrank();

        // ========== Close epoch via REAL RD ==========
        vm.prank(rdOwner);
        (bool epochOk,) = REWARDS_DISTRIBUTOR.call(
            abi.encodeWithSignature("closeEpoch(address,uint64)", studioProxy, uint64(0))
        );
        assertTrue(epochOk, "closeEpoch on real RD must succeed");
        console.log("closeEpoch succeeded!");

        // ========== Verify both agents can withdraw independently ==========

        // Worker withdrawal
        (bool wbOk, bytes memory wbData) = studioProxy.staticcall(
            abi.encodeWithSignature("getWithdrawableBalance(address)", worker)
        );
        assertTrue(wbOk, "getWithdrawableBalance must succeed for worker");
        uint256 workerWithdrawable = abi.decode(wbData, (uint256));
        assertTrue(workerWithdrawable > 0, "Worker must have rewards after closeEpoch");
        console.log("Worker withdrawable:", workerWithdrawable);

        uint256 workerBalBefore = worker.balance;
        vm.prank(worker);
        (bool wOk,) = studioProxy.call(abi.encodeWithSignature("withdraw()"));
        assertTrue(wOk, "Worker withdraw must succeed");
        assertEq(worker.balance - workerBalBefore, workerWithdrawable, "Worker must receive exact withdrawable amount");

        // Verify worker balance is 0 after withdrawal
        (, bytes memory postWorker) = studioProxy.staticcall(
            abi.encodeWithSignature("getWithdrawableBalance(address)", worker)
        );
        assertEq(abi.decode(postWorker, (uint256)), 0, "Worker withdrawable must be 0 after withdrawal");

        // Verifier withdrawal
        (bool vbOk, bytes memory vbData) = studioProxy.staticcall(
            abi.encodeWithSignature("getWithdrawableBalance(address)", verifier)
        );
        assertTrue(vbOk, "getWithdrawableBalance must succeed for verifier");
        uint256 verifierWithdrawable = abi.decode(vbData, (uint256));
        assertTrue(verifierWithdrawable > 0, "Verifier must have rewards after closeEpoch");
        console.log("Verifier withdrawable:", verifierWithdrawable);

        uint256 verifierBalBefore = verifier.balance;
        vm.prank(verifier);
        (bool vOk,) = studioProxy.call(abi.encodeWithSignature("withdraw()"));
        assertTrue(vOk, "Verifier withdraw must succeed");
        assertEq(verifier.balance - verifierBalBefore, verifierWithdrawable, "Verifier must receive exact withdrawable amount");

        // Verify total distributed does not exceed escrow
        uint256 totalDistributed = workerWithdrawable + verifierWithdrawable;
        assertTrue(totalDistributed <= 2 ether, "Total distributed must not exceed studio escrow");
        console.log("Total distributed:", totalDistributed, "/ 2 ETH escrow");

        // Verify double-withdraw reverts (no funds remaining)
        vm.prank(worker);
        (bool doubleOk,) = studioProxy.call(abi.encodeWithSignature("withdraw()"));
        assertTrue(!doubleOk, "Double withdraw must revert");

        // ========== Settle ==========
        registry.settleWithOutcome(studioProxy, 0, keccak256("withdraw-proof"), creReport);

        (, , , , , uint8 outcome, bool settled) = market.getMarket(marketId);
        assertEq(outcome, 0, "Yes should win");
        assertTrue(settled, "Market should be settled");

        console.log("=== Agent Withdraw Fork Test Passed ===");
    }

    // ============ Internal Helpers ============

    /// @dev Get the real ERC-8004 Identity Registry address from the on-chain ChaosChainRegistry.
    function _getIdentityRegistry() internal view returns (address) {
        (bool ok, bytes memory data) = CHAOSCHAIN_REGISTRY.staticcall(
            abi.encodeWithSignature("getIdentityRegistry()")
        );
        require(ok && data.length >= 32, "Failed to get identity registry from ChaosChainRegistry");
        address identityRegistry = abi.decode(data, (address));
        require(identityRegistry != address(0), "Identity registry address is zero");
        return identityRegistry;
    }

    /// @dev Register an agent on the real ERC-8004 Identity Registry and then on the StudioProxy.
    ///      1. Calls identityRegistry.register() to mint an ERC-8004 identity NFT for the agent
    ///      2. Calls studioProxy.registerAgent(agentId, role) with the minted agentId + ETH stake
    ///      Returns the agentId from the real identity registry.
    function _registerAgentViaERC8004(
        address studioProxyAddr,
        address agent,
        uint8 role // 1 = WORKER, 2 = VERIFIER
    ) internal returns (uint256 agentId) {
        address identityRegistry = _getIdentityRegistry();

        // Step 1: Mint ERC-8004 identity NFT on real identity registry
        vm.prank(agent);
        (bool regOk, bytes memory regData) = identityRegistry.call(
            abi.encodeWithSignature("register()")
        );
        assertTrue(regOk, "ERC-8004 register() must succeed");
        agentId = abi.decode(regData, (uint256));
        assertTrue(agentId > 0, "ERC-8004 agentId must be > 0");

        // Verify ownership on real identity registry
        (bool ownerOk, bytes memory ownerData) = identityRegistry.staticcall(
            abi.encodeWithSignature("ownerOf(uint256)", agentId)
        );
        assertTrue(ownerOk, "ownerOf must succeed");
        assertEq(abi.decode(ownerData, (address)), agent, "Agent must own their ERC-8004 identity NFT");

        // Step 2: Register agent on real StudioProxy with ETH stake
        vm.prank(agent);
        (bool studioRegOk,) = studioProxyAddr.call{value: 0.1 ether}(
            abi.encodeWithSignature("registerAgent(uint256,uint8)", agentId, role)
        );
        assertTrue(studioRegOk, "StudioProxy registerAgent must succeed");

        // Verify agent ID stored correctly on StudioProxy
        (bool getOk, bytes memory getData) = studioProxyAddr.staticcall(
            abi.encodeWithSignature("getAgentId(address)", agent)
        );
        assertTrue(getOk, "getAgentId must succeed");
        assertEq(abi.decode(getData, (uint256)), agentId, "StudioProxy must store correct agentId");
    }

    /// @dev Get the RD owner address on Sepolia
    function _getRDOwner() internal view returns (address) {
        (bool ok, bytes memory data) = REWARDS_DISTRIBUTOR.staticcall(
            abi.encodeWithSignature("owner()")
        );
        require(ok && data.length >= 32, "Failed to get RD owner");
        return abi.decode(data, (address));
    }

    receive() external payable {}
}
