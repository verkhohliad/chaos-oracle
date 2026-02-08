// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IChaosOracleSettleable
/// @notice Interface that prediction markets implement to receive ChaosOracle settlements
/// @dev Any prediction market wanting ChaosOracle settlement must implement this interface.
///      The Registry calls setSettler() when a studio is created, and the studio calls
///      onSettlement() when consensus is reached.
interface IChaosOracleSettleable {
    /// @notice Set the authorized settler address for a market
    /// @dev Called by ChaosOracleRegistry when a studio is created for this market.
    ///      Only the registry should be allowed to call this.
    /// @param marketId The market ID within this contract
    /// @param settler The StudioProxy address authorized to settle this market
    function setSettler(uint256 marketId, address settler) external;

    /// @notice Callback when settlement is reached
    /// @dev Called by the StudioProxy (via PredictionSettlementLogic delegatecall)
    ///      when the ChaosOracle agents reach consensus.
    /// @param marketId The market ID being settled
    /// @param outcome The winning outcome index (0-based)
    /// @param proofHash Keccak256 hash of concatenated evidence CIDs
    function onSettlement(uint256 marketId, uint8 outcome, bytes32 proofHash) external;
}
