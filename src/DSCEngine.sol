//SPDX_License-Identifier: MIT
pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Praise
 * 
 */

contract DSCEngine is ReentrancyGuard {
    
    // ERRORS //
    error DSCEngine__MoreThanZero();
    error DSCEngine__UnmatchedArrayLengths();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();

    // STATE VARIABLES //
    uint256 private constant LIQUIDATION_TRESHOLD = 50;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    mapping(address token => address priceFeed) private s_priceFeeds; // maps token address to chainlink price feed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited; // maps user to collateral amount deposited in specific token
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted; // maps user to amount of DSC minted
    
    DecentralizedStableCoin immutable i_dsc;
    address[] private s_collateralTokens;

    // EVENTS // 
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed from, address indexed to, address indexed token, uint256 amount);

    // MODIFIERS //
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) revert DSCEngine__MoreThanZero();
        _;
    }

    modifier isTokenAllowed(address token){
        if(s_priceFeeds[token] == address(0)) revert DSCEngine__TokenNotAllowed();
        _;
    }

    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        if(tokenAddresses.length != priceFeedAddresses.length) revert DSCEngine__UnmatchedArrayLengths();

        //loop through token and price feed arrays to map tokens to priceFeeds appropriately
        for (uint i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    // EXTERNAL FUNCTIONS // 
    
    /**
     * @param debtToCover: The amount of collateral we wish to pay back on behalf of the user
     * @notice Anyone can liquidate another user when their health factor becomes damaged
     */
    function liquidate (address tokenCollateralAddress, address user, uint256 debtToCover) external moreThanZero(debtToCover) nonReentrant {
        uint256 startingHealthFactor = _healthFactor(user);
        if (startingHealthFactor >= MIN_HEALTH_FACTOR) revert DSCEngine__HealthFactorOk();

        //Here were going to figure out how much DSC in $ is owed by the user
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(tokenCollateralAddress, debtToCover);


    }

    // Redeems collateral and burns DSC in the same transaction 
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral); // checks health factor after redeeming
    }

    function redeemCollateral (address tokenCollateralAddress, uint256 amountCollateral) public moreThanZero(amountCollateral) nonReentrant {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
    }

    function _redeemCollateral (address from, address to, address tokenCollateralAddress, uint256 amountCollateral) private  {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if(!success) revert DSCEngine__TransferFailed();
    }

    function depositCollateralAndMintDsc (address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToMint) external{
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    function depositCollateral( 
        address tokenCollateralAddress, //address of the collateral token to be deposited
        uint256 amountCollateral // collateral amount to deposit
     ) public moreThanZero(amountCollateral) isTokenAllowed(tokenCollateralAddress) nonReentrant {
         s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral; 
         emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

         bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
         if (!success) revert DSCEngine__TransferFailed();

         _revertIfHealthFactorIsBroken(msg.sender);
     }

    /**
     * @param amountDscToMint The amount of DSC tokens to mint
     */
     function mintDsc (uint256 amountDscToMint) public moreThanZero(amountDscToMint) {
         s_DSCMinted[msg.sender] += amountDscToMint;

         _revertIfHealthFactorIsBroken(msg.sender);

         bool success = i_dsc.mint(msg.sender, amountDscToMint);
        
         if(!success) revert DSCEngine__MintFailed(); 
     }

     function burnDsc (uint256 amount) public moreThanZero(amount) {
        s_DSCMinted[msg.sender] -= amount;
        bool success = i_dsc.transferFrom(msg.sender, address(this), amount);

        if(!success) revert DSCEngine__TransferFailed();

        i_dsc.burn(amount);
        _revertIfHealthFactorIsBroken(msg.sender); 
     }

     // INTERNAL FUNCTIONS // 

     function _revertIfHealthFactorIsBroken(address user) internal view {
         uint256 userHealthFactor = _healthFactor(user);
         if (userHealthFactor < MIN_HEALTH_FACTOR) revert DSCEngine__BreaksHealthFactor(userHealthFactor);

     }

     function _healthFactor(address user) private view returns (uint256) {
         (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);

         // Liquidation treshold = 50
         // Liquidation precision (to avoid decimals) = 100
         uint256 collateralAdjustedForTreshold = (collateralValueInUsd * 50) / 100;
         return (collateralAdjustedForTreshold * 100) / totalDscMinted;
     }

     // We aret trying to figure how much ETH/Collateral  == $ amount in DSC . TO know how much we need to repay behalf of user to be liquidiated 
     function getTokenAmountFromUsd(address tokenCollateralAddress, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[tokenCollateralAddress]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        // price is returned with 8 decimals, we have to multiply by 10^10 to make it 10^18 (wei's decimals)
        return ( usdAmountInWei * (10 ** 18) / ( uint256(price) * (10 ** 10 ) ) );

     }

     function _getAccountInformation(address user) private view returns (uint256 totalDscMinted, uint256 collateralValueInUsd){
         totalDscMinted = s_DSCMinted[user];
         collateralValueInUsd = getAccountCollateralValue(user);
     }

     function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {

         for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
         }
         return totalCollateralValueInUsd;
     }

     function getUsdValue(address token, uint256 amount) public view returns(uint256) {
         AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
         (, int256 price,,,) = priceFeed.latestRoundData();

         return ( ((uint256(price) * 10 ** 10 ) * amount ) / 10 ** 18 );
     }


}