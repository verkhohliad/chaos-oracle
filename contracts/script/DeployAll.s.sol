// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ChaosOracleRegistry} from "../src/ChaosOracleRegistry.sol";
import {PredictionSettlementLogic} from "../src/PredictionSettlementLogic.sol";
import {ExamplePredictionMarket} from "../src/example/ExamplePredictionMarket.sol";
import {IChaosCore} from "@chaoschain/interfaces/IChaosCore.sol";

/// @title DeployAll
/// @notice Deploy the full ChaosOracle stack to a target network.
///
/// Usage:
///   forge script script/DeployAll.s.sol --rpc-url $SEPOLIA_RPC --broadcast
///
/// Required env vars:
///   DEPLOYER_PRIVATE_KEY - Deployer wallet
///   CHAOS_CORE           - ChaosChain ChaosCore address
///   CRE_FORWARDER        - Chainlink CRE Forwarder address
///
/// After deployment:
///   1. Register logic module: chaosCore.registerLogicModule(logicAddr, "PredictionSettlement")
///      (requires ChaosCore owner)
///   2. Deploy CRE workflow -> get WORKFLOW_ID
///   3. Call registry.setAuthorizedWorkflowId(WORKFLOW_ID)
contract DeployAll is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address chaosCore = vm.envAddress("CHAOS_CORE");
        address creForwarder = vm.envAddress("CRE_FORWARDER");

        vm.startBroadcast(deployerKey);

        // 1. Deploy PredictionSettlementLogic (template - deployed once)
        PredictionSettlementLogic logic = new PredictionSettlementLogic();
        console.log("PredictionSettlementLogic:", address(logic));

        // 2. Deploy ChaosOracleRegistry
        ChaosOracleRegistry registry = new ChaosOracleRegistry(
            chaosCore,
            address(logic),
            creForwarder
        );
        console.log("ChaosOracleRegistry:", address(registry));

        // 3. Deploy ExamplePredictionMarket
        ExamplePredictionMarket market = new ExamplePredictionMarket(address(registry));
        console.log("ExamplePredictionMarket:", address(market));

        vm.stopBroadcast();

        console.log("");
        console.log("=== Post-Deployment Steps ===");
        console.log("1. Register logic module with ChaosCore (requires ChaosCore owner):");
        console.log("   chaosCore.registerLogicModule(%s, 'PredictionSettlement')", address(logic));
        console.log("2. Deploy CRE workflow, then set workflow ID:");
        console.log("   registry.setAuthorizedWorkflowId(WORKFLOW_ID)");
    }
}
