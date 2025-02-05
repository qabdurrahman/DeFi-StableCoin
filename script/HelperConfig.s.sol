//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract HelperConfig is Script {
    struct NetworkConfig { // from DSCEngine.sol like from constructor
        address wethUsdPriceFeed;
        address wbtcUsdPriceFeed;
        address weth; // weth is the ERC20 version of Ethereum
        address wbtc; // wbtc is the ERC20 version of Bitcoin
        uint256 deployerKey;
    }

    uint8 public constant DECIMALS = 8;
    int256 public constant ETH_USD_PRICE = 2000e8;
    int256 public constant BTC_USD_PRICE = 1000e8;
    uint256 public DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;


    NetworkConfig public activeNetworkConfig;

    constructor() {
        if (block.chainid == 11155111) { // 11155111 it is the chainid of anvil--make a note of it
            activeNetworkConfig = getSepoliaConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilEthConfig();
        }
    }

    function getSepoliaConfig() public view returns (NetworkConfig memory) {
        return NetworkConfig({
            wethUsdPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306, // the address we get it from docs.chain.link/pricefeed website like on sepolia ETH/USD ADDRESS
            wbtcUsdPriceFeed: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43, // the address we get it from docs.chain.link/pricefeed website like on sepolia BTC/USD ADDRESS
            weth: 0xdd13E55209Fd76AfE204dBda4007C227904f0a81,//took from patrick's content
            wbtc: 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063, // took from patrick's content
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }
  
    function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory) {
        if (activeNetworkConfig.wethUsdPriceFeed != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast();
        MockV3Aggregator ethUsdPriceFeed = new MockV3Aggregator(
            DECIMALS,
            ETH_USD_PRICE
        );
        // ERC20Mock wethMock = new ERC20Mock("WETH", "WETH", msg.sender, 1000e8); // we get this from the constructor of the ERC0Mock.sol
        // like while running it is expecting 0 argymenst but we are passing 4 arguments
        ERC20Mock wethMock = new ERC20Mock(); // we get this from the constructor of the ERC0Mock.sol
        MockV3Aggregator btcUsdPriceFeed = new MockV3Aggregator(
            DECIMALS,
            BTC_USD_PRICE
        );
        // ERC20Mock wbtcMock = new ERC20Mock("WBTC", "WBTC", msg.sender, 1000e8); // we get this from the constructor of the ERC0Mock.sol
        ERC20Mock wbtcMock = new ERC20Mock(); // we get this from the constructor of the ERC0Mock.sol

        vm.stopBroadcast();
        return NetworkConfig({
            wethUsdPriceFeed: address(ethUsdPriceFeed),
            wbtcUsdPriceFeed: address(btcUsdPriceFeed),
            weth: address(wethMock),
            wbtc: address(wbtcMock),
            // deployerKey: vm.envUint("PRIVATE_KEY")
            deployerKey: DEFAULT_ANVIL_KEY
        });
    }
}