// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChaosOracleRegistry} from "../src/ChaosOracleRegistry.sol";
import {PredictionSettlementLogic} from "../src/PredictionSettlementLogic.sol";
import {MockChaosCore} from "./mocks/MockChaosCore.sol";
import {MockPredictionMarket} from "./mocks/MockPredictionMarket.sol";
import {MarketKey} from "../src/libraries/MarketKey.sol";

contract ChaosOracleRegistryTest is Test {
    ChaosOracleRegistry registry;
    MockChaosCore chaosCore;
    PredictionSettlementLogic logic;
    address creForwarder = address(0xC4E);
    address owner;

    function setUp() public {
        owner = address(this);

        chaosCore = new MockChaosCore();
        logic = new PredictionSettlementLogic();

        // Register the logic module with ChaosCore
        chaosCore.registerLogicModule(address(logic), "PredictionSettlement");

        registry = new ChaosOracleRegistry(
            address(chaosCore),
            address(logic),
            creForwarder
        );
    }

    // ============ Constructor Tests ============

    function test_constructor() public view {
        assertEq(registry.chaosCore(), address(chaosCore));
        assertEq(registry.logicModuleTemplate(), address(logic));
        assertEq(registry.creForwarder(), creForwarder);
        assertEq(registry.owner(), owner);
    }

    function test_constructor_revertsZeroChaosCore() public {
        vm.expectRevert("ChaosOracleRegistry: zero chaosCore");
        new ChaosOracleRegistry(address(0), address(logic), creForwarder);
    }

    function test_constructor_revertsZeroLogicModule() public {
        vm.expectRevert("ChaosOracleRegistry: zero logicModule");
        new ChaosOracleRegistry(address(chaosCore), address(0), creForwarder);
    }

    function test_constructor_revertsZeroCreForwarder() public {
        vm.expectRevert("ChaosOracleRegistry: zero creForwarder");
        new ChaosOracleRegistry(address(chaosCore), address(logic), address(0));
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
        vm.expectRevert("ChaosOracleRegistry: no reward");
        registry.registerForSettlement(1, "Q?", opts, block.timestamp + 1);
    }

    function test_registerForSettlement_revertsEmptyQuestion() public {
        string[] memory opts = new string[](2);
        opts[0] = "Yes";
        opts[1] = "No";
        vm.expectRevert("ChaosOracleRegistry: empty question");
        registry.registerForSettlement{value: 1 ether}(1, "", opts, block.timestamp + 1);
    }

    function test_registerForSettlement_revertsTooFewOptions() public {
        string[] memory opts = new string[](1);
        opts[0] = "Yes";
        vm.expectRevert("ChaosOracleRegistry: need >= 2 options");
        registry.registerForSettlement{value: 1 ether}(1, "Q?", opts, block.timestamp + 1);
    }

    function test_registerForSettlement_revertsDeadlineInPast() public {
        string[] memory opts = new string[](2);
        opts[0] = "Yes";
        opts[1] = "No";
        vm.expectRevert("ChaosOracleRegistry: deadline in past");
        registry.registerForSettlement{value: 1 ether}(1, "Q?", opts, block.timestamp - 1);
    }

    function test_registerForSettlement_revertsDuplicate() public {
        string[] memory opts = new string[](2);
        opts[0] = "Yes";
        opts[1] = "No";
        uint256 deadline = block.timestamp + 1 days;

        registry.registerForSettlement{value: 1 ether}(1, "Q?", opts, deadline);

        vm.expectRevert("ChaosOracleRegistry: already registered");
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
        vm.expectRevert("ChaosOracleRegistry: not CRE forwarder");
        registry.createStudioForMarket(bytes32("key"), bytes(""));
    }

    function test_closeStudioEpoch_revertsNotCRE() public {
        vm.expectRevert("ChaosOracleRegistry: not CRE forwarder");
        registry.closeStudioEpoch(address(0x1), bytes(""));
    }

    function test_createStudioForMarket_revertsWrongWorkflowId() public {
        registry.setAuthorizedWorkflowId(bytes32("correct-id"));

        bytes memory creReport = abi.encode(bytes32("wrong-id"));
        vm.prank(creForwarder);
        vm.expectRevert("ChaosOracleRegistry: unauthorized workflow");
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

        // Verify settler was set on market
        assertEq(market.settlers(1), studioAddr);
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
        vm.expectRevert("ChaosOracleRegistry: deadline not reached");
        registry.createStudioForMarket(key, creReport);
    }

    // ============ Studio Callback Tests ============

    function test_onScoresSubmitted_revertsNotStudio() public {
        vm.expectRevert("ChaosOracleRegistry: not active studio");
        registry.onScoresSubmitted(5, 10);
    }

    function test_onStudioSettled_revertsNotStudio() public {
        vm.expectRevert("ChaosOracleRegistry: not active studio");
        registry.onStudioSettled(0, bytes32("proof"));
    }

    // ============ View Tests ============

    function test_getActiveStudios_empty() public view {
        address[] memory studios = registry.getActiveStudios();
        assertEq(studios.length, 0);
    }

    function test_canCloseStudio_nonExistent() public view {
        assertFalse(registry.canCloseStudio(address(0x123)));
    }

    // ============ Helpers ============

    receive() external payable {}
}
