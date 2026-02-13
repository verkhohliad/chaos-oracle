// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ChaosOracleRegistry} from "../src/ChaosOracleRegistry.sol";
import {PredictionSettlementLogic} from "../src/PredictionSettlementLogic.sol";
import {ExamplePredictionMarket} from "../src/example/ExamplePredictionMarket.sol";

/// @title DeployAll
/// @notice Deploy the full ChaosOracle stack to a target network.
///
/// Usage:
///   forge script script/DeployAll.s.sol --rpc-url $SEPOLIA_RPC --broadcast --verify
///
/// Required env vars:
///   DEPLOYER_PRIVATE_KEY   - Deployer wallet
///   CHAOS_CORE             - ChaosChain ChaosCore address
///   CRE_FORWARDER          - Chainlink CRE Forwarder address
///   STUDIO_PROXY_FACTORY   - ChaosChain StudioProxyFactory address
///   CHAOSCHAIN_REGISTRY    - ChaosChain Registry (protocol address book)
///   REWARDS_DISTRIBUTOR    - ChaosChain RewardsDistributor address
///
/// After deployment:
///   1. Deploy CRE workflow -> get WORKFLOW_ID
///   2. Call registry.setAuthorizedWorkflowId(WORKFLOW_ID)
///
/// Note: registerLogicModule on ChaosCore is NOT needed — the Registry deploys
///       StudioProxy instances directly via StudioProxyFactory (permissionless).
contract DeployAll is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address chaosCore = vm.envAddress("CHAOS_CORE");
        address creForwarder = vm.envAddress("CRE_FORWARDER");
        address studioProxyFactory = vm.envAddress("STUDIO_PROXY_FACTORY");
        address chaosChainRegistry = vm.envAddress("CHAOSCHAIN_REGISTRY");
        address rewardsDistributor = vm.envAddress("REWARDS_DISTRIBUTOR");

        vm.startBroadcast(deployerKey);

        // 1. Deploy PredictionSettlementLogic (template - deployed once)
        PredictionSettlementLogic logic = new PredictionSettlementLogic();
        console.log("PredictionSettlementLogic:", address(logic));

        // 2. Deploy ChaosOracleRegistry (uses StudioProxyFactory directly — no ChaosCore owner needed)
        ChaosOracleRegistry registry = new ChaosOracleRegistry(
            chaosCore,
            address(logic),
            creForwarder,
            studioProxyFactory,
            chaosChainRegistry,
            rewardsDistributor
        );
        console.log("ChaosOracleRegistry:", address(registry));

        // 3. Deploy ExamplePredictionMarket
        ExamplePredictionMarket market = new ExamplePredictionMarket(address(registry));
        console.log("ExamplePredictionMarket:", address(market));

        vm.stopBroadcast();

        console.log("");
        console.log("=== Post-Deployment Steps ===");
        console.log("1. Deploy CRE workflow, then set workflow ID:");
        console.log("   registry.setAuthorizedWorkflowId(WORKFLOW_ID)");
    }
}
