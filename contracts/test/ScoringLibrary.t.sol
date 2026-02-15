// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Scoring} from "@chaoschain-ext/libraries/Scoring.sol";

/// @title ScoringLibraryTest
/// @notice Tests for the real ChaosChain Scoring.sol MAD-based consensus library.
///         This uses the actual library code (not mocks) to verify consensus correctness.
contract ScoringLibraryTest is Test {

    // Default params: alpha = 3 * PRECISION (standard MAD multiplier)
    Scoring.Params defaultParams = Scoring.Params({
        alpha: 3 * 1e6,  // 3.0 in fixed-point
        beta: 1e6,       // unused in consensus
        kappa: 1e6,      // unused in consensus
        tau: 1e6          // unused in consensus
    });

    // ============ Tests ============

    function test_singleValidator_passthrough() public pure {
        // Single validator -> their scores are returned directly
        uint8[][] memory scores = new uint8[][](1);
        scores[0] = new uint8[](3);
        scores[0][0] = 85;
        scores[0][1] = 70;
        scores[0][2] = 90;

        uint256[] memory stakes = new uint256[](1);
        stakes[0] = 1 ether;

        Scoring.Params memory params = Scoring.Params({
            alpha: 3 * 1e6, beta: 1e6, kappa: 1e6, tau: 1e6
        });

        uint8[] memory result = Scoring.consensus(scores, stakes, params);

        assertEq(result.length, 3, "Should have 3 dimensions");
        assertEq(result[0], 85, "Dim 0 should passthrough");
        assertEq(result[1], 70, "Dim 1 should passthrough");
        assertEq(result[2], 90, "Dim 2 should passthrough");
    }

    function test_identicalScores_returnsSame() public {
        // All validators agree -> consensus matches exactly
        uint8[][] memory scores = new uint8[][](3);
        for (uint256 i = 0; i < 3; i++) {
            scores[i] = new uint8[](2);
            scores[i][0] = 75;
            scores[i][1] = 88;
        }

        uint256[] memory stakes = new uint256[](3);
        stakes[0] = 1 ether;
        stakes[1] = 1 ether;
        stakes[2] = 1 ether;

        uint8[] memory result = Scoring.consensus(scores, stakes, defaultParams);

        assertEq(result[0], 75, "All agree on 75 -> consensus 75");
        assertEq(result[1], 88, "All agree on 88 -> consensus 88");
    }

    function test_medianOddValidators() public {
        // 3 validators: [60, 80, 70] -> median = 70, all within MAD threshold
        uint8[][] memory scores = new uint8[][](3);

        scores[0] = new uint8[](1);
        scores[0][0] = 60;

        scores[1] = new uint8[](1);
        scores[1][0] = 80;

        scores[2] = new uint8[](1);
        scores[2][0] = 70;

        uint256[] memory stakes = new uint256[](3);
        stakes[0] = 1 ether;
        stakes[1] = 1 ether;
        stakes[2] = 1 ether;

        uint8[] memory result = Scoring.consensus(scores, stakes, defaultParams);

        // With equal stakes and alpha=3, all should be inliers
        // Weighted mean of inliers = (60 + 80 + 70) / 3 = 70
        assertEq(result[0], 70, "Median of [60,70,80] should produce consensus of 70");
    }

    function test_outlierFiltered() public {
        // Scores: [80, 82, 78, 5] — outlier at 5 should be filtered
        uint8[][] memory scores = new uint8[][](4);

        scores[0] = new uint8[](1);
        scores[0][0] = 80;

        scores[1] = new uint8[](1);
        scores[1][0] = 82;

        scores[2] = new uint8[](1);
        scores[2][0] = 78;

        scores[3] = new uint8[](1);
        scores[3][0] = 5;

        uint256[] memory stakes = new uint256[](4);
        stakes[0] = 1 ether;
        stakes[1] = 1 ether;
        stakes[2] = 1 ether;
        stakes[3] = 1 ether;

        uint8[] memory result = Scoring.consensus(scores, stakes, defaultParams);

        // The outlier (5) should be filtered out by MAD
        // Consensus should be around 80 (average of 78,80,82)
        assertTrue(result[0] >= 78 && result[0] <= 82, "Consensus should be ~80, not dragged by outlier 5");
    }

    function test_stakeWeighted() public {
        // High-staked validator at 90 vs low-staked at 50
        // With alpha=3, both may be inliers but high stake carries more weight
        uint8[][] memory scores = new uint8[][](2);

        scores[0] = new uint8[](1);
        scores[0][0] = 90;  // High stake validator

        scores[1] = new uint8[](1);
        scores[1][0] = 50;  // Low stake validator

        uint256[] memory stakes = new uint256[](2);
        stakes[0] = 10 ether;  // 10x stake
        stakes[1] = 1 ether;

        uint8[] memory result = Scoring.consensus(scores, stakes, defaultParams);

        // With 10x stake on 90 vs 1x stake on 50:
        // Weighted median should be around 90
        // Consensus should be closer to 90 than to 50
        assertTrue(result[0] > 70, "Consensus should be closer to high-staked validator (90)");
    }

    function test_multiDimensional_independentPerDimension() public {
        // Each dimension should be computed independently.
        // With 3 validators, the MAD-based outlier filtering is less aggressive.
        uint8[][] memory scores = new uint8[][](3);

        // Validator 0: [90, 30]
        scores[0] = new uint8[](2);
        scores[0][0] = 90;
        scores[0][1] = 30;

        // Validator 1: [80, 70]
        scores[1] = new uint8[](2);
        scores[1][0] = 80;
        scores[1][1] = 70;

        // Validator 2: [85, 50]
        scores[2] = new uint8[](2);
        scores[2][0] = 85;
        scores[2][1] = 50;

        uint256[] memory stakes = new uint256[](3);
        stakes[0] = 1 ether;
        stakes[1] = 1 ether;
        stakes[2] = 1 ether;

        uint8[] memory result = Scoring.consensus(scores, stakes, defaultParams);

        assertEq(result.length, 2, "Should have 2 dimensions");
        // Dim 0: median=85, all inliers -> mean=(90+80+85)/3 = 85
        assertEq(result[0], 85, "Dim 0 consensus should be 85");
        // Dim 1: median=50, all inliers -> mean=(30+70+50)/3 = 50
        assertEq(result[1], 50, "Dim 1 consensus should be 50");
    }

    function test_allIdentical_returnsExact() public {
        // Edge case: all validators give same score
        uint8[][] memory scores = new uint8[][](5);
        for (uint256 i = 0; i < 5; i++) {
            scores[i] = new uint8[](1);
            scores[i][0] = 42;
        }

        uint256[] memory stakes = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            stakes[i] = 1 ether;
        }

        uint8[] memory result = Scoring.consensus(scores, stakes, defaultParams);

        assertEq(result[0], 42, "All identical -> returns exact score");
    }
}
