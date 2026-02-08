// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProtocolConstants} from "../libraries/ProtocolConstants.sol";

/// @title LogicModule
/// @notice Base contract for Studio business logic modules
/// @dev Vendored from github.com/ChaosChain/chaoschain
///
/// LogicModules are called via DELEGATECALL from StudioProxy:
/// 1. All state modifications affect the proxy's storage
/// 2. msg.sender and msg.value are preserved from original call
/// 3. Storage layout must match StudioProxy layout
abstract contract LogicModule {
    // ============ Storage Matching StudioProxy ============
    // CRITICAL: Must match StudioProxy storage layout exactly

    /// @dev Slot 0-1: immutables in proxy (chaosCore, registry) - not accessible here
    /// @dev Slot 2: RewardsDistributor address
    address internal _rewardsDistributor;

    /// @dev Slot 3+: Escrow balances
    mapping(address => uint256) internal _escrowBalances;

    /// @dev Work submissions
    mapping(bytes32 => address) internal _workSubmissions;

    /// @dev Score vectors
    mapping(bytes32 => mapping(address => bytes)) internal _scoreVectors;

    /// @dev Total escrow
    uint256 internal _totalEscrow;

    // ============ Events ============
    event LogicExecuted(string action, address indexed actor, bytes data);

    // ============ Modifiers ============
    modifier hasEscrow(uint256 required) {
        require(_escrowBalances[msg.sender] >= required, "Insufficient escrow");
        _;
    }

    modifier workExists(bytes32 dataHash) {
        require(_workSubmissions[dataHash] != address(0), "Work not found");
        _;
    }

    // ============ Abstract Functions ============
    function initialize(bytes calldata params) external virtual;
    function getStudioType() external pure virtual returns (string memory studioType);
    function getVersion() external pure virtual returns (string memory version);

    function getScoringCriteria() external virtual view returns (
        string[] memory names,
        uint16[] memory weights
    ) {
        names = ProtocolConstants.getDefaultPoADimensions();
        weights = ProtocolConstants.getDefaultPoAWeights();
    }

    // ============ Internal Helpers ============
    function _deductEscrow(address account, uint256 amount) internal {
        require(_escrowBalances[account] >= amount, "Insufficient escrow");
        unchecked {
            _escrowBalances[account] -= amount;
            _totalEscrow -= amount;
        }
    }

    function _addEscrow(address account, uint256 amount) internal {
        _escrowBalances[account] += amount;
        _totalEscrow += amount;
    }

    function _recordWork(bytes32 dataHash, address submitter) internal {
        require(_workSubmissions[dataHash] == address(0), "Work already exists");
        _workSubmissions[dataHash] = submitter;
    }

    function _recordScoreVector(
        bytes32 dataHash,
        address validator,
        bytes memory scoreVector
    ) internal {
        _scoreVectors[dataHash][validator] = scoreVector;
    }
}
