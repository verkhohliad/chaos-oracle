// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ProtocolConstants
/// @notice Universal constants for the ChaosChain protocol
/// @dev Vendored from github.com/ChaosChain/chaoschain
library ProtocolConstants {
    bytes32 public constant POA_INITIATIVE = bytes32("INITIATIVE");
    bytes32 public constant POA_COLLABORATION = bytes32("COLLABORATION");
    bytes32 public constant POA_REASONING_DEPTH = bytes32("REASONING_DEPTH");
    bytes32 public constant POA_COMPLIANCE = bytes32("COMPLIANCE");
    bytes32 public constant POA_EFFICIENCY = bytes32("EFFICIENCY");

    function getDefaultPoADimensions() internal pure returns (string[] memory names) {
        names = new string[](5);
        names[0] = "Initiative";
        names[1] = "Collaboration";
        names[2] = "Reasoning Depth";
        names[3] = "Compliance";
        names[4] = "Efficiency";
    }

    function getDefaultPoAWeights() internal pure returns (uint16[] memory weights) {
        weights = new uint16[](5);
        weights[0] = 100;
        weights[1] = 100;
        weights[2] = 100;
        weights[3] = 100;
        weights[4] = 100;
    }

    uint8 public constant MIN_SCORE_VECTOR_LENGTH = 5;
}
