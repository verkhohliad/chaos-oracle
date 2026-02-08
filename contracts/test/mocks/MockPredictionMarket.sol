// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IChaosOracleSettleable} from "../../src/interfaces/IChaosOracleSettleable.sol";

/// @title MockPredictionMarket
/// @notice Mock implementation of IChaosOracleSettleable for testing.
///         Records all calls for assertion in tests.
contract MockPredictionMarket is IChaosOracleSettleable {
    address public registry;

    struct SettlementRecord {
        uint256 marketId;
        uint8 outcome;
        bytes32 proofHash;
        address settler;
        bool called;
    }

    mapping(uint256 => address) public settlers;
    mapping(uint256 => SettlementRecord) public settlements;

    constructor(address _registry) {
        registry = _registry;
    }

    function setSettler(uint256 marketId, address settler) external override {
        require(msg.sender == registry, "MockPredictionMarket: only registry");
        settlers[marketId] = settler;
    }

    function onSettlement(uint256 marketId, uint8 outcome, bytes32 proofHash) external override {
        require(msg.sender == settlers[marketId], "MockPredictionMarket: only settler");
        settlements[marketId] = SettlementRecord({
            marketId: marketId,
            outcome: outcome,
            proofHash: proofHash,
            settler: msg.sender,
            called: true
        });
    }

    function wasSettled(uint256 marketId) external view returns (bool) {
        return settlements[marketId].called;
    }

    function getSettlement(uint256 marketId) external view returns (SettlementRecord memory) {
        return settlements[marketId];
    }
}
