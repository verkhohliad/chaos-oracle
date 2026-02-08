// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IChaosCore
/// @notice Factory and registry for Studio proxy contracts
/// @dev Vendored from github.com/ChaosChain/chaoschain
interface IChaosCore {
    struct StudioConfig {
        address proxy;
        address logicModule;
        address owner;
        string name;
        uint256 createdAt;
        bool active;
    }

    event StudioCreated(
        address indexed proxy,
        address indexed logicModule,
        address indexed owner,
        string name,
        uint256 studioId
    );

    event LogicModuleRegistered(address indexed logicModule, string name);

    function createStudio(
        string calldata name,
        address logicModule
    ) external returns (address proxy, uint256 studioId);

    function registerLogicModule(address logicModule, string calldata name) external;
    function deactivateStudio(uint256 studioId) external;
    function getStudio(uint256 studioId) external view returns (StudioConfig memory config);
    function getStudioCount() external view returns (uint256 count);
    function isLogicModuleRegistered(address logicModule) external view returns (bool registered);
}
