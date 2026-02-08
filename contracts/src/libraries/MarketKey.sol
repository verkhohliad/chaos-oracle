// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MarketKey
/// @notice Library for deriving unique market keys from (market address, marketId) pairs
library MarketKey {
    /// @notice Derive a unique key for a market + marketId pair
    /// @param market The prediction market contract address
    /// @param marketId The market ID within that contract
    /// @return key The derived bytes32 key
    function derive(address market, uint256 marketId) internal pure returns (bytes32 key) {
        return keccak256(abi.encodePacked(market, marketId));
    }
}
