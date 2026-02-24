// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./interfaces/IAggregatorV3Interface.sol";
import "./interfaces/IPyth.sol";
import "./interfaces/IUniswapV3Pool.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./lib/TickMath.sol";
import "./lib/FullMath.sol";

/// @title Oracle: actual price from Chainlink, Pyth, Uniswap V3 TWAP (by freshness)
/// @notice getPrice(token): Pyth if updated < 60s ago, else Chainlink if < 10min, else Uniswap V3 TWAP / Uniswap V2.
/// @author 8lends team
contract Oracle is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    enum PriceSource {
        None,
        Pyth,
        ChainLink,
        Uniswap
    }

    uint8 public priceDecimals;
    uint256 public pythMaxAgeSec;
    uint256 public chainLinkMaxAgeSec;

    struct PriceResult {
        uint256 pythPrice;
        uint256 chainLinkPrice;
        uint256 uniswapPrice;
        uint256 price;
        PriceSource priceSource;
        uint256 pythUpdatedAt;
        uint256 chainLinkUpdatedAt;
    }

    address public pyth;

    mapping(address => address) public chainlinkFeeds;
    mapping(address => bytes32) public pythPriceIds;
    mapping(address => address) public uniswapPools;
    uint256 public twapWindowSeconds;
    /// @dev Max allowed deviation between sources, in percent (e.g. 5 = 5%).
    uint256 public maxPriceChangePercent;

    event ChainlinkFeedSet(address indexed token, address feed);
    event PythPriceIdSet(address indexed token, bytes32 priceId);
    event UniswapPoolSet(address indexed token, address pool);
    event PythSet(address pyth);
    event TwapWindowSecondsSet(uint256 sec);
    event PriceDecimalsSet(uint8 decimals);
    event PythMaxAgeSecSet(uint256 sec);
    event ChainLinkMaxAgeSecSet(uint256 sec);
    event MaxPriceChangePercentSet(uint256 percent);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param _owner Owner address
    function initialize(address _owner) public initializer {
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
        priceDecimals = 8;
        pythMaxAgeSec = 60;
        chainLinkMaxAgeSec = 60 * 60 * 24; // 24 hours
        twapWindowSeconds = 60 * 5; // 5 min; smaller window avoids 'OLD' on pools with short history
        maxPriceChangePercent = 5; // 5% max deviation
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function setPyth(address _pyth) external onlyOwner {
        pyth = _pyth;
        emit PythSet(_pyth);
    }

    function setUniswapPool(address _token, address _pool) external onlyOwner {
        uniswapPools[_token] = _pool;
        emit UniswapPoolSet(_token, _pool);
    }

    function setTwapWindowSeconds(uint256 _sec) external onlyOwner {
        twapWindowSeconds = _sec;
        emit TwapWindowSecondsSet(_sec);
    }

    function setChainlinkFeed(address _token, address _feed) external onlyOwner {
        chainlinkFeeds[_token] = _feed;
        emit ChainlinkFeedSet(_token, _feed);
    }

    function setPythPriceId(address _token, bytes32 _priceId) external onlyOwner {
        pythPriceIds[_token] = _priceId;
        emit PythPriceIdSet(_token, _priceId);
    }

    function setPriceDecimals(uint8 _decimals) external onlyOwner {
        priceDecimals = _decimals;
        emit PriceDecimalsSet(_decimals);
    }

    function setPythMaxAgeSec(uint256 _sec) external onlyOwner {
        pythMaxAgeSec = _sec;
        emit PythMaxAgeSecSet(_sec);
    }

    function setChainLinkMaxAgeSec(uint256 _sec) external onlyOwner {
        chainLinkMaxAgeSec = _sec;
        emit ChainLinkMaxAgeSecSet(_sec);
    }

    /// @param _percent Max deviation in percent (e.g. 5 = 5%), <= 100.
    function setMaxPriceChangePercent(uint256 _percent) external onlyOwner {
        require(_percent <= 100, "Oracle: percent > 100");
        maxPriceChangePercent = _percent;
        emit MaxPriceChangePercentSet(_percent);
    }

    /// @dev Returns true if _price is within maxPriceChangePercent of _reference (in both directions).
    /// maxPriceChangePercent is integer percent (e.g. 5 = 5%).
    function _isWithinDeviation(uint256 _price, uint256 _reference) internal view returns (bool) {
        if (_reference == 0) return true;
        if (maxPriceChangePercent >= 100) return true;
        uint256 minAllowed = (_reference * (100 - maxPriceChangePercent)) / 100;
        uint256 maxAllowed = (_reference * (100 + maxPriceChangePercent)) / 100;
        return _price >= minAllowed && _price <= maxAllowed;
    }

    /// @dev Returns true if _candidate is within deviation of all non-zero prices in the other two sources.
    function _passesDeviationCheck(
        uint256 _candidate,
        uint256 _other1,
        uint256 _other2
    ) internal view returns (bool) {
        if (_other1 > 0 && !_isWithinDeviation(_candidate, _other1)) return false;
        if (_other2 > 0 && !_isWithinDeviation(_candidate, _other2)) return false;
        return true;
    }

    /// @notice Returns all source prices (priceDecimals), actual price (by freshness), and chosen priceSource.
    /// If the chosen source deviates from other available sources by more than maxPriceChangePercent, the next source is used; if none pass, price is 0.
    function getPrice(address _token) external view returns (PriceResult memory result) {
        (result.pythPrice, result.pythUpdatedAt) = _getPythPriceAndTime(_token);
        (result.chainLinkPrice, result.chainLinkUpdatedAt) = _getChainlinkPriceAndTime(_token);
        result.uniswapPrice = _getUniswapTwapPrice(_token);
        uint256 now_ = block.timestamp;
        if (result.pythPrice > 0 && result.pythUpdatedAt > 0 && now_ - result.pythUpdatedAt <= pythMaxAgeSec) {
            if (_passesDeviationCheck(result.pythPrice, result.chainLinkPrice, result.uniswapPrice)) {
                result.price = result.pythPrice;
                result.priceSource = PriceSource.Pyth;
                return result;
            }
        }
        if (result.chainLinkPrice > 0 && result.chainLinkUpdatedAt > 0 && now_ - result.chainLinkUpdatedAt <= chainLinkMaxAgeSec) {
            if (_passesDeviationCheck(result.chainLinkPrice, result.pythPrice, result.uniswapPrice)) {
                result.price = result.chainLinkPrice;
                result.priceSource = PriceSource.ChainLink;
                return result;
            }
        }
        if (result.uniswapPrice > 0) {
            if (_passesDeviationCheck(result.uniswapPrice, result.pythPrice, result.chainLinkPrice)) {
                result.price = result.uniswapPrice;
                result.priceSource = PriceSource.Uniswap;
                return result;
            }
        }
        result.price = 0;
        result.priceSource = PriceSource.None;
        return result;
    }

    /// @dev Price and updatedAt from Chainlink (8 decimals); (0, 0) if not set or error.
    function _getChainlinkPriceAndTime(address _token) internal view returns (uint256 price, uint256 updatedAt) {
        address feed = chainlinkFeeds[_token];
        if (feed == address(0)) return (0, 0);
        try IAggregatorV3Interface(feed).latestRoundData() returns (
            uint80,
            int256 answer,
            uint256,
            uint256 updatedAt_,
            uint80
        ) {
            if (answer <= 0) return (0, 0);
            uint8 feedDecimals = IAggregatorV3Interface(feed).decimals();
            return (_toDecimals(uint256(answer), feedDecimals, priceDecimals), updatedAt_);
        } catch {
            return (0, 0);
        }
    }

    /// @dev Price and publishTime from Pyth. One scale: value = price * 10^expo -> target = price * 10^(expo + priceDecimals).
    function _getPythPriceAndTime(address _token) internal view returns (uint256 price, uint256 publishTime) {
        if (pyth == address(0)) return (0, 0);
        bytes32 id = pythPriceIds[_token];
        if (id == bytes32(0)) return (0, 0);
        try IPyth(pyth).getPrice(id) returns (IPyth.Price memory priceData) {
            int64 p = priceData.price;
            int32 expo = priceData.expo;
            if (p <= 0) return (0, 0);
            int32 shift = expo + int32(uint32(priceDecimals));
            uint256 scaled;
            if (shift == 0) {
                scaled = uint256(int256(p));
            } else if (shift > 0) {
                scaled = uint256(int256(p)) * (10 ** uint256(uint32(shift)));
            } else {
                scaled = uint256(int256(p)) / (10 ** uint256(uint32(-shift)));
            }
            return (scaled, priceData.publishTime);
        } catch {
            return (0, 0);
        }
    }

    /// @dev Price from Uniswap: try V3 TWAP first; on error treat pool as V2 and use getReserves (priceDecimals).
    /// @dev If poolAddr is address(1), return 1 USD in priceDecimals (for stablecoins without a real pool).
    function _getUniswapTwapPrice(address _token) internal view returns (uint256) {
        address poolAddr = uniswapPools[_token];
        if (poolAddr == address(0)) return 0;
        if (poolAddr == address(1)) return _toDecimals(1000000, 6, priceDecimals);
        if (twapWindowSeconds > 0) {
            try IUniswapV3Pool(poolAddr).token0() returns (address token0) {
                address token1 = IUniswapV3Pool(poolAddr).token1();
                address baseToken = _token == token0 ? token0 : token1;
                address quoteToken = _token == token0 ? token1 : token0;
                uint8 baseDecimals = IERC20Metadata(baseToken).decimals();
                uint128 baseAmount = uint128(10 ** baseDecimals);
                (int24 arithmeticMeanTick, bool consultOk) = _consultV3Pool(poolAddr, uint32(twapWindowSeconds));
                if (!consultOk) return _getUniswapV2Price(_token, poolAddr);
                uint256 quoteAmount = _getQuoteAtTick(arithmeticMeanTick, baseAmount, baseToken, quoteToken);
                if (quoteAmount == 0) return _getUniswapV2Price(_token, poolAddr);
                uint8 quoteDecimals = IERC20Metadata(quoteToken).decimals();
                return _toDecimals(quoteAmount, quoteDecimals, priceDecimals);
            } catch {
                return _getUniswapV2Price(_token, poolAddr);
            }
        }
        return _getUniswapV2Price(_token, poolAddr);
    }

    /// @dev Price from Uniswap V2 pair: getReserves, compare _token with token0 to get price in quote token (priceDecimals).
    function _getUniswapV2Price(address _token, address _poolAddr) internal view returns (uint256) {
        try IUniswapV2Pair(_poolAddr).getReserves() returns (uint112 reserve0, uint112 reserve1, uint32) {
            address token0 = IUniswapV2Pair(_poolAddr).token0();
            address token1 = IUniswapV2Pair(_poolAddr).token1();
            uint8 baseDecimals = IERC20Metadata(_token).decimals();
            uint256 quoteAmountWei;
            uint8 quoteDecimals;
            if (_token == token0) {
                if (reserve0 == 0) return 0;
                quoteAmountWei = (uint256(reserve1) * (10 ** baseDecimals)) / uint256(reserve0);
                quoteDecimals = IERC20Metadata(token1).decimals();
            } else if (_token == token1) {
                if (reserve1 == 0) return 0;
                quoteAmountWei = (uint256(reserve0) * (10 ** baseDecimals)) / uint256(reserve1);
                quoteDecimals = IERC20Metadata(token0).decimals();
            } else {
                return 0;
            }
            return _toDecimals(quoteAmountWei, quoteDecimals, priceDecimals);
        } catch {
            return 0;
        }
    }

    /// @dev Returns (arithmetic mean tick, true) or (0, false) if observe reverts (e.g. 'OLD' when window too large).
    function _consultV3Pool(address _pool, uint32 _secondsAgo) internal view returns (int24 arithmeticMeanTick, bool success) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = _secondsAgo;
        secondsAgos[1] = 0;
        try IUniswapV3Pool(_pool).observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            int56 delta = tickCumulatives[1] - tickCumulatives[0];
            arithmeticMeanTick = int24(delta / int56(int32(_secondsAgo)));
            if (delta < 0 && (delta % int56(int32(_secondsAgo)) != 0)) arithmeticMeanTick--;
            return (arithmeticMeanTick, true);
        } catch {
            return (0, false);
        }
    }

    function _getQuoteAtTick(int24 tick, uint128 baseAmount, address baseToken, address quoteToken)
        internal
        pure
        returns (uint256 quoteAmount)
    {
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * uint256(sqrtRatioX96);
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }

    function _toDecimals(uint256 _value, uint8 _from, uint8 _to) internal pure returns (uint256) {
        if (_from == _to) return _value;
        if (_from > _to) return _value / (10 ** (_from - _to));
        return _value * (10 ** (_to - _from));
    }

}
