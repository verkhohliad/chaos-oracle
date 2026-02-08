// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IChaosOracleRegistry
/// @notice Interface for the ChaosOracle Registry - the central hub bridging
///         prediction markets to ChaosChain studios for settlement
interface IChaosOracleRegistry {
    // ============ Events ============

    /// @notice Emitted when a prediction market registers for ChaosOracle settlement
    event MarketRegistered(
        bytes32 indexed key,
        address indexed market,
        uint256 indexed marketId,
        string question,
        string[] options,
        uint256 deadline,
        uint256 reward
    );

    /// @notice Emitted when a ChaosChain studio is created for a pending market
    event StudioCreated(
        bytes32 indexed key,
        address indexed studio,
        uint256 studioId,
        address indexed market,
        uint256 marketId
    );

    /// @notice Emitted when an active studio reports aggregated score submissions
    event StudioScoresSubmitted(
        address indexed studio,
        uint256 totalSubmissions,
        uint256 totalScores
    );

    /// @notice Emitted when a studio reaches consensus and settles a market
    event StudioSettled(
        address indexed studio,
        bytes32 indexed key,
        uint8 outcome,
        bytes32 proofHash
    );

    // ============ Market Registration ============

    /// @notice Register a prediction market for ChaosOracle settlement
    /// @dev msg.value is the reward pool for ChaosChain agents performing settlement.
    ///      The key is derived as keccak256(abi.encodePacked(msg.sender, marketId)).
    /// @param marketId The market ID within the calling contract
    /// @param question The market question (e.g., "Will ETH reach $5000 by March 2025?")
    /// @param options The possible outcomes (e.g., ["Yes", "No"])
    /// @param deadline The unix timestamp after which settlement can begin
    function registerForSettlement(
        uint256 marketId,
        string calldata question,
        string[] calldata options,
        uint256 deadline
    ) external payable;

    // ============ CRE-Only Functions ============

    /// @notice Create a ChaosChain studio for a pending market (CRE-triggered)
    /// @param key The market key (derived from market address + marketId)
    /// @param creReport The CRE report proving authorized workflow execution
    function createStudioForMarket(bytes32 key, bytes calldata creReport) external;

    /// @notice Close the studio epoch and trigger settlement (CRE-triggered)
    /// @param studio The studio proxy address
    /// @param creReport The CRE report proving authorized workflow execution
    function closeStudioEpoch(address studio, bytes calldata creReport) external;

    // ============ Studio Callbacks ============

    /// @notice Called by active studios to report score aggregation progress
    /// @param totalSubmissions Current number of work submissions in the studio
    /// @param totalScores Current number of score submissions in the studio
    function onScoresSubmitted(uint256 totalSubmissions, uint256 totalScores) external;

    /// @notice Called by active studios when settlement consensus is reached
    /// @param outcome The winning outcome index
    /// @param proofHash The proof hash from consensus
    function onStudioSettled(uint8 outcome, bytes32 proofHash) external;

    // ============ View Functions ============

    /// @notice Get all market keys that are past deadline and don't yet have a studio
    /// @return keys Array of market keys ready for studio creation
    function getMarketsReadyForSettlement() external view returns (bytes32[] memory keys);

    /// @notice Get all studio addresses that are currently active (not yet settled)
    /// @return studios Array of active studio proxy addresses
    function getActiveStudios() external view returns (address[] memory studios);

    /// @notice Check whether a studio has met minimum thresholds to close
    /// @param studio The studio proxy address
    /// @return ready True if the studio can be closed
    function canCloseStudio(address studio) external view returns (bool ready);
}
