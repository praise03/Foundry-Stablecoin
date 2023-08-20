//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import { Test } from "forge-std/Test.sol";
import "forge-std/console.sol";
import { DeployDSC } from "../../script/DeployDSC.s.sol";
import { DecentralizedStableCoin } from "../../src/DecentralizedStableCoin.sol";
import { DSCEngine } from "../../src/DSCEngine.sol";
import { HelperConfig } from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import { MockV3Aggregator } from "../../test/mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;
    address public USER = address(1);
    uint256 AMOUNT = 200 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dscEngine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed , weth , , ) = config.config();
        ERC20Mock(weth).mint(USER, AMOUNT);
    }

    modifier collateralDeposited {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), 1000 ether);
        dscEngine.depositCollateral(weth, AMOUNT);
        // uint256 collateralDepositedInUsd = dscEngine.getAccountCollateralValue(USER);
        // console.log(collateralDepositedInUsd);
        vm.stopPrank();
        _;
    }

    modifier dscMinted {
        vm.startPrank(USER);
        dscEngine.mintDsc(10 ether);
        dsc.approve(address(dscEngine), 1000 ether);
        vm.stopPrank();
        _;
    }

    modifier collateralDepositedAndDscMinted {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT);
        dscEngine.depositCollateral(weth, 50 ether);
        dscEngine.mintDsc(AMOUNT);
        dsc.approve(address(dscEngine), AMOUNT);
        vm.stopPrank();
        _;
    }

    function testTokenLengthToPriceFeedMismatch() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__UnmatchedArrayLengths.selector);

        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    function testGetTokenAmountFromUsd() public {
        uint256 udsAmountinWei = 100 ether;//ether == ^18;

        uint256 expectedweth = 0.05 ether;
        uint256 actualweth = dscEngine.getTokenAmountFromUsd(weth, udsAmountinWei);

        assertEq(actualweth, expectedweth);

    }

    function testGetUsdValue() public {
        uint256 ethAmount = 3e18;
        uint256 expectedUsd = 6000e18;
        uint256 actualUsd = dscEngine.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testDepositCollateral() public {
        ERC20Mock(weth).approve(address(dscEngine), 10 ether);
        vm.expectRevert(DSCEngine.DSCEngine__MoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock newToken = new ERC20Mock("TEST", "TST", USER, 1 ether);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        dscEngine.depositCollateral(address(newToken), 1 ether);
    }

    function  testGetExpectedAccountInformation() public collateralDeposited{
        (uint256 totalDscMinted, uint256 totalCollateralInUSD) = dscEngine.getAccountInformation(USER);  
        
        assertEq(AMOUNT, dscEngine.getTokenAmountFromUsd(weth, totalCollateralInUSD));
        assertEq(totalDscMinted, 0);
    }

    function testMintDscWithoutDepositingCollateral() collateralDeposited public  {
        vm.expectRevert(DSCEngine.DSCEngine__BreaksHealthFactor.selector);
        dscEngine.mintDsc(10);
    }

    function testCanMintDsc() public collateralDeposited {
        vm.prank(USER);
        dscEngine.mintDsc(10 ether );
        // (uint256 totalDscMinted, ) = dscEngine.getAccountInformation(USER);
        // console.log(totalDscMinted);
        // // cviusd = 40000000000000000000000;
        // uint256 cvTshd = (cviusd * 50) / 100;
        // 0.002000000000000000000
        //  return (cvtshd * 100) / totalDscMinted;
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 10 ether );
    }

    function testBurnZeroAmountDsc() public  collateralDepositedAndDscMinted {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__MoreThanZero.selector);
        dscEngine.burnDsc(0);
    }

    function testBurnDsc() public collateralDeposited {
        vm.startPrank(USER);
        dscEngine.mintDsc(100);
        dsc.approve(address(dscEngine), AMOUNT);
        dscEngine.burnDsc(90);
        vm.stopPrank();

        uint256 dscBalance = dscEngine.getDscBalance(USER);
        assertEq(dscBalance, 10);
    }

    function testRedeemCollateral() public collateralDepositedAndDscMinted {
        vm.startPrank(USER);
        uint256 startingBalance = ERC20Mock(weth).balanceOf(USER);
        // 20000000000000000000
        uint256 initialDepositedCollateralAmount = dscEngine.getDepositedCollateralAmount(weth, USER);

        console.log(initialDepositedCollateralAmount);
        
        dscEngine.redeemCollateral(weth, 5 ether);

        uint256 endingBalance = ERC20Mock(weth).balanceOf(USER);
        uint256 finalDepositedCollateralAmount = dscEngine.getDepositedCollateralAmount(weth, USER);

        assertEq(endingBalance, (startingBalance + 5 ether));
        assertEq(initialDepositedCollateralAmount, (finalDepositedCollateralAmount + 5 ether));
        vm.stopPrank();
    }

    function testHealthFactor() public {
        vm.startPrank(USER);
        
        ERC20Mock(weth).approve(address(dscEngine), 1 ether);
        dscEngine.depositCollateral(weth, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 500000000000000000));
        dscEngine.mintDsc(2000 ether);

        // console.log(dscEngine.getHealthFactor(USER));
        vm.stopPrank();
        // to calculate health factor
        // uint256 collateralAdjustedForTreshold = (collateralValueInUsd * 50) / 100;
        // return (collateralAdjustedForTreshold * 1e18) / totalDscMinted;
        // collateralvalueinUsd = (2000 ether * 50 ) / 100 = = 1e21
        // totalDscMinted = 2e21
        // 1000.000000000000000000
    }

    function testLiquidate() public  collateralDepositedAndDscMinted {

        // Init new user with .5 health factor, below health factor and can be liquidated
        address USER2 = address(2);
        ERC20Mock(weth).mint(USER2, 50 ether);
        vm.startPrank(USER2);
        
        ERC20Mock(weth).approve(address(dscEngine), 1000 ether);
        dscEngine.depositCollateral(weth, 20 ether);

        dscEngine.mintDsc(200 ether);
        dsc.approve(address(dscEngine), 2000 ether);
        

        // vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 500000000000000000));
        // dscEngine.mintDsc(1000 ether);
        vm.stopPrank();

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(15e8);

        uint256 startingHealthFactor = dscEngine.getHealthFactor(USER2);
        // calculate total debt of user2; 2000 * 1 = $2000
        // (,uint256 user2CollateralValue) = dscEngine.getAccountInformation(USER2);
        // console.log(dscEngine.getTokenAmountFromUsd(weth, 10 ether));
        // 1.000000000000000000
        // we choose to pay back $1000 out of user's $2000 debt
        // vm.startPrank(USER);
        // dscEngine.getHealthFactor(USER2);
        // // vm.prank(USER);
        // uint256 tokenAmountFromDebtCovered = dscEngine.getTokenAmountFromUsd(weth, 1000 ether);
        // uint256 bonusCollateral = (tokenAmountFromDebtCovered * 10) / 100;

        // uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        // console.log(totalCollateralToRedeem);
        // uint256 s_cd = dscEngine.getDepositedCollateralAmount(weth, USER2);
        // uint256 dscBal = dscEngine.getDscBalance(USER2); 
        // console.log(dscBal -= 1000 ether);
        // dscEngine.burnDsc(1000 ether);
        // vm.stopPrank();
        // console.log(dscEngine.getDscBalance(USER));
        // vm.prank(USER);
        // dscEngine._burnDsc(USER2, USER, 20 ether);

        vm.prank(USER);
        dscEngine.liquidate(weth, USER2, 100 ether);
    }



}