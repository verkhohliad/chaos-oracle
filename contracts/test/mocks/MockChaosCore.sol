// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IChaosCore} from "@chaoschain/interfaces/IChaosCore.sol";
import {IStudioProxyFactory} from "@chaoschain/interfaces/IStudioProxyFactory.sol";

/// @title MockChaosCore
/// @notice Mock implementation of ChaosCore for testing.
///         Deploys MockStudioProxy instances when createStudio is called.
contract MockChaosCore is IChaosCore {
    uint256 public studioCount;
    mapping(address => bool) public registeredModules;
    mapping(uint256 => StudioConfig) private _studios;
    mapping(address => uint256[]) private _ownerStudios;

    // Track deployed proxies for testing
    address[] public deployedProxies;

    function registerLogicModule(address logicModule, string calldata name) external override {
        registeredModules[logicModule] = true;
        emit LogicModuleRegistered(logicModule, name);
    }

    function createStudio(
        string calldata name,
        address logicModule
    ) external override returns (address proxy, uint256 studioId) {
        require(registeredModules[logicModule], "MockChaosCore: module not registered");

        studioId = studioCount++;

        // Deploy a minimal proxy that can receive ETH and forward calls
        MockStudioProxy proxyContract = new MockStudioProxy(logicModule);
        proxy = address(proxyContract);

        _studios[studioId] = StudioConfig({
            proxy: proxy,
            logicModule: logicModule,
            owner: msg.sender,
            name: name,
            createdAt: block.timestamp,
            active: true
        });

        _ownerStudios[msg.sender].push(studioId);
        deployedProxies.push(proxy);

        emit StudioCreated(proxy, logicModule, msg.sender, name, studioId);
    }

    function deactivateStudio(uint256 studioId) external override {
        _studios[studioId].active = false;
    }

    function getStudio(uint256 studioId) external view override returns (StudioConfig memory) {
        return _studios[studioId];
    }

    function getStudioCount() external view override returns (uint256) {
        return studioCount;
    }

    function isLogicModuleRegistered(address logicModule) external view override returns (bool) {
        return registeredModules[logicModule];
    }

    function getStudiosByOwner(address owner) external view returns (uint256[] memory) {
        return _ownerStudios[owner];
    }
}

/// @title MockStudioProxyFactory
/// @notice Mock of StudioProxyFactory for testing.
///         Deploys MockStudioProxy instances (same as MockChaosCore would).
contract MockStudioProxyFactory is IStudioProxyFactory {
    function deployStudioProxy(
        address,
        address,
        address logicModule_,
        address
    ) external override returns (address proxy) {
        MockStudioProxy proxyContract = new MockStudioProxy(logicModule_);
        proxy = address(proxyContract);
    }
}

/// @title MockStudioProxy
/// @notice Rich mock matching the real IStudioProxy interface.
///         Supports deposit(), agent lifecycle (submitWork, submitScoreVector),
///         escrow management, fund release, and delegatecall to the LogicModule.
contract MockStudioProxy {
    // ============ Events (matching real IStudioProxy) ============

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

    // ============ Storage ============

    address public logicModule;
    uint256 public depositedAmount;

    /// @dev Agent registration: address => agentId
    mapping(address => uint256) public agentIds;
    /// @dev Role per agent: agentId => role (1 = worker, 2 = verifier)
    mapping(uint256 => uint8) public agentRoles;
    uint256 public nextAgentId = 1;

    /// @dev Work submissions: dataHash => submitter agentId
    mapping(bytes32 => uint256) public workSubmitterAgentId;
    /// @dev Work submissions: dataHash => submitter address
    mapping(bytes32 => address) public workSubmitters;

    /// @dev Score vectors: dataHash => validator => scoreVector
    mapping(bytes32 => mapping(address => bytes)) public scoreVectors;

    /// @dev Escrow balances per agent
    mapping(address => uint256) public escrowBalances;
    uint256 public totalEscrow;

    /// @dev Withdrawable balances (populated after releaseFunds)
    mapping(address => uint256) public withdrawable;

    // ============ Constructor ============

    constructor(address _logicModule) {
        logicModule = _logicModule;
    }

    // ============ IStudioProxy: Core functions ============

    function deposit() external payable {
        depositedAmount += msg.value;
    }

    function getLogicModule() external view returns (address) {
        return logicModule;
    }

    function upgradeLogicModule(address newLogic) external {
        logicModule = newLogic;
    }

    // ============ Agent Registration (mock helper — not in IStudioProxy) ============

    /// @notice Register an agent with a given role.
    /// @param agentId The ERC-8004 identity ID for this agent
    /// @param role 1 = worker, 2 = verifier
    function registerAgent(uint256 agentId, uint8 role) external {
        agentIds[msg.sender] = agentId;
        agentRoles[agentId] = role;
    }

    // ============ IStudioProxy: Work Submission ============

    /// @notice Submit work as a registered worker.
    /// @dev Matches real IStudioProxy signature: submitWork(bytes32, bytes32, bytes32, bytes)
    function submitWork(
        bytes32 dataHash,
        bytes32 threadRoot,
        bytes32 evidenceRoot,
        bytes calldata /* feedbackAuth */
    ) external {
        require(workSubmitters[dataHash] == address(0), "Work already submitted");

        uint256 agentId = agentIds[msg.sender];
        workSubmitterAgentId[dataHash] = agentId;
        workSubmitters[dataHash] = msg.sender;

        emit WorkSubmitted(agentId, dataHash, threadRoot, evidenceRoot, block.timestamp);
    }

    // ============ IStudioProxy: Score Submission ============

    /// @notice Submit a score vector for a piece of work.
    /// @dev Matches real IStudioProxy signature: submitScoreVector(bytes32, bytes)
    function submitScoreVector(bytes32 dataHash, bytes calldata scoreVector) external {
        require(workSubmitters[dataHash] != address(0), "Work not found");

        uint256 validatorAgentId = agentIds[msg.sender];
        scoreVectors[dataHash][msg.sender] = scoreVector;

        emit ScoreVectorSubmitted(validatorAgentId, dataHash, scoreVector, block.timestamp);
    }

    // ============ IStudioProxy: Escrow & Funds ============

    function getEscrowBalance(address account) external view returns (uint256) {
        return escrowBalances[account];
    }

    function getWorkSubmitter(bytes32 dataHash) external view returns (address) {
        return workSubmitters[dataHash];
    }

    /// @notice Release funds to an agent (e.g., after settlement / rewards distribution).
    function releaseFunds(address to, uint256 amount, bytes32 /* dataHash */) external {
        withdrawable[to] += amount;
    }

    /// @notice Withdraw accumulated funds.
    function withdraw() external {
        uint256 amount = withdrawable[msg.sender];
        require(amount > 0, "Nothing to withdraw");
        withdrawable[msg.sender] = 0;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "Transfer failed");
    }

    // ============ Delegatecall fallback (for LogicModule functions) ============

    /// @dev Forward all unknown calls to the logic module via delegatecall.
    ///      This is how initialize(), question(), getStudioType(), etc. are handled.
    fallback() external payable {
        address impl = logicModule;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {
        depositedAmount += msg.value;
    }
}
