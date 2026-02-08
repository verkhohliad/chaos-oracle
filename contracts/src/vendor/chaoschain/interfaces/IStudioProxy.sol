// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IStudioProxy
/// @notice Interface for Studio proxy contracts
/// @dev Vendored from github.com/ChaosChain/chaoschain
interface IStudioProxy {
    event WorkSubmitted(
        uint256 indexed agentId,
        bytes32 indexed dataHash,
        bytes32 threadRoot,
        bytes32 evidenceRoot,
        uint256 timestamp
    );

    event ScoreVectorSubmitted(
        uint256 indexed validatorAgentId,
        bytes32 indexed dataHash,
        bytes scoreVector,
        uint256 timestamp
    );

    function getLogicModule() external view returns (address);
    function upgradeLogicModule(address newLogic) external;
    function submitWork(bytes32 dataHash, bytes32 threadRoot, bytes32 evidenceRoot, bytes calldata feedbackAuth) external;
    function submitScoreVector(bytes32 dataHash, bytes calldata scoreVector) external;
    function releaseFunds(address to, uint256 amount, bytes32 dataHash) external;
    function getEscrowBalance(address account) external view returns (uint256);
    function getWorkSubmitter(bytes32 dataHash) external view returns (address);
    function deposit() external payable;
}
