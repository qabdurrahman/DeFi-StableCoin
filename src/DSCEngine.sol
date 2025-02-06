//SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";


/**
 * @title DSCEngine (Decentralized Stable Coin Engine)
 * @author Quraishi Abdur Rahman
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg
 * This stablecoin has the properties:
 * - Exogenous Collateral (ETH & BTC)
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed bu WETH and WBTC.
 *
 * Our DSC system should always be "over-collateralized". At no point should the value of the collateral be less than the value of the DSC.
 * @notice This contract is the core of the DSC system. It handles all the logic for mining and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is very loosely based on the MakerDAO DSS (DAI) system.
 */

contract DSCEngine is ReentrancyGuard {
    //////////////
    // ERRORS   //
    //////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    //////////////////////
    // STATE VARIABLES //
    /////////////////////
    uint256 private constant ADDITION_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized IT IS 200% COLLATERALIZED
    uint256 private constant LIQUIDATION_PRECISION = 100; 
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus for liquidators

    mapping(address token => address priceFeed) private s_priceFeeds; // token to price feeds
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens; // array of collateral tokens

    DecentralizedStableCoin private immutable i_dsc; // DSC token

    //////////////////////
    //  EVENTS //////////
    /////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount);

    //////////////
    // MODIFIERS//
    //////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ////////////////////////
    ///  FUNCTIONS  ///////
    //////////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        //USD price feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        // For example ETH/USD, BTC/USD, MKR/USD, etc
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////
    // EXTERNAL FUNCTIONS///
    ////////////////////////

    /*
    * @param tokenCollateralAddress The address of the token to deposit as collateral
    * @param amountCollateral The amount of the token to deposit as collateral
    * @param amountDscToMint The amount of DSC(decentralized stable coin) to mint
    * @notice This function will deposit your collateral and mint in one transaction
    */

    function depositCollateralAndMintDSC(address tokenCollateralAddress, uint256 amoountCollateral, uint256 amountDscToMint) external {
        depositCollateral(tokenCollateralAddress, amoountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of the token to deposit as collateral
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        // external
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        } 
    }

    /**
    * @param tokenCollateralAddress The collateral address to redeem
    * @param amountCollateral The amount of collateral to redeem
    * @param amountDscToBurn The amount of DSC to burn
    * This function burns DSC and redee,s underlying collateral in one transaction
     */

    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn) external {
        this.burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral already checks health factor
    }

    // in order to redeem the collateral:
    // 1. Check if the health factor is > 1 after collateral is pulled

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) public moreThanZero(amountCollateral) nonReentrant { // made it public from external
        /**s_collateralDeposited[msg.sender][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(msg.sender, tokenCollateralAddress, tokenCollateralAddress, amountCollateral);
        // here we r gonna transfer the collateral back to the user then calcluate the Health factor if it is less then 1 we r gonna revert the transaction
        bool success = IERC20(tokenCollateralAddress).transfer(msg.sender, amountCollateral);
        if(!success) {
            revert DSCEngine__TransferFailed();
        }*/
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral); // like from msg.sender to msg.sender it is this way
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // $100 ETh --> $20 DSC
    //  100 (break)
    // FIRST burn the DSC
    // NEXT redeem ETH

    // Check if the collateral value > DSC amount
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        // if they minted too much like ($150 DSC, $100 ETH)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }

    }

    // 
    function burnDsc(uint256 amount) external moreThanZero(amount) {
       /** s_DSCMinted[msg.sender] -= amount;
        bool success = i_dsc.transferFrom(msg.sender, address(this), amount);
        // This conditional is hypothethically unreachable
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amount);
        */
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);// we here dont think that it would ever hit this
    }


    // If we do start nearing undercollateralization, we need someone to liquidate the positions
    
    // $100 ETH backing $50 DSC
    // $20 ETH back $50 DSC <-- Now DSC isn't worth $1

    // $75 backing $50 DSC
    // liquidator take $75 ETH, and oays of the $50 DSC

    // IF someone is undercollateralized, we need to liquidate their position


    /**
    * @param collateral The erc20 collateral address to liquidate from the user
    * @param user The user who has broken the health factor. Their _healthFactor should be below MIN_HEALTH_FACTOR
    * @param debtToCover The amount of DSC u want to burn to improve the users health factor
    * @notice U can partially liquidate a user
    * @notice This function working assumes the protocol will be roughly 200% overcollateralized inn order for this to work.
    * @notice A known bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentive the liquidators.
    * For example, if the price of the collateral plummeted before anyone could be liquidated.
     */

    function liquidate(address collateral, address user, uint256 debtToCover) external moreThanZero(debtToCover) {
        // we need to check first the health factor of the user so....--->
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        // WE want to burn their DSC "debt"
        // And take their collateral
        // Bad USer: $140 ETH, $100 DSC
        // debtToCover = $100 DSC
        // $100 DSC == ??? ETH?
        uint256 tokeAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // ANd give them a 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury
        uint256 bonusCollateral = (tokeAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokeAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        // We need to burn the DSC
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
    }

    function getHealthFactor() external view {}

    ///////////////////////////////////
    // PRIVATE & INTERNAL View FUNCTIONS ///
    //////////////////////////////////
    /** here we are using _ bcoz like to get us know it is an private function */

    /*
     * @dev Low-level internal function, do not call unless the function calling it is 
     * checking for health factors being broken
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // price of ETH (token)
        // $/ETH ETH ???
        // $2000 / ETH. $1000 = 0.5 ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,) = priceFeed.latestRoundData();
        // ($10e18 * 1e8) / ($2000e8 * 1e10)
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITION_FEED_PRECISION);
    }

    function _getAccountInformation(address user) private view returns (uint256 totalDscMinted, uint256 collateralValueInUsd) {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getCollateralValue(user);
    }
    /**
    * Returns how close to liquidation a user is
    * If a user goes below 1, then they can get liquidated
     */
    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral value
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        /**
        // like say
        // 1000 ETH * 50 = 50,000 / 100 = 500
        // $150 ETH / 100 DSC = 1.5
        // 150 * 50 = 7500 / 100 = (75 / 100) which is definitely < 1
        // which means 200% collateralized is required
        */
        
        // $1000 ETH / 100 DSC
        // 1000 * 50 = 50000 / 100 = (500 / 100) > 1
        return (collateralAdjustedForThreshold *  PRECISION) / totalDscMinted; // this will give us the true health factor
    }

    // 1. To chcek health factor (like do they have enough collateral?)
    // 2. If not, revert
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }


    ///////////////////////////////////////
    // PUBLIC & EXTERNAL View FUNCTIONS///
    //////////////////////////////////////
    function getCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // 1. loop thru each collateral token, get the amount they have deposited, and map it
        // to the price feed to get the USD value
        for(uint256 i=0; i<s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns(uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,) = priceFeed.latestRoundData();
        // 1 ETH = 1000 USD
        // 1 ETH = 1000000000000000000 // 1e18
        // The returned value from CL will be 1000 * 1e8
        return ((uint256(price) * ADDITION_FEED_PRECISION) * amount)/PRECISION; // price is in 8 decimals
        //(1000 * 1e10 * 1e8) * 1000 * 1e18

    }

}
