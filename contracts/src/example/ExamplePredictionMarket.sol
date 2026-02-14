// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IChaosOracleSettleable} from "../interfaces/IChaosOracleSettleable.sol";
import {IChaosOracleRegistry} from "../interfaces/IChaosOracleRegistry.sol";

/// @title ExamplePredictionMarket
/// @notice A simple pool-based binary (Yes/No) prediction market that uses ChaosOracle
///         for settlement. This is an example implementation demonstrating the framework.
///
/// @dev Flow:
///      1. Creator calls createMarket() with ETH (10% goes to Registry as settlement reward)
///      2. Users call placeBet() with ETH on Yes (0) or No (1)
///      3. After deadline, CRE triggers studio creation, agents do settlement work
///      4. Studio calls onSettlement() with the winning outcome
///      5. Winners call claimWinnings() to receive pro-rata from the losing pool
contract ExamplePredictionMarket is IChaosOracleSettleable {
    // ============ Custom Errors ============

    error ZeroAddress();
    error NoETHSent();
    error EmptyQuestion();
    error DeadlineInPast();
    error MarketNotFound();
    error AlreadySettled();
    error DeadlinePassed();
    error InvalidOption();
    error OnlyRegistry();
    error SettlerAlreadySet();
    error OnlySettler();
    error InvalidOutcome();
    error NotSettled();
    error AlreadyClaimed();
    error NoWinningBet();
    error TransferFailed();
    // ============ Structs ============

    struct Market {
        address creator;
        string question;
        uint256 deadline;
        uint256[2] pools;       // [Yes pool, No pool]
        uint8 outcome;          // 0=Yes, 1=No, 255=unresolved
        bytes32 proofHash;
        address settler;        // StudioProxy authorized to settle
        bool settled;
        bool exists;
    }

    // ============ State ============

    /// @notice ChaosOracleRegistry address
    address public immutable registry;

    /// @notice Auto-incrementing market ID
    uint256 public nextMarketId;

    /// @notice Market ID => Market
    mapping(uint256 => Market) public markets;

    /// @notice Market ID => user => option => bet amount
    mapping(uint256 => mapping(address => mapping(uint8 => uint256))) public bets;

    /// @notice Market ID => user => claimed flag
    mapping(uint256 => mapping(address => bool)) public claimed;

    /// @notice Settlement reward percentage (10%)
    uint256 public constant SETTLEMENT_REWARD_BPS = 1000;
    uint256 public constant BPS_DENOMINATOR = 10000;

    // ============ Events ============

    event MarketCreated(
        uint256 indexed marketId,
        address indexed creator,
        string question,
        uint256 deadline,
        uint256 settlementReward
    );

    event BetPlaced(
        uint256 indexed marketId,
        address indexed bettor,
        uint8 option,
        uint256 amount
    );

    event MarketSettled(
        uint256 indexed marketId,
        uint8 outcome,
        bytes32 proofHash
    );

    event WinningsClaimed(
        uint256 indexed marketId,
        address indexed claimer,
        uint256 amount
    );

    // ============ Constructor ============

    /// @param _registry ChaosOracleRegistry address
    constructor(address _registry) {
        if (_registry == address(0)) revert ZeroAddress();
        registry = _registry;
    }

    // ============ Market Creation ============

    /// @notice Create a new prediction market
    /// @dev 10% of msg.value is sent to Registry as settlement reward.
    ///      The remaining 90% seeds the creator's bet on the Yes pool.
    /// @param _question The market question
    /// @param _deadline Unix timestamp after which settlement can begin
    /// @return marketId The created market's ID
    function createMarket(
        string calldata _question,
        uint256 _deadline
    ) external payable returns (uint256 marketId) {
        if (msg.value == 0) revert NoETHSent();
        if (bytes(_question).length == 0) revert EmptyQuestion();
        if (_deadline <= block.timestamp) revert DeadlineInPast();

        unchecked { marketId = nextMarketId++; }

        // Calculate settlement reward (10%)
        uint256 reward = (msg.value * SETTLEMENT_REWARD_BPS) / BPS_DENOMINATOR;
        uint256 seedBet = msg.value - reward;

        markets[marketId] = Market({
            creator: msg.sender,
            question: _question,
            deadline: _deadline,
            pools: [seedBet, uint256(0)],
            outcome: 255, // unresolved
            proofHash: bytes32(0),
            settler: address(0),
            settled: false,
            exists: true
        });

        // Track the creator's seed bet
        bets[marketId][msg.sender][0] = seedBet;

        // Register with ChaosOracleRegistry for settlement
        string[] memory opts = new string[](2);
        opts[0] = "Yes";
        opts[1] = "No";

        IChaosOracleRegistry(registry).registerForSettlement{value: reward}(
            marketId,
            _question,
            opts,
            _deadline
        );

        emit MarketCreated(marketId, msg.sender, _question, _deadline, reward);
    }

    // ============ Betting ============

    /// @notice Place a bet on a market outcome
    /// @param _marketId The market ID
    /// @param _option 0 = Yes, 1 = No
    function placeBet(uint256 _marketId, uint8 _option) external payable {
        Market storage m = markets[_marketId];
        if (!m.exists) revert MarketNotFound();
        if (m.settled) revert AlreadySettled();
        if (block.timestamp >= m.deadline) revert DeadlinePassed();
        if (_option > 1) revert InvalidOption();
        if (msg.value == 0) revert NoETHSent();

        m.pools[_option] += msg.value;
        bets[_marketId][msg.sender][_option] += msg.value;

        emit BetPlaced(_marketId, msg.sender, _option, msg.value);
    }

    // ============ IChaosOracleSettleable ============

    /// @inheritdoc IChaosOracleSettleable
    function setSettler(uint256 _marketId, address _settler) external {
        if (msg.sender != registry) revert OnlyRegistry();
        Market storage m = markets[_marketId];
        if (!m.exists) revert MarketNotFound();
        if (m.settler != address(0)) revert SettlerAlreadySet();

        m.settler = _settler;
    }

    /// @inheritdoc IChaosOracleSettleable
    function onSettlement(uint256 _marketId, uint8 _outcome, bytes32 _proofHash) external {
        Market storage m = markets[_marketId];
        if (!m.exists) revert MarketNotFound();
        if (msg.sender != m.settler) revert OnlySettler();
        if (m.settled) revert AlreadySettled();
        if (_outcome > 1) revert InvalidOutcome();

        m.outcome = _outcome;
        m.proofHash = _proofHash;
        m.settled = true;

        emit MarketSettled(_marketId, _outcome, _proofHash);
    }

    // ============ Claims ============

    /// @notice Claim winnings from a settled market
    /// @dev Winners receive pro-rata share from the losing pool.
    ///      If the losing pool is empty, winners get their bets back.
    /// @param _marketId The market ID
    function claimWinnings(uint256 _marketId) external {
        Market storage m = markets[_marketId];
        if (!m.settled) revert NotSettled();
        if (claimed[_marketId][msg.sender]) revert AlreadyClaimed();

        uint8 winningOption = m.outcome;
        uint256 userBet = bets[_marketId][msg.sender][winningOption];
        if (userBet == 0) revert NoWinningBet();

        claimed[_marketId][msg.sender] = true;

        uint256 winPool = m.pools[winningOption];
        uint256 losingOption = winningOption == 0 ? 1 : 0;
        uint256 losePool = m.pools[losingOption];

        // Pro-rata share: userBet / winPool * totalPool
        uint256 totalPool = winPool + losePool;
        uint256 payout = (userBet * totalPool) / winPool;

        (bool success,) = msg.sender.call{value: payout}("");
        if (!success) revert TransferFailed();

        emit WinningsClaimed(_marketId, msg.sender, payout);
    }

    // ============ View Functions ============

    /// @notice Get market details
    function getMarket(uint256 _marketId) external view returns (
        address creator,
        string memory _question,
        uint256 deadline,
        uint256 yesPool,
        uint256 noPool,
        uint8 outcome,
        bool settled
    ) {
        Market storage m = markets[_marketId];
        return (m.creator, m.question, m.deadline, m.pools[0], m.pools[1], m.outcome, m.settled);
    }

    /// @notice Get a user's bet on a specific option
    function getUserBet(uint256 _marketId, address _user, uint8 _option) external view returns (uint256) {
        return bets[_marketId][_user][_option];
    }

    receive() external payable {}
}
