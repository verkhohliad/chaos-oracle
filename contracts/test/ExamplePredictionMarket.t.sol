// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ExamplePredictionMarket} from "../src/example/ExamplePredictionMarket.sol";
import {ChaosOracleRegistry} from "../src/ChaosOracleRegistry.sol";
import {PredictionSettlementLogic} from "../src/PredictionSettlementLogic.sol";
import {MockChaosCore} from "./mocks/MockChaosCore.sol";

contract ExamplePredictionMarketTest is Test {
    ExamplePredictionMarket market;
    ChaosOracleRegistry registry;
    MockChaosCore chaosCore;
    PredictionSettlementLogic logic;
    address creForwarder = address(0xC4E);

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        chaosCore = new MockChaosCore();
        logic = new PredictionSettlementLogic();
        chaosCore.registerLogicModule(address(logic), "PredictionSettlement");

        registry = new ChaosOracleRegistry(
            address(chaosCore), address(logic), creForwarder
        );

        market = new ExamplePredictionMarket(address(registry));

        // Fund test accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    // ============ Market Creation Tests ============

    function test_createMarket() public {
        vm.prank(alice);
        uint256 marketId = market.createMarket{value: 1 ether}(
            "Will ETH hit $5000?",
            block.timestamp + 1 days
        );

        assertEq(marketId, 0);

        (address creator, string memory question, uint256 deadline,
         uint256 yesPool, uint256 noPool, uint8 outcome, bool settled) = market.getMarket(0);

        assertEq(creator, alice);
        assertEq(question, "Will ETH hit $5000?");
        assertEq(deadline, block.timestamp + 1 days);
        // 90% of 1 ether seeds the Yes pool
        assertEq(yesPool, 0.9 ether);
        assertEq(noPool, 0);
        assertEq(outcome, 255); // unresolved
        assertFalse(settled);
    }

    function test_createMarket_registersWithRegistry() public {
        vm.prank(alice);
        market.createMarket{value: 1 ether}(
            "Will ETH hit $5000?",
            block.timestamp + 1 days
        );

        // 10% should have been sent to registry
        assertEq(address(registry).balance, 0.1 ether);
    }

    function test_createMarket_revertsNoETH() public {
        vm.prank(alice);
        vm.expectRevert("ExamplePredictionMarket: no ETH sent");
        market.createMarket("Q?", block.timestamp + 1 days);
    }

    function test_createMarket_revertsEmptyQuestion() public {
        vm.prank(alice);
        vm.expectRevert("ExamplePredictionMarket: empty question");
        market.createMarket{value: 1 ether}("", block.timestamp + 1 days);
    }

    function test_createMarket_revertsDeadlineInPast() public {
        vm.prank(alice);
        vm.expectRevert("ExamplePredictionMarket: deadline in past");
        market.createMarket{value: 1 ether}("Q?", block.timestamp - 1);
    }

    // ============ Betting Tests ============

    function test_placeBet() public {
        vm.prank(alice);
        market.createMarket{value: 1 ether}(
            "Q?", block.timestamp + 1 days
        );

        vm.prank(bob);
        market.placeBet{value: 2 ether}(0, 1); // Bet 2 ETH on No

        (, , , , uint256 noPool, , ) = market.getMarket(0);
        assertEq(noPool, 2 ether);
        assertEq(market.getUserBet(0, bob, 1), 2 ether);
    }

    function test_placeBet_revertsInvalidOption() public {
        vm.prank(alice);
        market.createMarket{value: 1 ether}("Q?", block.timestamp + 1 days);

        vm.prank(bob);
        vm.expectRevert("ExamplePredictionMarket: invalid option");
        market.placeBet{value: 1 ether}(0, 2);
    }

    function test_placeBet_revertsAfterDeadline() public {
        uint256 deadline = block.timestamp + 1 days;
        vm.prank(alice);
        market.createMarket{value: 1 ether}("Q?", deadline);

        vm.warp(deadline + 1);
        vm.prank(bob);
        vm.expectRevert("ExamplePredictionMarket: deadline passed");
        market.placeBet{value: 1 ether}(0, 0);
    }

    function test_placeBet_revertsNoETH() public {
        vm.prank(alice);
        market.createMarket{value: 1 ether}("Q?", block.timestamp + 1 days);

        vm.prank(bob);
        vm.expectRevert("ExamplePredictionMarket: no ETH sent");
        market.placeBet(0, 0);
    }

    // ============ Settlement Tests ============

    function test_setSettler_revertsNotRegistry() public {
        vm.expectRevert("ExamplePredictionMarket: only registry");
        market.setSettler(0, address(0x123));
    }

    function test_onSettlement() public {
        // Create market
        vm.prank(alice);
        market.createMarket{value: 1 ether}("Q?", block.timestamp + 1 days);

        // Set settler via registry
        address settler = address(0x5E771E);
        vm.prank(address(registry));
        market.setSettler(0, settler);

        // Settle
        vm.prank(settler);
        market.onSettlement(0, 0, bytes32("proof"));

        (, , , , , uint8 outcome, bool settled) = market.getMarket(0);
        assertEq(outcome, 0);
        assertTrue(settled);
    }

    function test_onSettlement_revertsNotSettler() public {
        vm.prank(alice);
        market.createMarket{value: 1 ether}("Q?", block.timestamp + 1 days);

        vm.prank(address(registry));
        market.setSettler(0, address(0x5E771E));

        vm.expectRevert("ExamplePredictionMarket: only settler");
        market.onSettlement(0, 0, bytes32("proof"));
    }

    // ============ Claim Tests ============

    function test_claimWinnings_yesWins() public {
        // Alice creates market (seeds Yes with 0.9 ETH)
        vm.prank(alice);
        market.createMarket{value: 1 ether}("Q?", block.timestamp + 1 days);

        // Bob bets 2 ETH on No
        vm.prank(bob);
        market.placeBet{value: 2 ether}(0, 1);

        // Set settler & settle with Yes (0) winning
        address settler = address(0x5E771E);
        vm.prank(address(registry));
        market.setSettler(0, settler);

        vm.prank(settler);
        market.onSettlement(0, 0, bytes32("proof"));

        // Alice claims - she has all 0.9 ETH in Yes pool
        // Total pool = 0.9 + 2 = 2.9 ETH
        // Her share = (0.9 / 0.9) * 2.9 = 2.9 ETH
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        market.claimWinnings(0);
        uint256 aliceGain = alice.balance - aliceBefore;
        assertEq(aliceGain, 2.9 ether);
    }

    function test_claimWinnings_noWins() public {
        vm.prank(alice);
        market.createMarket{value: 1 ether}("Q?", block.timestamp + 1 days);

        // Bob bets 2 ETH on No
        vm.prank(bob);
        market.placeBet{value: 2 ether}(0, 1);

        address settler = address(0x5E771E);
        vm.prank(address(registry));
        market.setSettler(0, settler);

        vm.prank(settler);
        market.onSettlement(0, 1, bytes32("proof")); // No wins

        // Bob claims - he has all 2 ETH in No pool
        // Total pool = 0.9 + 2 = 2.9 ETH
        // His share = (2 / 2) * 2.9 = 2.9 ETH
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        market.claimWinnings(0);
        uint256 bobGain = bob.balance - bobBefore;
        assertEq(bobGain, 2.9 ether);
    }

    function test_claimWinnings_revertsNotSettled() public {
        vm.prank(alice);
        market.createMarket{value: 1 ether}("Q?", block.timestamp + 1 days);

        vm.prank(alice);
        vm.expectRevert("ExamplePredictionMarket: not settled");
        market.claimWinnings(0);
    }

    function test_claimWinnings_revertsDoubleClaim() public {
        vm.prank(alice);
        market.createMarket{value: 1 ether}("Q?", block.timestamp + 1 days);

        address settler = address(0x5E771E);
        vm.prank(address(registry));
        market.setSettler(0, settler);

        vm.prank(settler);
        market.onSettlement(0, 0, bytes32("proof"));

        vm.prank(alice);
        market.claimWinnings(0);

        vm.prank(alice);
        vm.expectRevert("ExamplePredictionMarket: already claimed");
        market.claimWinnings(0);
    }

    function test_claimWinnings_revertsNoWinningBet() public {
        vm.prank(alice);
        market.createMarket{value: 1 ether}("Q?", block.timestamp + 1 days);

        vm.prank(bob);
        market.placeBet{value: 2 ether}(0, 1); // Bob bets No

        address settler = address(0x5E771E);
        vm.prank(address(registry));
        market.setSettler(0, settler);

        vm.prank(settler);
        market.onSettlement(0, 0, bytes32("proof")); // Yes wins

        // Bob tries to claim but he bet on No
        vm.prank(bob);
        vm.expectRevert("ExamplePredictionMarket: no winning bet");
        market.claimWinnings(0);
    }

    // ============ Multiple Bettors Test ============

    function test_claimWinnings_prorate() public {
        address charlie = address(0xCC);
        vm.deal(charlie, 100 ether);

        vm.prank(alice);
        market.createMarket{value: 10 ether}("Q?", block.timestamp + 1 days);
        // Alice: 9 ETH on Yes

        // Bob bets 3 ETH on Yes
        vm.prank(bob);
        market.placeBet{value: 3 ether}(0, 0);

        // Charlie bets 8 ETH on No
        vm.prank(charlie);
        market.placeBet{value: 8 ether}(0, 1);

        // Settle: Yes wins
        address settler = address(0x5E771E);
        vm.prank(address(registry));
        market.setSettler(0, settler);

        vm.prank(settler);
        market.onSettlement(0, 0, bytes32("proof"));

        // Total pool = 9 + 3 + 8 = 20 ETH
        // Yes pool = 12, No pool = 8
        // Alice share: (9/12) * 20 = 15 ETH
        // Bob share: (3/12) * 20 = 5 ETH

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        market.claimWinnings(0);
        assertEq(alice.balance - aliceBefore, 15 ether);

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        market.claimWinnings(0);
        assertEq(bob.balance - bobBefore, 5 ether);
    }

    receive() external payable {}
}
