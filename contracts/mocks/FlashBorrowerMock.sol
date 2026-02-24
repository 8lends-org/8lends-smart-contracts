// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IERC20} from "./interfaces/IERC20.sol";
import {ILending8} from "./interfaces/ILending8.sol";
import {ILending8FlashLoanCallback} from "./interfaces/ILending8Callbacks.sol";

contract FlashBorrowerMock is ILending8FlashLoanCallback {
    ILending8 private immutable LENDING8;

    constructor(ILending8 newLending8) {
        LENDING8 = newLending8;
    }

    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        LENDING8.flashLoan(token, assets, data);
    }

    function onLending8FlashLoan(uint256 assets, bytes calldata data) external {
        require(msg.sender == address(LENDING8));
        address token = abi.decode(data, (address));
        IERC20(token).approve(address(LENDING8), assets);
    }
}
