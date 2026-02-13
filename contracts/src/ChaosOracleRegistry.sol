// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {IChaosOracleRegistry} from "./interfaces/IChaosOracleRegistry.sol";
import {IChaosOracleSettleable} from "./interfaces/IChaosOracleSettleable.sol";
import {IStudioProxy} from "@chaoschain/interfaces/IStudioProxy.sol";
import {IStudioProxyFactory} from "@chaoschain/interfaces/IStudioProxyFactory.sol";
import {MarketKey} from "./libraries/MarketKey.sol";

/// @title ChaosOracleRegistry
/// @notice Central hub bridging prediction markets to ChaosChain studios for settlement.
///         Prediction markets register here, CRE workflows trigger studio creation and
///         epoch closure, and studios report back settlement results.
/// @dev The Registry is the single entry point for the ChaosOracle protocol.
///      It coordinates between prediction markets, ChaosChain ChaosCore, and Chainlink CRE.
contract ChaosOracleRegistry is IChaosOracleRegistry, Ownable {
    using MarketKey for address;

    // ============ Structs ============

    struct PendingMarket {
        address market;
        uint256 marketId;
        string question;
        string[] options;
        uint256 deadline;
        uint256 reward;
        bool exists;
    }

    struct ActiveStudio {
        bytes32 key;
        address studio;
        uint256 studioId;
        address market;
        uint256 marketId;
        bool settled;
    }

    // ============ Immutables ============

    /// @notice ChaosChain ChaosCore address
    address public immutable chaosCore;

    /// @notice PredictionSettlementLogic template address
    address public immutable logicModuleTemplate;

    /// @notice Chainlink CRE Forwarder address
    address public immutable creForwarder;

    /// @notice ChaosChain StudioProxyFactory (permissionless — bypasses ChaosCore onlyOwner gate)
    address public immutable studioProxyFactory;

    /// @notice ChaosChain Registry (protocol address book, not this contract)
    address public immutable chaosChainRegistry;

    /// @notice ChaosChain RewardsDistributor
    address public immutable rewardsDistributor;

    // ============ State ============

    /// @notice Authorized CRE workflow ID (set after workflow deployment)
    bytes32 public authorizedWorkflowId;

    /// @notice Market key => PendingMarket
    mapping(bytes32 => PendingMarket) public pendingMarkets;

    /// @notice All pending market keys (for iteration)
    bytes32[] public pendingMarketKeys;

    /// @notice Studio address => ActiveStudio
    mapping(address => ActiveStudio) public activeStudios;

    /// @notice All active studio addresses (for iteration)
    address[] public activeStudioList;

    /// @notice Market key => studio address (tracks which keys have studios)
    mapping(bytes32 => address) public keyToStudio;

    // ============ Modifiers ============

    modifier onlyCRE(bytes calldata creReport) {
        require(msg.sender == creForwarder, "ChaosOracleRegistry: not CRE forwarder");
        if (authorizedWorkflowId != bytes32(0)) {
            // Decode workflowId from the first 32 bytes of creReport
            bytes32 workflowId = abi.decode(creReport[:32], (bytes32));
            require(workflowId == authorizedWorkflowId, "ChaosOracleRegistry: unauthorized workflow");
        }
        _;
    }

    modifier onlyActiveStudio() {
        require(activeStudios[msg.sender].studio == msg.sender, "ChaosOracleRegistry: not active studio");
        require(!activeStudios[msg.sender].settled, "ChaosOracleRegistry: already settled");
        _;
    }

    // ============ Constructor ============

    /// @param _chaosCore ChaosChain ChaosCore address
    /// @param _logicModuleTemplate PredictionSettlementLogic template address
    /// @param _creForwarder Chainlink CRE Forwarder address
    /// @param _studioProxyFactory ChaosChain StudioProxyFactory address
    /// @param _chaosChainRegistry ChaosChain Registry (protocol address book)
    /// @param _rewardsDistributor ChaosChain RewardsDistributor address
    constructor(
        address _chaosCore,
        address _logicModuleTemplate,
        address _creForwarder,
        address _studioProxyFactory,
        address _chaosChainRegistry,
        address _rewardsDistributor
    ) Ownable(msg.sender) {
        require(_chaosCore != address(0), "ChaosOracleRegistry: zero chaosCore");
        require(_logicModuleTemplate != address(0), "ChaosOracleRegistry: zero logicModule");
        require(_creForwarder != address(0), "ChaosOracleRegistry: zero creForwarder");
        require(_studioProxyFactory != address(0), "ChaosOracleRegistry: zero factory");
        require(_chaosChainRegistry != address(0), "ChaosOracleRegistry: zero ccRegistry");
        require(_rewardsDistributor != address(0), "ChaosOracleRegistry: zero rewards");

        chaosCore = _chaosCore;
        logicModuleTemplate = _logicModuleTemplate;
        creForwarder = _creForwarder;
        studioProxyFactory = _studioProxyFactory;
        chaosChainRegistry = _chaosChainRegistry;
        rewardsDistributor = _rewardsDistributor;
    }

    // ============ Admin ============

    /// @notice Set the authorized CRE workflow ID
    /// @dev Solves bootstrap dependency: deploy Registry first, deploy CRE workflow,
    ///      then set the workflow ID here.
    /// @param _workflowId The CRE workflow ID
    function setAuthorizedWorkflowId(bytes32 _workflowId) external onlyOwner {
        authorizedWorkflowId = _workflowId;
    }

    // ============ Market Registration ============

    /// @inheritdoc IChaosOracleRegistry
    function registerForSettlement(
        uint256 marketId,
        string calldata question,
        string[] calldata options,
        uint256 deadline
    ) external payable {
        require(msg.value > 0, "ChaosOracleRegistry: no reward");
        require(bytes(question).length > 0, "ChaosOracleRegistry: empty question");
        require(options.length >= 2, "ChaosOracleRegistry: need >= 2 options");
        require(deadline > block.timestamp, "ChaosOracleRegistry: deadline in past");

        bytes32 key = msg.sender.derive(marketId);
        require(!pendingMarkets[key].exists, "ChaosOracleRegistry: already registered");
        require(keyToStudio[key] == address(0), "ChaosOracleRegistry: already has studio");

        // Copy options to storage
        string[] memory opts = new string[](options.length);
        for (uint256 i = 0; i < options.length; i++) {
            opts[i] = options[i];
        }

        pendingMarkets[key] = PendingMarket({
            market: msg.sender,
            marketId: marketId,
            question: question,
            options: opts,
            deadline: deadline,
            reward: msg.value,
            exists: true
        });
        pendingMarketKeys.push(key);

        emit MarketRegistered(key, msg.sender, marketId, question, options, deadline, msg.value);
    }

    // ============ CRE-Only Functions ============

    /// @inheritdoc IChaosOracleRegistry
    function createStudioForMarket(bytes32 key, bytes calldata creReport) external onlyCRE(creReport) {
        PendingMarket storage pm = pendingMarkets[key];
        require(pm.exists, "ChaosOracleRegistry: market not found");
        require(block.timestamp >= pm.deadline, "ChaosOracleRegistry: deadline not reached");
        require(keyToStudio[key] == address(0), "ChaosOracleRegistry: studio already exists");

        // Deploy StudioProxy directly via StudioProxyFactory (permissionless).
        // This bypasses ChaosCore.createStudio() which requires onlyOwner registration
        // of our custom LogicModule. The factory itself has no access control.
        address proxy = IStudioProxyFactory(studioProxyFactory).deployStudioProxy(
            chaosCore,
            chaosChainRegistry,
            logicModuleTemplate,
            rewardsDistributor
        );

        // Fund the studio with the reward pool
        IStudioProxy(proxy).deposit{value: pm.reward}();

        // Initialize the logic module via the proxy's fallback (delegatecall)
        bytes memory initData = abi.encodeWithSignature(
            "initialize(bytes)",
            abi.encode(address(this), pm.market, pm.marketId, pm.question, pm.options)
        );
        (bool success,) = proxy.call(initData);
        require(success, "ChaosOracleRegistry: initialize failed");

        // Set this studio as the authorized settler on the prediction market
        IChaosOracleSettleable(pm.market).setSettler(pm.marketId, proxy);

        // Track the active studio (studioId = 0 since not registered through ChaosCore)
        activeStudios[proxy] = ActiveStudio({
            key: key,
            studio: proxy,
            studioId: 0,
            market: pm.market,
            marketId: pm.marketId,
            settled: false
        });
        activeStudioList.push(proxy);
        keyToStudio[key] = proxy;

        emit StudioCreated(key, proxy, 0, pm.market, pm.marketId);
    }

    /// @inheritdoc IChaosOracleRegistry
    function closeStudioEpoch(address studio, bytes calldata creReport) external onlyCRE(creReport) {
        ActiveStudio storage as_ = activeStudios[studio];
        require(as_.studio == studio, "ChaosOracleRegistry: not active studio");
        require(!as_.settled, "ChaosOracleRegistry: already settled");

        // Call closeEpoch on the studio (via fallback → delegatecall to PredictionSettlementLogic)
        (bool success,) = studio.call(abi.encodeWithSignature("closeEpoch()"));
        require(success, "ChaosOracleRegistry: closeEpoch failed");
    }

    // ============ Studio Callbacks ============

    /// @inheritdoc IChaosOracleRegistry
    function onScoresSubmitted(uint256 totalSubmissions, uint256 totalScores) external onlyActiveStudio {
        emit StudioScoresSubmitted(msg.sender, totalSubmissions, totalScores);
    }

    /// @inheritdoc IChaosOracleRegistry
    function onStudioSettled(uint8 outcome, bytes32 proofHash) external onlyActiveStudio {
        ActiveStudio storage as_ = activeStudios[msg.sender];
        as_.settled = true;

        emit StudioSettled(msg.sender, as_.key, outcome, proofHash);
    }

    // ============ View Functions ============

    /// @inheritdoc IChaosOracleRegistry
    function getMarketsReadyForSettlement() external view returns (bytes32[] memory keys) {
        // Count first
        uint256 count = 0;
        for (uint256 i = 0; i < pendingMarketKeys.length; i++) {
            bytes32 key = pendingMarketKeys[i];
            PendingMarket storage pm = pendingMarkets[key];
            if (pm.exists && block.timestamp >= pm.deadline && keyToStudio[key] == address(0)) {
                count++;
            }
        }

        // Build result
        keys = new bytes32[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < pendingMarketKeys.length; i++) {
            bytes32 key = pendingMarketKeys[i];
            PendingMarket storage pm = pendingMarkets[key];
            if (pm.exists && block.timestamp >= pm.deadline && keyToStudio[key] == address(0)) {
                keys[idx++] = key;
            }
        }
    }

    /// @inheritdoc IChaosOracleRegistry
    function getActiveStudios() external view returns (address[] memory studios) {
        // Count unsettled
        uint256 count = 0;
        for (uint256 i = 0; i < activeStudioList.length; i++) {
            if (!activeStudios[activeStudioList[i]].settled) {
                count++;
            }
        }

        // Build result
        studios = new address[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < activeStudioList.length; i++) {
            if (!activeStudios[activeStudioList[i]].settled) {
                studios[idx++] = activeStudioList[i];
            }
        }
    }

    /// @inheritdoc IChaosOracleRegistry
    function canCloseStudio(address studio) external view returns (bool ready) {
        ActiveStudio storage as_ = activeStudios[studio];
        if (as_.studio != studio || as_.settled) return false;

        // Delegate to PredictionSettlementLogic.canClose() via static call
        (bool success, bytes memory data) = studio.staticcall(
            abi.encodeWithSignature("canClose()")
        );
        if (!success) return false;
        return abi.decode(data, (bool));
    }

    // ============ Getters for struct fields ============

    /// @notice Get the options array for a pending market
    function getPendingMarketOptions(bytes32 key) external view returns (string[] memory) {
        return pendingMarkets[key].options;
    }

    /// @notice Get the number of pending market keys
    function getPendingMarketCount() external view returns (uint256) {
        return pendingMarketKeys.length;
    }

    /// @notice Get the number of active studios
    function getActiveStudioCount() external view returns (uint256) {
        return activeStudioList.length;
    }

    // ============ Internal ============

    /// @dev Convert first 4 bytes of a bytes32 to hex string for studio naming
    function _bytes32ToHexString(bytes32 value) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(8);
        for (uint256 i = 0; i < 4; i++) {
            str[i * 2] = alphabet[uint8(value[i] >> 4)];
            str[1 + i * 2] = alphabet[uint8(value[i] & 0x0f)];
        }
        return string(str);
    }

    /// @dev Allow receiving ETH (for edge cases)
    receive() external payable {}
}
