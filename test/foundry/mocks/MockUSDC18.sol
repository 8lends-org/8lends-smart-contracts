// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice 18-decimal ERC20 mock for testing dynamic decimals
contract MockUSDC18 is ERC20 {
    constructor() ERC20("Test USDC 18", "USDC18") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
