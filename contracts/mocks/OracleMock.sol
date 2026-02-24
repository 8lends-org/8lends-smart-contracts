// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IOracle} from "./interfaces/IOracle.sol";

contract OracleMock is IOracle {
    uint256 public price;
    uint8 public priceDecimals = 18;

    function setPrice(uint256 newPrice) external {
        price = newPrice;
    }

    function getPrice(address) external view returns (PriceResult memory result) {
        result.pythPrice = price;
        result.chainLinkPrice = price;
        result.uniswapPrice = price;
        result.price = price;
        result.priceSource = PriceSource.Pyth;
        result.pythUpdatedAt = block.timestamp;
        result.chainLinkUpdatedAt = block.timestamp;
    }

}
