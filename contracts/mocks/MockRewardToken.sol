// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @notice ERC20 reward token for tests (e.g. 8LNDS with 18 decimals).
contract MockRewardToken is ERC20, Ownable {
    uint8 private _decimals;

    constructor(address initialOwner, string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) Ownable(initialOwner) {
        _decimals = decimals_;
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
