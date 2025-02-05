//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";    
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address weth;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 100 ether;

    function setUp() public {
        deployer = new DeployDSC();
        // vm.prank(msg.sender); //change sender to msg.sender before deployment
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, , weth, , ) = config.activeNetworkConfig();
        //changes made below
        vm.prank(msg.sender); // Ensure msg.sender is the test contract address
        dsc.transferOwnership(address(dsce)); // Transfer ownership to DSCEngine
    }

    /////////////////
    ////PRICE TESTS//
    /////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        //  15e8 * 2000/ETH = 30,000e18;
        uint256 expectedUsd = 30000e18;
        vm.prank(address(dsce)); // Simulate correct ownership
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    ///////////////////////////////////
    ////depositCOllateral TESTS////////
    //////////////////////////////////
                                            
    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);// Expect the transaction to revert if the collateral amount is zero
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();

    }
}