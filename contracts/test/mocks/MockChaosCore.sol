// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IChaosCore} from "@chaoschain/interfaces/IChaosCore.sol";
import {IStudioProxyFactory} from "@chaoschain/interfaces/IStudioProxyFactory.sol";

/// @title MockChaosCore
/// @notice Mock implementation of ChaosCore for testing.
///         Deploys MockStudioProxy instances when createStudio is called.
contract MockChaosCore is IChaosCore {
    uint256 public studioCount;
    mapping(address => bool) public registeredModules;
    mapping(uint256 => StudioConfig) private _studios;
    mapping(address => uint256[]) private _ownerStudios;

    // Track deployed proxies for testing
    address[] public deployedProxies;

    function registerLogicModule(address logicModule, string calldata name) external override {
        registeredModules[logicModule] = true;
        emit LogicModuleRegistered(logicModule, name);
    }

    function createStudio(
        string calldata name,
        address logicModule
    ) external override returns (address proxy, uint256 studioId) {
        require(registeredModules[logicModule], "MockChaosCore: module not registered");

        studioId = studioCount++;

        // Deploy a minimal proxy that can receive ETH and forward calls
        MockStudioProxy proxyContract = new MockStudioProxy(logicModule);
        proxy = address(proxyContract);

        _studios[studioId] = StudioConfig({
            proxy: proxy,
            logicModule: logicModule,
            owner: msg.sender,
            name: name,
            createdAt: block.timestamp,
            active: true
        });

        _ownerStudios[msg.sender].push(studioId);
        deployedProxies.push(proxy);

        emit StudioCreated(proxy, logicModule, msg.sender, name, studioId);
    }

    function deactivateStudio(uint256 studioId) external override {
        _studios[studioId].active = false;
    }

    function getStudio(uint256 studioId) external view override returns (StudioConfig memory) {
        return _studios[studioId];
    }

    function getStudioCount() external view override returns (uint256) {
        return studioCount;
    }

    function isLogicModuleRegistered(address logicModule) external view override returns (bool) {
        return registeredModules[logicModule];
    }

    function getStudiosByOwner(address owner) external view returns (uint256[] memory) {
        return _ownerStudios[owner];
    }
}

/// @title MockStudioProxyFactory
/// @notice Mock of StudioProxyFactory for testing.
///         Deploys MockStudioProxy instances (same as MockChaosCore would).
contract MockStudioProxyFactory is IStudioProxyFactory {
    function deployStudioProxy(
        address,
        address,
        address logicModule_,
        address
    ) external override returns (address proxy) {
        MockStudioProxy proxyContract = new MockStudioProxy(logicModule_);
        proxy = address(proxyContract);
    }
}

/// @title MockStudioProxy
/// @notice Minimal proxy mock that delegates calls to the logic module.
///         Supports deposit() and delegatecalls for initialize, domain functions, etc.
contract MockStudioProxy {
    address public logicModule;
    uint256 public depositedAmount;

    constructor(address _logicModule) {
        logicModule = _logicModule;
    }

    function deposit() external payable {
        depositedAmount += msg.value;
    }

    /// @dev Forward all unknown calls to the logic module via delegatecall
    fallback() external payable {
        address impl = logicModule;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {
        depositedAmount += msg.value;
    }
}
