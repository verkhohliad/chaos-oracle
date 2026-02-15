// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IChaosOracleSettleable
/// @notice Interface that prediction markets implement to receive ChaosOracle settlements
/// @dev Any prediction market wanting ChaosOracle settlement must implement this interface.
///      The ChaosOracleRegistry calls onSettlement() directly when the CRE workflow
///      computes consensus — no separate settler authorization step is needed.
interface IChaosOracleSettleable {
    /// @notice Callback when settlement is reached
    /// @dev Called by the ChaosOracleRegistry when the CRE workflow computes consensus.
    ///      Implementations should restrict access to only the registry address.
    /// @param marketId The market ID being settled
    /// @param outcome The winning outcome index (0-based)
    /// @param proofHash Keccak256 hash of concatenated evidence CIDs
    function onSettlement(uint256 marketId, uint8 outcome, bytes32 proofHash) external;
}
