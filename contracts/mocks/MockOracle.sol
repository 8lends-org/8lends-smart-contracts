// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./interfaces/IOracle.sol";

/// @notice Mock Oracle for tests: set price per token, getPrice returns it.
contract MockOracle {
    uint8 public constant priceDecimals = 8;
    mapping(address => uint256) public prices;

    function setPrice(address _token, uint256 _price) external {
        prices[_token] = _price;
    }

    function getPrice(address _token) external view returns (IOracle.PriceResult memory result) {
        result.price = prices[_token];
        result.priceSource = IOracle.PriceSource.ChainLink;
        result.pythPrice = 0;
        result.chainLinkPrice = prices[_token];
        result.uniswapPrice = 0;
        result.pythUpdatedAt = 0;
        result.chainLinkUpdatedAt = block.timestamp;
    }
}
