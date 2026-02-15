// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LogicModule} from "@chaoschain/base/LogicModule.sol";

/// @title PredictionSettlementLogic
/// @notice ChaosChain LogicModule for ChaosOracle prediction market settlement.
///         Deployed once, used by many StudioProxy instances via delegatecall.
///
/// @dev This is a configuration/metadata module only. It stores the market question,
///      options, and scoring criteria. All agent registration, work submission, and
///      score submission are handled natively by StudioProxy. Consensus computation
///      is performed by the CRE workflow.
///
///      Storage layout: LogicModule base storage first, then ChaosOracle-specific storage.
///      Since this runs via delegatecall from StudioProxy, all state lives in the proxy's storage.
contract PredictionSettlementLogic is LogicModule {
    // ============ Custom Errors ============

    error AlreadyInitialized();

    // ============ ChaosOracle-Specific Storage ============
    // CRITICAL: These come AFTER LogicModule's storage slots

    /// @notice ChaosOracleRegistry address
    address public oracleRegistry;

    /// @notice Target prediction market contract
    address public predictionMarket;

    /// @notice Market ID within the prediction market contract
    uint256 public marketId;

    /// @notice The market question
    string public question;

    /// @notice The possible outcome options
    string[] public options;

    /// @notice Whether this module has been initialized
    bool public initialized;

    // ============ LogicModule Overrides ============

    /// @inheritdoc LogicModule
    function initialize(bytes calldata params) external override {
        if (initialized) revert AlreadyInitialized();
        initialized = true;

        (
            address _registry,
            address _market,
            uint256 _marketId,
            string memory _question,
            string[] memory _options
        ) = abi.decode(params, (address, address, uint256, string, string[]));

        oracleRegistry = _registry;
        predictionMarket = _market;
        marketId = _marketId;
        question = _question;

        uint256 optLen = _options.length;
        for (uint256 i = 0; i < optLen;) {
            options.push(_options[i]);
            unchecked { ++i; }
        }
    }

    /// @inheritdoc LogicModule
    function getStudioType() external pure override returns (string memory) {
        return "prediction-settlement";
    }

    /// @inheritdoc LogicModule
    function getVersion() external pure override returns (string memory) {
        return "1.0.0";
    }

    /// @inheritdoc LogicModule
    function getScoringCriteria() external pure override returns (
        string[] memory names,
        uint16[] memory weights
    ) {
        // 5 universal PoA + 4 prediction-settlement specific = 9 dimensions
        names = new string[](9);
        weights = new uint16[](9);

        // Universal PoA dimensions (REQUIRED)
        names[0] = "Initiative";
        names[1] = "Collaboration";
        names[2] = "Reasoning Depth";
        names[3] = "Compliance";
        names[4] = "Efficiency";

        // ChaosOracle prediction-specific dimensions
        names[5] = "Accuracy";
        names[6] = "Evidence Quality";
        names[7] = "Source Diversity";
        names[8] = "Reasoning Depth";

        // Weights (100 = 1.0x baseline)
        weights[0] = 100;  // Initiative: 1.0x
        weights[1] = 100;  // Collaboration: 1.0x
        weights[2] = 100;  // Reasoning Depth: 1.0x
        weights[3] = 100;  // Compliance: 1.0x
        weights[4] = 100;  // Efficiency: 1.0x
        weights[5] = 200;  // Accuracy: 2.0x (MOST CRITICAL)
        weights[6] = 150;  // Evidence Quality: 1.5x
        weights[7] = 120;  // Source Diversity: 1.2x
        weights[8] = 130;  // Reasoning Depth: 1.3x
    }

    // ============ View Helpers ============

    /// @notice Get the number of outcome options
    function getOptionCount() external view returns (uint256) {
        return options.length;
    }

    /// @notice Get a specific option string
    function getOption(uint256 index) external view returns (string memory) {
        return options[index];
    }
}
