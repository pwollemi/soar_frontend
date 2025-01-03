// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {USDC} from "../../contracts/mock/USDC.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WETH9} from "../../contracts/vendor/canonical-weth/contracts/WETH9.sol";
import {RWAPriceConsumerV3} from "../../contracts/mock/RWAOracle.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {MockRWA} from "../../contracts/mock/MockRWA.sol";
// import {Lendefi} from "../../contracts/lender/Lendefi.sol";

contract LendefiTest is BasicDeploy {
    // Events
    event Borrow(address indexed user, uint256 indexed positionId, uint256 amount);
    event EnteredIsolationMode(address indexed user, uint256 indexed positionId, address indexed asset);
    event ExitedIsolationMode(address indexed user, uint256 indexed positionId);

    // Contract instances
    MockRWA internal rwaToken;
    RWAPriceConsumerV3 internal rwaOracleInstance;
    WETHPriceConsumerV3 internal wethOracleInstance;

    // Constants for price setting
    uint256 internal constant ETH_PRICE = 2500e8; // $2500 per ETH
    uint256 internal constant RWA_PRICE = 1000e8; // $1000 per RWA token

    function setUp() public {
        // Use deployCompleteWithOracle() instead of deployComplete()
        deployCompleteWithOracle();
        assertEq(tokenInstance.totalSupply(), 0);

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Deploy mock tokens
        // Note: usdcInstance is already deployed by deployCompleteWithOracle()
        wethInstance = new WETH9();
        rwaToken = new MockRWA("Ondo Finance", "ONDO");

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        rwaOracleInstance = new RWAPriceConsumerV3();

        // Set prices
        wethOracleInstance.setPrice(int256(ETH_PRICE)); // $2500 per ETH
        rwaOracleInstance.setPrice(int256(RWA_PRICE)); // $1000 per RWA token

        // Set the minimum oracles required to 1 to avoid NotEnoughOracles errors
        vm.startPrank(address(timelockInstance));
        oracleInstance.updateMinimumOracles(1);

        // Register oracles with Oracle module
        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(wethInstance), address(wethOracleInstance));

        oracleInstance.addOracle(address(rwaToken), address(rwaOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(rwaToken), address(rwaOracleInstance));
        vm.stopPrank();

        // Setup roles
        vm.prank(guardian);
        ecoInstance.grantRole(REWARDER_ROLE, address(LendefiInstance));

        _setupAssets();
        _setupLiquidity();
    }

    function _setupAssets() internal {
        vm.startPrank(address(timelockInstance));

        // Configure RWA token (isolated)
        LendefiInstance.updateAssetConfig(
            address(rwaToken),
            address(rwaOracleInstance),
            8,
            18,
            1,
            650,
            750,
            1_000_000 ether,
            IPROTOCOL.CollateralTier.ISOLATED,
            100_000e6
        );

        // Configure WETH (cross-collateral)
        LendefiInstance.updateAssetConfig(
            address(wethInstance),
            address(wethOracleInstance),
            8,
            18,
            1,
            800,
            850,
            1_000_000 ether,
            IPROTOCOL.CollateralTier.CROSS_A,
            0
        );
        vm.stopPrank();
    }

    function _setupLiquidity() internal {
        usdcInstance.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), 1_000_000e6);
        LendefiInstance.supplyLiquidity(1_000_000e6);
        vm.stopPrank();
    }

    // Test 3: Borrow exceeding isolation debt cap should revert
    function test_Revert_BorrowExceedingIsolationDebtCap() public {
        // Configure asset with low isolation debt cap
        vm.prank(address(timelockInstance));
        LendefiInstance.updateAssetConfig(
            address(rwaToken),
            address(rwaOracleInstance),
            8, // Oracle decimals
            18, // Asset decimals
            1, // Active
            650, // 65% LTV
            750, // 75% liquidation threshold
            1_000_000 ether, // Max supply limit
            IPROTOCOL.CollateralTier.ISOLATED, // Tier
            50_000e6 // Isolation debt cap (lower than potential borrow amount)
        );

        // Setup borrower with collateral
        rwaToken.mint(bob, 100 ether);

        vm.startPrank(bob);
        // Create isolated position
        LendefiInstance.createPosition(address(rwaToken), true);
        uint256 positionId = 0;

        // Supply collateral
        rwaToken.approve(address(LendefiInstance), 100 ether);
        LendefiInstance.supplyCollateral(address(rwaToken), 100 ether, positionId);

        // Try to borrow more than isolation debt cap but within credit limit
        uint256 borrowAmount = 60_000e6; // Within 65% LTV but above 50k isolation cap

        // Updated to use custom error
        vm.expectRevert(
            abi.encodeWithSelector(
                IPROTOCOL.IsolationDebtCapExceeded.selector,
                address(rwaToken),
                borrowAmount, // requested
                50_000e6 // cap
            )
        );
        LendefiInstance.borrow(positionId, borrowAmount);
        vm.stopPrank();
    }

    // Debug test to check credit limit calculation
    // Debug test to check credit limit calculation
    function test_Debug_CreditLimit() public {
        // Setup borrower with collateral
        rwaToken.mint(bob, 100 ether);

        vm.startPrank(bob);
        // First enter isolation mode
        LendefiInstance.createPosition(address(rwaToken), true);
        uint256 positionId = 0;

        // Supply collateral
        rwaToken.approve(address(LendefiInstance), 100 ether);
        LendefiInstance.supplyCollateral(address(rwaToken), 100 ether, positionId);

        // Calculate expected credit limit
        // 100 tokens * $1000 per token * 65% LTV = $65,000 (6 decimal USDC)
        uint256 expectedCreditLimit = 65_000e6;

        // Try to borrow exactly at the credit limit
        LendefiInstance.borrow(positionId, expectedCreditLimit);

        // Now try to borrow $1 more - this should revert
        uint256 currentDebt = LendefiInstance.getPositionDebt(bob, positionId);
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(bob, positionId);

        // The error should reflect that the total debt (current + new amount) would exceed the credit limit
        vm.expectRevert(
            abi.encodeWithSelector(
                IPROTOCOL.ExceedsCreditLimit.selector,
                currentDebt + 1e6, // Total debt after adding new amount
                creditLimit // Current credit limit
            )
        );
        LendefiInstance.borrow(positionId, 1e6);
        vm.stopPrank();
    }

    // Test with a higher borrow amount that should definitely revert
    function test_Revert_BorrowExceedingCreditLimit_Higher() public {
        // Setup borrower with collateral
        rwaToken.mint(bob, 100 ether);

        vm.startPrank(bob);
        // First enter isolation mode
        LendefiInstance.createPosition(address(rwaToken), true);
        uint256 positionId = 0;

        // Supply collateral
        rwaToken.approve(address(LendefiInstance), 100 ether);
        LendefiInstance.supplyCollateral(address(rwaToken), 100 ether, positionId);

        // Set a higher isolation debt cap to ensure we hit credit limit error first
        vm.stopPrank();
        vm.prank(address(timelockInstance));
        LendefiInstance.updateAssetConfig(
            address(rwaToken),
            address(rwaOracleInstance),
            8, // Oracle decimals
            18, // Asset decimals
            1, // Active
            650, // 65% LTV
            750, // 75% liquidation threshold
            1_000_000 ether, // Max supply limit
            IPROTOCOL.CollateralTier.ISOLATED, // Tier
            300_000e6 // Isolation debt cap increased to be higher than our credit limit
        );
        vm.startPrank(bob);

        // Try to borrow way more than allowed
        uint256 excessBorrowAmount = 200_000e6; // $200,000 is definitely more than 65% of $100,000

        // Calculate credit limit for correct error value
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(bob, positionId);

        // Updated to use custom error
        vm.expectRevert(
            abi.encodeWithSelector(
                IPROTOCOL.ExceedsCreditLimit.selector,
                excessBorrowAmount, // requested
                creditLimit // creditLimit
            )
        );
        LendefiInstance.borrow(positionId, excessBorrowAmount);
        vm.stopPrank();
    }

    // Test with a slightly higher borrow amount
    function test_Revert_BorrowExceedingCreditLimit() public {
        // Setup borrower with collateral
        rwaToken.mint(bob, 100 ether);

        vm.startPrank(bob);
        // Create isolated position - this automatically sets isolation mode
        LendefiInstance.createPosition(address(rwaToken), true);
        uint256 positionId = 0;

        // Supply collateral
        rwaToken.approve(address(LendefiInstance), 100 ether);
        LendefiInstance.supplyCollateral(address(rwaToken), 100 ether, positionId);

        // Try to borrow more than allowed (100 tokens * $1000 * 65% = $65,000)
        uint256 excessBorrowAmount = 65_001e6; // Just $1 over the limit

        // Calculate credit limit for correct error value
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(bob, positionId);

        // Updated to use custom error
        vm.expectRevert(
            abi.encodeWithSelector(
                IPROTOCOL.ExceedsCreditLimit.selector,
                excessBorrowAmount, // requested
                creditLimit // creditLimit
            )
        );
        LendefiInstance.borrow(positionId, excessBorrowAmount);
        vm.stopPrank();
    }

    function test_Debug_CreditLimitCalculation() public {
        rwaToken.mint(bob, 100 ether);

        vm.startPrank(bob);
        LendefiInstance.createPosition(address(rwaToken), true);
        uint256 positionId = 0;

        // Supply collateral
        rwaToken.approve(address(LendefiInstance), 100 ether);
        LendefiInstance.supplyCollateral(address(rwaToken), 100 ether, positionId);

        // Debug prints
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(bob, positionId);
        console2.log("Credit Limit:", creditLimit);

        IPROTOCOL.Asset memory asset = LendefiInstance.getAssetInfo(address(rwaToken));
        console2.log("Asset Decimals:", asset.decimals);
        console2.log("Oracle Decimals:", asset.oracleDecimals);
        console2.log("Borrow Threshold:", asset.borrowThreshold);

        uint256 price = LendefiInstance.getAssetPrice(address(rwaToken));
        console2.log("Asset Price:", price);

        // Calculation:
        // 100 ether (10^18) * $1000 (10^8) * 650 / (1000 * 10^18 * 10^8) = 65_000_000_000 (65M USDC with 6 decimals)
        uint256 expected = (100 ether * price * 650) / (1000 * 10 ** asset.decimals);
        expected = expected / 10 ** asset.oracleDecimals * 1e6; // Convert to USDC decimals
        console2.log("Expected Credit Limit:", expected);

        assertEq(creditLimit, expected);
        vm.stopPrank();
    }

    function test_CollateralTracking_Isolated() public {
        rwaToken.mint(bob, 100 ether);

        vm.startPrank(bob);
        // Create isolated position
        LendefiInstance.createPosition(address(rwaToken), true);
        uint256 positionId = 0;

        // Supply collateral
        rwaToken.approve(address(LendefiInstance), 100 ether);
        LendefiInstance.supplyCollateral(address(rwaToken), 50 ether, positionId);

        // Check collateral is tracked
        assertEq(LendefiInstance.getUserCollateralAmount(bob, positionId, address(rwaToken)), 50 ether);

        // Add more collateral
        LendefiInstance.supplyCollateral(address(rwaToken), 50 ether, positionId);
        assertEq(LendefiInstance.getUserCollateralAmount(bob, positionId, address(rwaToken)), 100 ether);

        // Try to borrow first
        uint256 borrowAmount = 65_000e6; // 65000 USDC (65% of $100,000)
        LendefiInstance.borrow(positionId, borrowAmount);

        // Attempt to withdraw collateral should fail due to existing debt
        uint256 withdrawAmount = 30 ether;
        uint256 remainingCollateral = 100 ether - withdrawAmount;
        uint256 newCreditLimit = LendefiInstance.calculateCreditLimit(bob, positionId) * remainingCollateral / 100 ether;

        vm.expectRevert(
            abi.encodeWithSelector(
                IPROTOCOL.WithdrawalExceedsCreditLimit.selector, bob, positionId, borrowAmount, newCreditLimit
            )
        );
        LendefiInstance.withdrawCollateral(address(rwaToken), 30 ether, positionId);

        // Repay debt first
        usdcInstance.approve(address(LendefiInstance), borrowAmount);
        LendefiInstance.repay(positionId, borrowAmount);

        // Now withdraw should succeed
        LendefiInstance.withdrawCollateral(address(rwaToken), 30 ether, positionId);
        assertEq(LendefiInstance.getUserCollateralAmount(bob, positionId, address(rwaToken)), 70 ether);
        vm.stopPrank();
    }

    function test_CollateralTracking_CrossCollateral() public {
        vm.deal(bob, 10 ether);
        rwaToken.mint(bob, 100 ether);

        vm.startPrank(bob);
        wethInstance.deposit{value: 10 ether}();
        // Create cross-collateral position
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = 0;

        // Supply multiple types of collateral
        wethInstance.approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 5 ether, positionId);

        // Verify first collateral
        assertEq(LendefiInstance.getUserCollateralAmount(bob, positionId, address(wethInstance)), 5 ether);

        // Try to add RWA token to cross position (should revert)
        rwaToken.approve(address(LendefiInstance), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.IsolationModeRequired.selector, address(rwaToken)));
        LendefiInstance.supplyCollateral(address(rwaToken), 100 ether, positionId);

        // Add more WETH
        LendefiInstance.supplyCollateral(address(wethInstance), 5 ether, positionId);
        assertEq(LendefiInstance.getUserCollateralAmount(bob, positionId, address(wethInstance)), 10 ether);

        // Withdraw all WETH
        LendefiInstance.withdrawCollateral(address(wethInstance), 10 ether, positionId);
        assertEq(LendefiInstance.getUserCollateralAmount(bob, positionId, address(wethInstance)), 0);
        vm.stopPrank();
    }

    // Test 1: Simple borrow test
    function test_SimpleBorrow() public {
        // Setup borrower with collateral
        rwaToken.mint(bob, 100 ether);

        vm.startPrank(bob);
        // Create isolated position
        LendefiInstance.createPosition(address(rwaToken), true);
        uint256 positionId = 0; // First position

        // Supply collateral
        rwaToken.approve(address(LendefiInstance), 100 ether);
        LendefiInstance.supplyCollateral(address(rwaToken), 100 ether, positionId);

        // Calculate expected borrow amount (65% of collateral value)
        // 100 RWA * $1000 * 65% = $65,000 = 65_000e6 USDC
        uint256 borrowAmount = 65_000e6; // USDC is 6 decimals

        // Check initial balance
        uint256 initialBalance = usdcInstance.balanceOf(bob);

        // Borrow
        vm.expectEmit(true, true, false, true);
        emit Borrow(bob, positionId, borrowAmount);
        LendefiInstance.borrow(positionId, borrowAmount);

        // Verify borrow was successful
        assertEq(usdcInstance.balanceOf(bob), initialBalance + borrowAmount);

        // Verify debt was recorded
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(position.debtAmount, borrowAmount);
        vm.stopPrank();
    }

    function test_InterestRateScaling() public {
        // Setup initial liquidity
        usdcInstance.mint(alice, 10000e6);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), 10000e6);
        LendefiInstance.supplyLiquidity(10000e6);
        vm.stopPrank();

        // Setup collateral
        vm.deal(bob, 10 ether);
        vm.startPrank(bob);
        wethInstance.deposit{value: 10 ether}();
        LendefiInstance.createPosition(address(wethInstance), false);
        wethInstance.approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 10 ether, 0);

        // Get initial rate at 0% utilization
        uint256 rate1 = LendefiInstance.getBorrowRate(IPROTOCOL.CollateralTier.CROSS_A);

        // Borrow 50% of available liquidity
        uint256 borrowAmount = 5000e6;
        LendefiInstance.borrow(0, borrowAmount);

        // Get rate at 50% utilization
        uint256 rate2 = LendefiInstance.getBorrowRate(IPROTOCOL.CollateralTier.CROSS_A);

        assertTrue(rate2 > rate1, "Interest rate should increase with utilization");
        vm.stopPrank();
    }

    function test_LiquidationThresholds() public {
        // Initial price: $2500 per ETH
        wethOracleInstance.setPrice(2500e8);

        // Setup liquidity
        usdcInstance.mint(alice, 10000e6);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), 10000e6);
        LendefiInstance.supplyLiquidity(10000e6);
        vm.stopPrank();

        // Setup borrower with 10 ETH
        vm.deal(bob, 10 ether);
        vm.startPrank(bob);
        wethInstance.deposit{value: 10 ether}();
        LendefiInstance.createPosition(address(wethInstance), false);
        wethInstance.approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 10 ether, 0);

        // Initial collateral value: 10 ETH * $2500 = $25,000
        // Borrow threshold is 80%, so can borrow up to $20,000
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(bob, 0);
        console2.log("Initial credit limit:", creditLimit / 1e6);
        LendefiInstance.borrow(0, creditLimit);

        // Initial check
        uint256 initialDebt = LendefiInstance.calculateDebtWithInterest(bob, 0);
        uint256 initialCollateral = LendefiInstance.calculateCreditLimit(bob, 0);
        console2.log("Initial debt:", initialDebt / 1e6);
        console2.log("Initial collateral value:", initialCollateral / 1e6);

        // We need to drop the price more significantly
        // Currently: 10 ETH * $1000 * 85% = $8,500 (still above debt)
        // Let's drop to $200 instead: 10 ETH * $200 * 85% = $1,700
        wethOracleInstance.setPrice(200e8);

        uint256 newDebt = LendefiInstance.calculateDebtWithInterest(bob, 0);
        uint256 newCollateralValue = LendefiInstance.calculateCreditLimit(bob, 0);

        console2.log("Final debt:", newDebt / 1e6);
        console2.log("Final collateral value:", newCollateralValue / 1e6);

        // Should now be liquidatable since collateral value (~$1,700) < debt ($20,000)
        assertTrue(newDebt > newCollateralValue, "Debt should exceed collateral value");
        assertTrue(LendefiInstance.isLiquidatable(bob, 0), "Position should be liquidatable");
        vm.stopPrank();
    }

    function test_UtilizationCap() public {
        // Set initial price correctly
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
        // Setup borrower
        vm.deal(bob, 500 ether);
        vm.startPrank(bob);
        wethInstance.deposit{value: 500 ether}();
        LendefiInstance.createPosition(address(wethInstance), false);
        wethInstance.approve(address(LendefiInstance), 500 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 500 ether, 0);

        // Try to borrow more than total liquidity (1_000_000e6)
        uint256 requestedAmount = 1_000_001e6;
        uint256 availableLiquidity = 1_000_000e6;
        vm.expectRevert(
            abi.encodeWithSelector(IPROTOCOL.InsufficientLiquidity.selector, requestedAmount, availableLiquidity)
        );
        LendefiInstance.borrow(0, 1_000_001e6); // Trying to borrow more than total supply

        // Now borrow exactly at the total liquidity
        LendefiInstance.borrow(0, 1_000_000e6);
        vm.stopPrank();

        // Verify 100% utilization
        assertEq(LendefiInstance.getUtilization(), 1e6, "Utilization should be 100%");
    }

    function test_CantBorrowBeyondYourMeans() public {
        // Setup borrower
        vm.deal(bob, 10 ether);
        vm.startPrank(bob);
        wethInstance.deposit{value: 10 ether}();
        LendefiInstance.createPosition(address(wethInstance), false);
        wethInstance.approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 10 ether, 0);
        // Calculate credit limit for correct error value
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(bob, 0);
        uint256 requestedAmount = 500_000e6;
        // Try to borrow more than collateral is worth
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.ExceedsCreditLimit.selector, requestedAmount, creditLimit));
        LendefiInstance.borrow(0, requestedAmount);
    }
}
