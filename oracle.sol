// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.10;

import {Ownable} from '../dependencies/openzeppelin/contracts/Ownable.sol';
import {IERC20} from '../dependencies/openzeppelin/contracts/IERC20.sol';
import {SafeCast} from '../dependencies/openzeppelin/contracts/SafeCast.sol';
import {IPoolAddressesProvider} from '../interfaces/IPoolAddressesProvider.sol';
import {IPriceOracleGetter} from '../interfaces/IPriceOracleGetter.sol';

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IJoeRouter {
    function WAVAX() external pure returns (address);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
}

// Chainlink AggregatorV3Interface
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    function getRoundData(uint80 _roundId) external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

/**
 * @title LPBasedOracle
 * @author Arena
 * @notice Oracle for assets based on Liquidity Pool token pairs and Chainlink price feeds
 * @dev Uses DEX liquidity pools and Chainlink to determine prices in the native currency
 */
contract LPBasedOracle is IPriceOracleGetter, Ownable {
    using SafeCast for uint256;

    // Base currency address (0 for USD)
    address public immutable BASE_CURRENCY;
    
    // Base currency unit (10^8 for USD)
    uint256 public immutable BASE_CURRENCY_UNIT;
    
    // Fallback oracle address
    address public immutable FALLBACK_ORACLE;
    
    // The address of the pool addresses provider
    IPoolAddressesProvider public immutable ADDRESSES_PROVIDER;
    
    // Router addresses - changed from immutable to allow updates
    address public arenaRouter;
    address public kyberRouter;
    address public paraswapRouter;
    address public joeRouter;
    
    // Native token (WAVAX on Avalanche)
    address public immutable nativeToken;
    
    // Map of asset addresses to LP addresses
    mapping(address => address) private assetToLp;
    
    // Map of asset addresses to prices (fallback if LP calculation fails)
    mapping(address => uint256) private assetPrices;
    
    // Standard token decimals for well known tokens
    mapping(address => uint8) private tokenDecimals;
    
    // Chainlink price feeds
    mapping(address => address) private chainlinkFeeds;
    
    // Constants
    uint256 private constant PRICE_PRECISION = 10**8; // 8 decimals for USD price
    
    event AssetSourceUpdated(address indexed asset, address indexed source);
    event FallbackPriceUpdated(address indexed asset, uint256 price);
    event TokenDecimalsUpdated(address indexed asset, uint8 decimals);
    event ChainlinkFeedUpdated(address indexed asset, address indexed feed);
    event RoutersUpdated(address arenaRouter, address kyberRouter, address paraswapRouter, address joeRouter);
    
    /**
     * @notice Constructor
     * @param provider The address of the pool addresses provider
     * @param assets Array of assets to be initialized
     * @param sources Array of LP addresses to be used as price sources
     * @param fallbackOracle The address of the fallback oracle
     * @param baseCurrency The base currency address (0x0 for USD)
     * @param baseCurrencyUnit The base currency unit (10^8 for USD)
     * @param _arenaRouter Arena router address (optional)
     * @param _kyberRouter Kyber router address (optional)
     * @param _paraswapRouter Paraswap router address (optional)
     * @param _joeRouter Trader Joe router address
     * @param _nativeToken Native token address (WAVAX)
     */
    constructor(
        address provider,
        address[] memory assets,
        address[] memory sources,
        address fallbackOracle,
        address baseCurrency,
        uint256 baseCurrencyUnit,
        address _arenaRouter,
        address _kyberRouter,
        address _paraswapRouter,
        address _joeRouter,
        address _nativeToken
    ) {
        require(assets.length == sources.length, "Arrays length mismatch");
        require(_joeRouter != address(0), "Joe router cannot be zero");
        require(_nativeToken != address(0), "Native token cannot be zero");
        
        ADDRESSES_PROVIDER = IPoolAddressesProvider(provider);
        FALLBACK_ORACLE = fallbackOracle;
        BASE_CURRENCY = baseCurrency;
        BASE_CURRENCY_UNIT = baseCurrencyUnit;
        
        arenaRouter = _arenaRouter;
        kyberRouter = _kyberRouter;
        paraswapRouter = _paraswapRouter;
        joeRouter = _joeRouter;
        nativeToken = _nativeToken;
        
        // Initialize assets and sources
        for (uint256 i = 0; i < assets.length; i++) {
            _setAssetSource(assets[i], sources[i]);
        }
        
        // Default decimals for WAVAX
        tokenDecimals[_nativeToken] = 18;
    }
    
    /**
     * @notice Sets the LP source for an asset
     * @param asset The address of the asset
     * @param source The address of the LP to use as price source
     */
    function setAssetSource(address asset, address source) external onlyOwner {
        _setAssetSource(asset, source);
    }
    
    /**
     * @notice Internal function to set the LP source for an asset
     * @param asset The address of the asset
     * @param source The address of the LP to use as price source
     */
    function _setAssetSource(address asset, address source) internal {
        require(asset != address(0), "Asset cannot be zero address");
        require(source != address(0), "Source cannot be zero address");
        
        assetToLp[asset] = source;
        emit AssetSourceUpdated(asset, source);
    }
    
    /**
     * @notice Sets a fallback price for an asset
     * @param asset The address of the asset
     * @param price The price of the asset
     */
    function setFallbackPrice(address asset, uint256 price) external onlyOwner {
        assetPrices[asset] = price;
        emit FallbackPriceUpdated(asset, price);
    }
    
    /**
     * @notice Sets decimals for a token
     * @param asset The address of the asset
     * @param decimals The number of decimals for the asset
     */
    function setTokenDecimals(address asset, uint8 decimals) external onlyOwner {
        tokenDecimals[asset] = decimals;
        emit TokenDecimalsUpdated(asset, decimals);
    }
    
    /**
     * @notice Updates the router addresses
     * @param _arenaRouter Arena router address
     * @param _kyberRouter Kyber router address
     * @param _paraswapRouter Paraswap router address
     * @param _joeRouter Joe router address
     */
    function setRouters(
        address _arenaRouter,
        address _kyberRouter,
        address _paraswapRouter,
        address _joeRouter
    ) external onlyOwner {
        require(_joeRouter != address(0), "Joe router cannot be zero");
        
        arenaRouter = _arenaRouter;
        kyberRouter = _kyberRouter;
        paraswapRouter = _paraswapRouter;
        joeRouter = _joeRouter;
        
        emit RoutersUpdated(_arenaRouter, _kyberRouter, _paraswapRouter, _joeRouter);
    }
    
    /**
     * @notice Sets a Chainlink price feed for an asset
     * @param asset The address of the asset
     * @param feed The address of the Chainlink price feed
     */
    function setChainlinkFeed(address asset, address feed) external onlyOwner {
        require(asset != address(0), "Asset cannot be zero address");
        
        chainlinkFeeds[asset] = feed;
        emit ChainlinkFeedUpdated(asset, feed);
    }
    
    /**
     * @notice Gets the price of an asset
     * @param asset The address of the asset
     * @return The price of the asset (normalized to 8 decimals)
     */
    function getAssetPrice(address asset) external view override returns (uint256) {
        if (asset == BASE_CURRENCY) {
            return BASE_CURRENCY_UNIT;
        }
        
        // First try Chainlink price feed if available
        try this.getChainlinkPrice(asset) returns (uint256 price) {
            if (price > 0) {
                return price;
            }
        } catch {}
        
        // Then try to get price from LP
        try this.getLpPrice(asset) returns (uint256 price) {
            if (price > 0) {
                return price;
            }
        } catch {}
        
        // If LP price fails or returns zero, try fallback price
        if (assetPrices[asset] > 0) {
            return assetPrices[asset];
        }
        
        // If no fallback price, try fallback oracle
        if (FALLBACK_ORACLE != address(0)) {
            try IPriceOracleGetter(FALLBACK_ORACLE).getAssetPrice(asset) returns (uint256 price) {
                if (price > 0) {
                    return price;
                }
            } catch {}
        }
        
        revert("No price found for asset");
    }
    
    /**
     * @notice Gets the price from Chainlink price feed
     * @param asset The address of the asset
     * @return The price from Chainlink price feed
     */
    function getChainlinkPrice(address asset) external view returns (uint256) {
        address feedAddress = chainlinkFeeds[asset];
        if (feedAddress == address(0)) {
            return 0;
        }
        
        AggregatorV3Interface feed = AggregatorV3Interface(feedAddress);
        
        try feed.latestRoundData() returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            // Check for negative price
            if (answer <= 0) {
                return 0;
            }
            
            // Check for stale data
            if (block.timestamp - updatedAt > 86400) { // 24 hours
                return 0;
            }
            
            // Convert to our precision (8 decimals)
            uint8 feedDecimals = feed.decimals();
            uint256 price = uint256(answer);
            
            if (feedDecimals < 8) {
                price = price * (10**(8 - feedDecimals));
            } else if (feedDecimals > 8) {
                price = price / (10**(feedDecimals - 8));
            }
            
            return price;
        } catch {
            return 0;
        }
    }
    
    /**
     * @notice Gets the price of an asset from its LP
     * @param asset The address of the asset
     * @return The price of the asset from LP calculations
     */
    function getLpPrice(address asset) external view returns (uint256) {
        address lpAddress = assetToLp[asset];
        if (lpAddress == address(0)) {
            return 0;
        }
        
        IUniswapV2Pair pair = IUniswapV2Pair(lpAddress);
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        
        address token0 = pair.token0();
        address token1 = pair.token1();
        
        // If the asset is directly paired with BASE_CURRENCY or USDC/USDT/DAI
        if (token0 == asset || token1 == asset) {
            address otherToken = token0 == asset ? token1 : token0;
            uint112 assetReserve = token0 == asset ? reserve0 : reserve1;
            uint112 otherReserve = token0 == asset ? reserve1 : reserve0;
            
            // Get asset decimals - default to 18 if not set
            uint8 assetDecimals = tokenDecimals[asset];
            if (assetDecimals == 0) {
                assetDecimals = 18; // Default to 18 decimals for most tokens
            }
            
            // Check if the other token is a stablecoin or base currency
            if (isStablecoin(otherToken)) {
                // Direct stablecoin pairing - assume 6 decimals for stablecoins
                return calculatePriceFromStable(assetReserve, otherReserve, assetDecimals);
            }
            
            // If paired with native token, get native token price first
            if (otherToken == nativeToken) {
                uint256 nativePrice = getNativeTokenPrice();
                if (nativePrice > 0) {
                    // Multiply by the native token price
                    return calculatePriceFromToken(assetReserve, otherReserve, assetDecimals, nativePrice);
                }
            }
        }
        
        // Try using Trader Joe router for price calculation
        return calculatePriceViaRouter(asset);
    }
    
    /**
     * @notice Calculates asset price via DEX router
     * @param asset The address of the asset
     * @return The price of the asset via router
     */
    function calculatePriceViaRouter(address asset) internal view returns (uint256) {
        if (joeRouter == address(0)) {
            return 0;
        }
        
        // Get asset decimals - default to 18 if not set
        uint8 assetDecimals = tokenDecimals[asset];
        if (assetDecimals == 0) {
            assetDecimals = 18; // Default to 18 decimals for most tokens
        }
        
        // Create path from asset to WAVAX
        address[] memory path = new address[](2);
        path[0] = asset;
        path[1] = nativeToken;
        
        try IJoeRouter(joeRouter).getAmountsOut(10**assetDecimals, path) returns (uint[] memory amounts) {
            if (amounts.length >= 2 && amounts[1] > 0) {
                uint256 wavaxAmount = amounts[1];
                uint256 nativePrice = getNativeTokenPrice();
                
                if (nativePrice > 0) {
                    // Convert to USD terms
                    uint256 usdValue = (wavaxAmount * nativePrice) / 10**18; // WAVAX has 18 decimals
                    return usdValue;
                }
            }
        } catch {}
        
        return 0;
    }
    
    /**
     * @notice Gets the native token (WAVAX) price
     * @return The price of the native token in USD terms
     */
    function getNativeTokenPrice() internal view returns (uint256) {
        // First try to get from Chainlink if available
        try this.getChainlinkPrice(nativeToken) returns (uint256 price) {
            if (price > 0) {
                return price;
            }
        } catch {}
        
        // Then try to get from fallback oracle
        if (FALLBACK_ORACLE != address(0)) {
            try IPriceOracleGetter(FALLBACK_ORACLE).getAssetPrice(nativeToken) returns (uint256 price) {
                if (price > 0) {
                    return price;
                }
            } catch {}
        }
        
        // If no price from fallback, return hardcoded fallback
        return assetPrices[nativeToken] > 0 ? assetPrices[nativeToken] : 20 * 10**8; // $20 as default
    }
    
    /**
     * @notice Checks if a token is a stablecoin
     * @param token The address of the token
     * @return True if the token is a stablecoin
     */
    function isStablecoin(address token) internal pure returns (bool) {
        // Common Avalanche stablecoins (lowercase for comparison)
        bytes32 tokenHash = keccak256(abi.encodePacked(token));
        
        // USDC, USDT, DAI, MIM, FRAX, etc.
        bytes32 usdc = 0x8f47F47220F88B4F7B96d566D539fE5e7a8938a62e7BAD11A739ce22DF8aa906;
        bytes32 usdt = 0x24ef3146ca9bfa04459ec5331e9f8823a571a1f281c60fb9cf5c67c4118ef27c;
        bytes32 dai = 0xaef8d2bc21f13a911fa37f25ce16252a5694620bcfd5e69661a8638447dea284;
        
        return (
            tokenHash == usdc ||
            tokenHash == usdt ||
            tokenHash == dai
        );
    }
    
    /**
     * @notice Calculates price from a stablecoin pairing
     * @param assetReserve The reserve of the asset in the LP
     * @param stableReserve The reserve of the stablecoin in the LP
     * @param assetDecimals The decimals of the asset
     * @return The price of the asset in USD terms
     */
    function calculatePriceFromStable(
        uint112 assetReserve, 
        uint112 stableReserve, 
        uint8 assetDecimals
    ) internal pure returns (uint256) {
        uint256 price = (uint256(stableReserve) * 10**8 * 10**assetDecimals) / (uint256(assetReserve) * 10**6);
        return price;
    }
    
    /**
     * @notice Calculates price from a token pairing
     * @param assetReserve The reserve of the asset in the LP
     * @param tokenReserve The reserve of the token in the LP
     * @param assetDecimals The decimals of the asset
     * @param tokenPrice The price of the token
     * @return The price of the asset in USD terms
     */
    function calculatePriceFromToken(
        uint112 assetReserve, 
        uint112 tokenReserve, 
        uint8 assetDecimals, 
        uint256 tokenPrice
    ) internal pure returns (uint256) {
        uint256 price = (uint256(tokenReserve) * tokenPrice * 10**assetDecimals) / (uint256(assetReserve) * 10**18);
        return price;
    }
} 
