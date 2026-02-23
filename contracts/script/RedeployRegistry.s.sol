// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ChaosOracleRegistry} from "../src/ChaosOracleRegistry.sol";
import {ExamplePredictionMarket} from "../src/example/ExamplePredictionMarket.sol";

/// @title RedeployRegistry
/// @notice Redeploy ChaosOracleRegistry + ExamplePredictionMarket (market has immutable registry ref).
///
/// Usage:
///   cd contracts && forge script script/RedeployRegistry.s.sol --rpc-url $SEPOLIA_RPC --broadcast -vvv
///
/// Required env vars (all from .env):
///   DEPLOYER_PRIVATE_KEY, CHAOS_CORE, CRE_FORWARDER, STUDIO_PROXY_FACTORY,
///   CHAOSCHAIN_REGISTRY, REWARDS_DISTRIBUTOR, LOGIC_MODULE (existing template)
contract RedeployRegistry is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address chaosCore = vm.envAddress("CHAOS_CORE");
        address logicModule = vm.envAddress("LOGIC_MODULE");
        address creForwarder = vm.envAddress("CRE_FORWARDER");
        address studioProxyFactory = vm.envAddress("STUDIO_PROXY_FACTORY");
        address chaosChainRegistry = vm.envAddress("CHAOSCHAIN_REGISTRY");
        address rewardsDistributor = vm.envAddress("REWARDS_DISTRIBUTOR");

        vm.startBroadcast(deployerKey);

        ChaosOracleRegistry registry = new ChaosOracleRegistry(
            chaosCore,
            logicModule,
            creForwarder,
            studioProxyFactory,
            chaosChainRegistry,
            rewardsDistributor
        );
        console.log("New ChaosOracleRegistry:", address(registry));

        ExamplePredictionMarket market = new ExamplePredictionMarket(address(registry));
        console.log("New ExamplePredictionMarket:", address(market));

        vm.stopBroadcast();
    }
}
