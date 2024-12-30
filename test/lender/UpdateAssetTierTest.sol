// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";
import {console2} from "forge-std/console2.sol";
import {MockPriceOracle} from "../../contracts/mock/MockPriceOracle.sol";

contract UpdateAssetTierTest is BasicDeploy {
    // Events
    event AssetTierUpdated(address indexed asset, IPROTOCOL.CollateralTier tier);

    MockPriceOracle internal wethOracle;
    MockPriceOracle internal usdcOracle;

    function setUp() public {
        deployComplete();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Deploy USDC
        usdcInstance = new USDC();

        // Deploy Lendefi
        bytes memory data = abi.encodeCall(
            Lendefi.initialize,
            (
                address(usdcInstance),
                address(tokenInstance),
                address(ecoInstance),
                address(treasuryInstance),
                address(timelockInstance),
                guardian
            )
        );

        address payable proxy = payable(Upgrades.deployUUPSProxy("Lendefi.sol", data));
        LendefiInstance = Lendefi(proxy);

        // Set up oracles
        wethOracle = new MockPriceOracle();
        wethOracle.setPrice(2500e8); // $2500 per ETH
        wethOracle.setTimestamp(block.timestamp);
        wethOracle.setRoundId(1);
        wethOracle.setAnsweredInRound(1);

        usdcOracle = new MockPriceOracle();
        usdcOracle.setPrice(1e8); // $1 per USDC
        usdcOracle.setTimestamp(block.timestamp);
        usdcOracle.setRoundId(1);
        usdcOracle.setAnsweredInRound(1);

        // Set up mock assets in the protocol
        vm.startPrank(address(timelockInstance));

        // Add WETH as CROSS_A initially
        LendefiInstance.updateAssetConfig(
            address(wethInstance),
            address(wethOracle),
            8, // oracle decimals
            18, // asset decimals
            1, // active
            800, // 80% borrow threshold
            850, // 85% liquidation threshold
            1_000_000 ether, // max supply
            IPROTOCOL.CollateralTier.CROSS_A,
            0 // no isolation debt cap
        );

        // Add USDC as STABLE initially
        LendefiInstance.updateAssetConfig(
            address(usdcInstance),
            address(usdcOracle),
            8, // oracle decimals
            6, // asset decimals
            1, // active
            900, // 90% borrow threshold
            950, // 95% liquidation threshold
            10_000_000e6, // max supply
            IPROTOCOL.CollateralTier.STABLE,
            0 // no isolation debt cap
        );

        vm.stopPrank();
    }

    function test_UpdateAssetTier_AccessControl() public {
        // Regular user should not be able to update asset tier
        vm.startPrank(alice);
        vm.expectRevert();
        LendefiInstance.updateAssetTier(address(wethInstance), IPROTOCOL.CollateralTier.ISOLATED);
        vm.stopPrank();

        // Manager should be able to update asset tier
        vm.prank(address(timelockInstance));
        LendefiInstance.updateAssetTier(address(wethInstance), IPROTOCOL.CollateralTier.ISOLATED);

        // Verify tier was updated
        IPROTOCOL.Asset memory asset = LendefiInstance.getAssetInfo(address(wethInstance));
        assertEq(uint256(asset.tier), uint256(IPROTOCOL.CollateralTier.ISOLATED));
    }

    function test_UpdateAssetTier_RequireAssetListed() public {
        address unlisted = address(0x123); // Random unlisted address

        vm.startPrank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(Lendefi.AssetNotListed.selector, unlisted));
        LendefiInstance.updateAssetTier(unlisted, IPROTOCOL.CollateralTier.ISOLATED);
        vm.stopPrank();
    }

    function test_UpdateAssetTier_StateChange_AllTiers() public {
        // Test updating to each possible tier
        vm.startPrank(address(timelockInstance));

        // Update to ISOLATED
        LendefiInstance.updateAssetTier(address(wethInstance), IPROTOCOL.CollateralTier.ISOLATED);
        IPROTOCOL.Asset memory asset = LendefiInstance.getAssetInfo(address(wethInstance));
        assertEq(uint256(asset.tier), uint256(IPROTOCOL.CollateralTier.ISOLATED));

        // Update to CROSS_A
        LendefiInstance.updateAssetTier(address(wethInstance), IPROTOCOL.CollateralTier.CROSS_A);
        asset = LendefiInstance.getAssetInfo(address(wethInstance));
        assertEq(uint256(asset.tier), uint256(IPROTOCOL.CollateralTier.CROSS_A));

        // Update to CROSS_B
        LendefiInstance.updateAssetTier(address(wethInstance), IPROTOCOL.CollateralTier.CROSS_B);
        asset = LendefiInstance.getAssetInfo(address(wethInstance));
        assertEq(uint256(asset.tier), uint256(IPROTOCOL.CollateralTier.CROSS_B));

        // Update to STABLE
        LendefiInstance.updateAssetTier(address(wethInstance), IPROTOCOL.CollateralTier.STABLE);
        asset = LendefiInstance.getAssetInfo(address(wethInstance));
        assertEq(uint256(asset.tier), uint256(IPROTOCOL.CollateralTier.STABLE));

        vm.stopPrank();
    }

    function test_UpdateAssetTier_EventEmission() public {
        vm.expectEmit(true, false, false, true);
        emit AssetTierUpdated(address(wethInstance), IPROTOCOL.CollateralTier.ISOLATED);

        vm.prank(address(timelockInstance));
        LendefiInstance.updateAssetTier(address(wethInstance), IPROTOCOL.CollateralTier.ISOLATED);
    }

    function test_UpdateAssetTier_MultipleAssets() public {
        vm.startPrank(address(timelockInstance));

        // Update WETH to ISOLATED
        LendefiInstance.updateAssetTier(address(wethInstance), IPROTOCOL.CollateralTier.ISOLATED);
        IPROTOCOL.Asset memory wethAsset = LendefiInstance.getAssetInfo(address(wethInstance));
        assertEq(uint256(wethAsset.tier), uint256(IPROTOCOL.CollateralTier.ISOLATED));

        // Update USDC to CROSS_B
        LendefiInstance.updateAssetTier(address(usdcInstance), IPROTOCOL.CollateralTier.CROSS_B);
        IPROTOCOL.Asset memory usdcAsset = LendefiInstance.getAssetInfo(address(usdcInstance));
        assertEq(uint256(usdcAsset.tier), uint256(IPROTOCOL.CollateralTier.CROSS_B));

        // Ensure updates are independent
        wethAsset = LendefiInstance.getAssetInfo(address(wethInstance));
        assertEq(uint256(wethAsset.tier), uint256(IPROTOCOL.CollateralTier.ISOLATED));

        vm.stopPrank();
    }

    function test_UpdateAssetTier_NoChangeWhenSameTier() public {
        vm.startPrank(address(timelockInstance));

        // Get initial tier
        IPROTOCOL.Asset memory initialAsset = LendefiInstance.getAssetInfo(address(wethInstance));
        IPROTOCOL.CollateralTier initialTier = initialAsset.tier;

        // Update to same tier
        vm.expectEmit(true, false, false, true);
        emit AssetTierUpdated(address(wethInstance), initialTier);
        LendefiInstance.updateAssetTier(address(wethInstance), initialTier);

        // Verify tier is unchanged
        IPROTOCOL.Asset memory updatedAsset = LendefiInstance.getAssetInfo(address(wethInstance));
        assertEq(uint256(updatedAsset.tier), uint256(initialTier));

        vm.stopPrank();
    }
}
