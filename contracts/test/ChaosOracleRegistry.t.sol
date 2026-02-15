// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChaosOracleRegistry} from "../src/ChaosOracleRegistry.sol";
import {IChaosOracleRegistry} from "../src/interfaces/IChaosOracleRegistry.sol";
import {PredictionSettlementLogic} from "../src/PredictionSettlementLogic.sol";
import {MockChaosCore, MockStudioProxyFactory, MockStudioProxy} from "./mocks/MockChaosCore.sol";
import {MockPredictionMarket} from "./mocks/MockPredictionMarket.sol";
import {MarketKey} from "../src/libraries/MarketKey.sol";

contract ChaosOracleRegistryTest is Test {
    ChaosOracleRegistry registry;
    MockChaosCore chaosCore;
    MockStudioProxyFactory proxyFactory;
    PredictionSettlementLogic logic;
    address creForwarder = address(0xC4E);
    address chaosChainRegistry = address(0xCC1);
    address rewardsDistributor = address(0x4E1);
    address owner;

    function setUp() public {
        owner = address(this);

        chaosCore = new MockChaosCore();
        proxyFactory = new MockStudioProxyFactory();
        logic = new PredictionSettlementLogic();

        registry = new ChaosOracleRegistry(
            address(chaosCore),
            address(logic),
            creForwarder,
            address(proxyFactory),
            chaosChainRegistry,
            rewardsDistributor
        );
    }

    // ============ Constructor Tests ============

    function test_constructor() public view {
        assertEq(registry.chaosCore(), address(chaosCore));
        assertEq(registry.logicModuleTemplate(), address(logic));
        assertEq(registry.creForwarder(), creForwarder);
        assertEq(registry.studioProxyFactory(), address(proxyFactory));
        assertEq(registry.chaosChainRegistry(), chaosChainRegistry);
        assertEq(registry.rewardsDistributor(), rewardsDistributor);
        assertEq(registry.owner(), owner);
    }

    function test_constructor_revertsZeroChaosCore() public {
        vm.expectRevert(ChaosOracleRegistry.ZeroAddress.selector);
        new ChaosOracleRegistry(address(0), address(logic), creForwarder, address(proxyFactory), chaosChainRegistry, rewardsDistributor);
    }

    function test_constructor_revertsZeroLogicModule() public {
        vm.expectRevert(ChaosOracleRegistry.ZeroAddress.selector);
        new ChaosOracleRegistry(address(chaosCore), address(0), creForwarder, address(proxyFactory), chaosChainRegistry, rewardsDistributor);
    }

    function test_constructor_revertsZeroCreForwarder() public {
        vm.expectRevert(ChaosOracleRegistry.ZeroAddress.selector);
        new ChaosOracleRegistry(address(chaosCore), address(logic), address(0), address(proxyFactory), chaosChainRegistry, rewardsDistributor);
    }

    // ============ Admin Tests ============

    function test_setAuthorizedWorkflowId() public {
        bytes32 wfId = bytes32("workflow-123");
        registry.setAuthorizedWorkflowId(wfId);
        assertEq(registry.authorizedWorkflowId(), wfId);
    }

    function test_setAuthorizedWorkflowId_revertsNonOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        registry.setAuthorizedWorkflowId(bytes32("workflow-123"));
    }

    // ============ Market Registration Tests ============

    function test_registerForSettlement() public {
        string[] memory opts = new string[](2);
        opts[0] = "Yes";
        opts[1] = "No";

        uint256 deadline = block.timestamp + 1 days;

        registry.registerForSettlement{value: 1 ether}(
            1, "Will ETH hit $5000?", opts, deadline
        );

        bytes32 key = MarketKey.derive(address(this), 1);
        // Auto-generated getter: (market, marketId, question, deadline, reward, exists)
        // Note: string[] options is skipped
        (address mkt, uint256 mid, string memory q, uint256 storedDeadline, uint256 reward, bool exists) =
            registry.pendingMarkets(key);

        assertEq(mkt, address(this));
        assertEq(mid, 1);
        assertEq(q, "Will ETH hit $5000?");
        assertEq(storedDeadline, deadline);
        assertEq(reward, 1 ether);
        assertTrue(exists);
    }

    function test_registerForSettlement_revertsNoReward() public {
        string[] memory opts = new string[](2);
        opts[0] = "Yes";
        opts[1] = "No";
        vm.expectRevert(ChaosOracleRegistry.NoReward.selector);
        registry.registerForSettlement(1, "Q?", opts, block.timestamp + 1);
    }

    function test_registerForSettlement_revertsEmptyQuestion() public {
        string[] memory opts = new string[](2);
        opts[0] = "Yes";
        opts[1] = "No";
        vm.expectRevert(ChaosOracleRegistry.EmptyQuestion.selector);
        registry.registerForSettlement{value: 1 ether}(1, "", opts, block.timestamp + 1);
    }

    function test_registerForSettlement_revertsTooFewOptions() public {
        string[] memory opts = new string[](1);
        opts[0] = "Yes";
        vm.expectRevert(ChaosOracleRegistry.TooFewOptions.selector);
        registry.registerForSettlement{value: 1 ether}(1, "Q?", opts, block.timestamp + 1);
    }

    function test_registerForSettlement_revertsDeadlineInPast() public {
        string[] memory opts = new string[](2);
        opts[0] = "Yes";
        opts[1] = "No";
        vm.expectRevert(ChaosOracleRegistry.DeadlineInPast.selector);
        registry.registerForSettlement{value: 1 ether}(1, "Q?", opts, block.timestamp - 1);
    }

    function test_registerForSettlement_revertsDuplicate() public {
        string[] memory opts = new string[](2);
        opts[0] = "Yes";
        opts[1] = "No";
        uint256 deadline = block.timestamp + 1 days;

        registry.registerForSettlement{value: 1 ether}(1, "Q?", opts, deadline);

        vm.expectRevert(ChaosOracleRegistry.AlreadyRegistered.selector);
        registry.registerForSettlement{value: 1 ether}(1, "Q?", opts, deadline);
    }

    // ============ getMarketsReadyForSettlement Tests ============

    function test_getMarketsReadyForSettlement_empty() public view {
        bytes32[] memory keys = registry.getMarketsReadyForSettlement();
        assertEq(keys.length, 0);
    }

    function test_getMarketsReadyForSettlement_afterDeadline() public {
        string[] memory opts = new string[](2);
        opts[0] = "Yes";
        opts[1] = "No";
        uint256 deadline = block.timestamp + 1 hours;

        registry.registerForSettlement{value: 1 ether}(1, "Q?", opts, deadline);

        // Before deadline - should be empty
        bytes32[] memory keysBefore = registry.getMarketsReadyForSettlement();
        assertEq(keysBefore.length, 0);

        // After deadline - should have one
        vm.warp(deadline + 1);
        bytes32[] memory keysAfter = registry.getMarketsReadyForSettlement();
        assertEq(keysAfter.length, 1);
        assertEq(keysAfter[0], MarketKey.derive(address(this), 1));
    }

    // ============ CRE Access Control Tests ============

    function test_createStudioForMarket_revertsNotCRE() public {
        vm.expectRevert(ChaosOracleRegistry.NotCREForwarder.selector);
        registry.createStudioForMarket(bytes32("key"), bytes(""));
    }

    function test_settleWithOutcome_revertsNotCRE() public {
        vm.expectRevert(ChaosOracleRegistry.NotCREForwarder.selector);
        registry.settleWithOutcome(address(0x1), 0, bytes32(0), bytes(""));
    }

    function test_createStudioForMarket_revertsWrongWorkflowId() public {
        registry.setAuthorizedWorkflowId(bytes32("correct-id"));

        bytes memory creReport = abi.encode(bytes32("wrong-id"));
        vm.prank(creForwarder);
        vm.expectRevert(ChaosOracleRegistry.UnauthorizedWorkflow.selector);
        registry.createStudioForMarket(bytes32("key"), creReport);
    }

    // ============ Studio Creation Tests ============

    function test_createStudioForMarket() public {
        // Setup: register a market
        MockPredictionMarket market = new MockPredictionMarket(address(registry));
        vm.deal(address(market), 10 ether);
        string[] memory opts = new string[](2);
        opts[0] = "Yes";
        opts[1] = "No";
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(address(market));
        registry.registerForSettlement{value: 1 ether}(1, "Will ETH hit $5000?", opts, deadline);

        bytes32 key = MarketKey.derive(address(market), 1);

        // Warp past deadline
        vm.warp(deadline + 1);

        // Create studio as CRE
        bytes memory creReport = abi.encode(bytes32(0));
        vm.prank(creForwarder);
        registry.createStudioForMarket(key, creReport);

        // Verify studio was created
        address studioAddr = registry.keyToStudio(key);
        assertTrue(studioAddr != address(0));

        // Verify active studio tracking
        (bytes32 storedKey, address studio, , address storedMarket, uint256 storedMarketId, bool settled) =
            registry.activeStudios(studioAddr);
        assertEq(storedKey, key);
        assertEq(studio, studioAddr);
        assertEq(storedMarket, address(market));
        assertEq(storedMarketId, 1);
        assertFalse(settled);

        // Verify registry is the authorized caller for settlement (no separate settler needed)
    }

    function test_createStudioForMarket_revertsBeforeDeadline() public {
        MockPredictionMarket market = new MockPredictionMarket(address(registry));
        vm.deal(address(market), 10 ether);
        string[] memory opts = new string[](2);
        opts[0] = "Yes";
        opts[1] = "No";
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(address(market));
        registry.registerForSettlement{value: 1 ether}(1, "Q?", opts, deadline);

        bytes32 key = MarketKey.derive(address(market), 1);
        bytes memory creReport = abi.encode(bytes32(0));

        vm.prank(creForwarder);
        vm.expectRevert(ChaosOracleRegistry.DeadlineNotReached.selector);
        registry.createStudioForMarket(key, creReport);
    }

    // ============ settleWithOutcome Tests ============

    function test_settleWithOutcome() public {
        // Setup: register market, create studio
        MockPredictionMarket market = new MockPredictionMarket(address(registry));
        vm.deal(address(market), 10 ether);
        string[] memory opts = new string[](2);
        opts[0] = "Yes";
        opts[1] = "No";
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(address(market));
        registry.registerForSettlement{value: 1 ether}(1, "Will ETH hit $5000?", opts, deadline);

        bytes32 key = MarketKey.derive(address(market), 1);
        vm.warp(deadline + 1);

        bytes memory creReport = abi.encode(bytes32(0));
        vm.prank(creForwarder);
        registry.createStudioForMarket(key, creReport);

        address studioAddr = registry.keyToStudio(key);

        // Settle with outcome 0 (Yes)
        bytes32 proofHash = keccak256("evidence-proof");
        vm.prank(creForwarder);
        registry.settleWithOutcome(studioAddr, 0, proofHash, creReport);

        // Verify studio is settled
        (, , , , , bool settled) = registry.activeStudios(studioAddr);
        assertTrue(settled);

        // Verify market received the settlement
        assertTrue(market.wasSettled(1));
        MockPredictionMarket.SettlementRecord memory record = market.getSettlement(1);
        assertEq(record.outcome, 0);
        assertEq(record.proofHash, proofHash);
        assertEq(record.caller, address(registry)); // Registry calls onSettlement directly
    }

    function test_settleWithOutcome_revertsNotActiveStudio() public {
        bytes memory creReport = abi.encode(bytes32(0));
        vm.prank(creForwarder);
        vm.expectRevert(ChaosOracleRegistry.NotActiveStudio.selector);
        registry.settleWithOutcome(address(0x123), 0, bytes32(0), creReport);
    }

    function test_settleWithOutcome_revertsAlreadySettled() public {
        // Setup: register market, create studio, settle once
        MockPredictionMarket market = new MockPredictionMarket(address(registry));
        vm.deal(address(market), 10 ether);
        string[] memory opts = new string[](2);
        opts[0] = "Yes";
        opts[1] = "No";
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(address(market));
        registry.registerForSettlement{value: 1 ether}(1, "Q?", opts, deadline);

        bytes32 key = MarketKey.derive(address(market), 1);
        vm.warp(deadline + 1);

        bytes memory creReport = abi.encode(bytes32(0));
        vm.prank(creForwarder);
        registry.createStudioForMarket(key, creReport);

        address studioAddr = registry.keyToStudio(key);

        // First settlement succeeds
        vm.prank(creForwarder);
        registry.settleWithOutcome(studioAddr, 0, bytes32(0), creReport);

        // Second settlement should revert
        vm.prank(creForwarder);
        vm.expectRevert(ChaosOracleRegistry.StudioAlreadySettled.selector);
        registry.settleWithOutcome(studioAddr, 1, bytes32(0), creReport);
    }

    function test_settleWithOutcome_emitsEvent() public {
        // Setup: register market, create studio
        MockPredictionMarket market = new MockPredictionMarket(address(registry));
        vm.deal(address(market), 10 ether);
        string[] memory opts = new string[](2);
        opts[0] = "Yes";
        opts[1] = "No";
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(address(market));
        registry.registerForSettlement{value: 1 ether}(1, "Q?", opts, deadline);

        bytes32 key = MarketKey.derive(address(market), 1);
        vm.warp(deadline + 1);

        bytes memory creReport = abi.encode(bytes32(0));
        vm.prank(creForwarder);
        registry.createStudioForMarket(key, creReport);

        address studioAddr = registry.keyToStudio(key);
        bytes32 proofHash = keccak256("proof");

        // Expect the StudioSettled event
        vm.expectEmit(true, true, false, true);
        emit IChaosOracleRegistry.StudioSettled(studioAddr, key, 1, proofHash);

        vm.prank(creForwarder);
        registry.settleWithOutcome(studioAddr, 1, proofHash, creReport);
    }

    // ============ View Tests ============

    function test_getActiveStudios_empty() public view {
        address[] memory studios = registry.getActiveStudios();
        assertEq(studios.length, 0);
    }

    function test_getActiveStudios_excludesSettled() public {
        // Setup: register market, create studio, settle it
        MockPredictionMarket market = new MockPredictionMarket(address(registry));
        vm.deal(address(market), 10 ether);
        string[] memory opts = new string[](2);
        opts[0] = "Yes";
        opts[1] = "No";
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(address(market));
        registry.registerForSettlement{value: 1 ether}(1, "Q?", opts, deadline);

        bytes32 key = MarketKey.derive(address(market), 1);
        vm.warp(deadline + 1);

        bytes memory creReport = abi.encode(bytes32(0));
        vm.prank(creForwarder);
        registry.createStudioForMarket(key, creReport);

        address studioAddr = registry.keyToStudio(key);

        // Should have 1 active studio
        address[] memory studios = registry.getActiveStudios();
        assertEq(studios.length, 1);
        assertEq(studios[0], studioAddr);

        // Settle it
        vm.prank(creForwarder);
        registry.settleWithOutcome(studioAddr, 0, bytes32(0), creReport);

        // Should have 0 active studios
        studios = registry.getActiveStudios();
        assertEq(studios.length, 0);
    }

    function test_canCloseStudio_nonExistent() public view {
        assertFalse(registry.canCloseStudio(address(0x123)));
    }

    function test_canCloseStudio_activeStudio() public {
        // Setup: register market, create studio
        MockPredictionMarket market = new MockPredictionMarket(address(registry));
        vm.deal(address(market), 10 ether);
        string[] memory opts = new string[](2);
        opts[0] = "Yes";
        opts[1] = "No";
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(address(market));
        registry.registerForSettlement{value: 1 ether}(1, "Q?", opts, deadline);

        bytes32 key = MarketKey.derive(address(market), 1);
        vm.warp(deadline + 1);

        bytes memory creReport = abi.encode(bytes32(0));
        vm.prank(creForwarder);
        registry.createStudioForMarket(key, creReport);

        address studioAddr = registry.keyToStudio(key);

        // Active and unsettled: canClose should be true
        assertTrue(registry.canCloseStudio(studioAddr));

        // After settlement: canClose should be false
        vm.prank(creForwarder);
        registry.settleWithOutcome(studioAddr, 0, bytes32(0), creReport);
        assertFalse(registry.canCloseStudio(studioAddr));
    }

    // ============ Studio Escrow Deposit Tests ============

    function test_createStudioForMarket_depositsReward() public {
        // Setup: register a market with 1 ETH reward
        MockPredictionMarket mkt = new MockPredictionMarket(address(registry));
        vm.deal(address(mkt), 10 ether);
        string[] memory opts = new string[](2);
        opts[0] = "Yes";
        opts[1] = "No";
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(address(mkt));
        registry.registerForSettlement{value: 1 ether}(1, "Will ETH hit $5000?", opts, deadline);

        bytes32 key = MarketKey.derive(address(mkt), 1);
        vm.warp(deadline + 1);

        bytes memory creReport = abi.encode(bytes32(0));
        vm.prank(creForwarder);
        registry.createStudioForMarket(key, creReport);

        // Verify reward was deposited to the studio proxy
        address studioAddr = registry.keyToStudio(key);
        assertEq(studioAddr.balance, 1 ether, "Studio proxy should hold the reward");
        assertEq(MockStudioProxy(payable(studioAddr)).depositedAmount(), 1 ether,
            "depositedAmount should equal the reward");
    }

    function test_createStudioForMarket_registryBalanceDeducted() public {
        // Setup: register two markets
        MockPredictionMarket mkt = new MockPredictionMarket(address(registry));
        vm.deal(address(mkt), 10 ether);
        string[] memory opts = new string[](2);
        opts[0] = "Yes";
        opts[1] = "No";
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(address(mkt));
        registry.registerForSettlement{value: 2 ether}(1, "Market 1?", opts, deadline);
        vm.prank(address(mkt));
        registry.registerForSettlement{value: 3 ether}(2, "Market 2?", opts, deadline);

        // Registry should hold 5 ETH total
        assertEq(address(registry).balance, 5 ether, "Registry should hold both rewards");

        // Create studio for first market
        bytes32 key1 = MarketKey.derive(address(mkt), 1);
        vm.warp(deadline + 1);

        bytes memory creReport = abi.encode(bytes32(0));
        vm.prank(creForwarder);
        registry.createStudioForMarket(key1, creReport);

        // Registry balance should decrease by 2 ETH (first reward)
        assertEq(address(registry).balance, 3 ether,
            "Registry should have 3 ETH after first studio creation");

        // Create studio for second market
        bytes32 key2 = MarketKey.derive(address(mkt), 2);
        vm.prank(creForwarder);
        registry.createStudioForMarket(key2, creReport);

        // Registry balance should be 0 now
        assertEq(address(registry).balance, 0,
            "Registry should have 0 ETH after both studios created");
    }

    // ============ Helpers ============

    receive() external payable {}
}
