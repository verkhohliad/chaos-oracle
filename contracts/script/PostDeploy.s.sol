// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ChaosOracleRegistry} from "../src/ChaosOracleRegistry.sol";

/// @title PostDeploy
/// @notice Post-deployment configuration for ChaosOracle.
///
/// Set CRE workflow ID on Registry (requires Registry owner = deployer):
///   forge script script/PostDeploy.s.sol --sig "setWorkflowId()" \
///     --rpc-url $SEPOLIA_RPC --broadcast
///
/// Required env vars:
///   setWorkflowId: DEPLOYER_PRIVATE_KEY, REGISTRY, CRE_WORKFLOW_ID
///
/// Note: registerLogicModule on ChaosCore is NOT needed — the Registry deploys
///       StudioProxy instances directly via the permissionless StudioProxyFactory.
contract PostDeploy is Script {
    /// @notice Set the authorized CRE workflow ID on the Registry.
    /// @dev Requires the Registry owner's private key (= original deployer).
    function setWorkflowId() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address registry = vm.envAddress("REGISTRY");
        bytes32 workflowId = vm.envBytes32("CRE_WORKFLOW_ID");

        vm.startBroadcast(deployerKey);
        ChaosOracleRegistry(payable(registry)).setAuthorizedWorkflowId(workflowId);
        vm.stopBroadcast();

        console.log("Set workflow ID on Registry %s", registry);
        console.log("Workflow ID: %s", vm.toString(workflowId));
    }

    function run() external {
        setWorkflowId();
    }
}
