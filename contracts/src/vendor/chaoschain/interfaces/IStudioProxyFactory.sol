// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IStudioProxyFactory
/// @notice Interface for the ChaosChain StudioProxyFactory
/// @dev Vendored from github.com/ChaosChain/chaoschain
///      The factory has NO access control — anyone can deploy StudioProxy instances.
interface IStudioProxyFactory {
    function deployStudioProxy(
        address chaosCore_,
        address registry_,
        address logicModule_,
        address rewardsDistributor_
    ) external returns (address proxy);
}
