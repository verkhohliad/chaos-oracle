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

        // Check option values
        (success, data) = studioProxy.staticcall(
            abi.encodeWithSignature("getOption(uint256)", uint256(0))
        );
        assertTrue(success);
        assertEq(abi.decode(data, (string)), "Yes");

        (success, data) = studioProxy.staticcall(
            abi.encodeWithSignature("getOption(uint256)", uint256(1))
        );
        assertTrue(success);
        assertEq(abi.decode(data, (string)), "No");
    }

    function test_initialize_setsRegistryAndMarket() public {
        (bool success, bytes memory data) = studioProxy.staticcall(
            abi.encodeWithSignature("oracleRegistry()")
        );
        assertTrue(success);
        assertEq(abi.decode(data, (address)), address(registry));

        (success, data) = studioProxy.staticcall(
            abi.encodeWithSignature("predictionMarket()")
        );
        assertTrue(success);
        assertEq(abi.decode(data, (address)), address(predMarket));

        (success, data) = studioProxy.staticcall(
            abi.encodeWithSignature("marketId()")
        );
        assertTrue(success);
        assertEq(abi.decode(data, (uint256)), 1);
    }

    function test_initialize_cannotReinitialize() public {
        bytes memory initData = abi.encodeWithSignature(
            "initialize(bytes)",
            abi.encode(address(registry), address(predMarket), uint256(1), "Q2?", new string[](2))
        );
        (bool success,) = studioProxy.call(initData);
        assertFalse(success); // Should revert: already initialized
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

        // Universal PoA dimensions
        assertEq(names[0], "Initiative");
        assertEq(names[1], "Collaboration");
        assertEq(names[2], "Reasoning Depth");
        assertEq(names[3], "Compliance");
        assertEq(names[4], "Efficiency");

        // Prediction-specific dimensions
        assertEq(names[5], "Accuracy");
        assertEq(names[6], "Evidence Quality");
        assertEq(names[7], "Source Diversity");
        assertEq(names[8], "Reasoning Depth");

        // Key weights
        assertEq(weights[5], 200); // 2.0x for Accuracy
        assertEq(weights[6], 150); // 1.5x for Evidence Quality
        assertEq(weights[7], 120); // 1.2x for Source Diversity
        assertEq(weights[8], 130); // 1.3x for Reasoning Depth
    }

    function test_getScoringCriteria_universalWeightsAreBaseline() public {
        (bool success, bytes memory data) = studioProxy.staticcall(
            abi.encodeWithSignature("getScoringCriteria()")
        );
        assertTrue(success);
        (, uint16[] memory weights) = abi.decode(data, (string[], uint16[]));

        // All 5 universal PoA dimensions should be 100 (1.0x baseline)
        for (uint256 i = 0; i < 5; i++) {
            assertEq(weights[i], 100, "Universal PoA dimension should be 1.0x");
        }
    }

    receive() external payable {}
}
