// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";

/// @notice Fuzz tests for Token canTransfer modifier
contract TokenTransferFuzzTest is Setup {
    /// @notice Transfer to random non-pool/non-rewardSystem address reverts when buying disabled
    function testFuzz_transfer_blockedToRandomAddress(address recipient) public {
        // Exclude allowed addresses
        vm.assume(recipient != address(0));
        vm.assume(!managerRegistry.isPool(recipient));
        vm.assume(!managerRegistry.isRewardSystem(recipient));
        vm.assume(recipient != address(token)); // can't transfer to self

        vm.prank(owner);
        token.mint(investor, 1_000e18);

        vm.prank(investor);
        vm.expectRevert("Token: Buying is disabled");
        token.transfer(recipient, 100e18);
    }

    /// @notice Transfer to pool always succeeds when buying disabled
    function testFuzz_transfer_allowedToPool(uint256 amount) public {
        amount = bound(amount, 1, 10_000e18);

        address pool = makeAddr("fuzzPool");
        vm.prank(owner);
        managerRegistry.setPoolStatus(pool, true);

        vm.prank(owner);
        token.mint(investor, amount);

        vm.prank(investor);
        token.transfer(pool, amount);

        assertEq(token.balanceOf(pool), amount);
    }

    /// @notice Transfer to rewardSystem always succeeds when buying disabled
    function testFuzz_transfer_allowedToRewardSystem(uint256 amount) public {
        amount = bound(amount, 1, 10_000e18);

        vm.prank(owner);
        token.mint(investor, amount);

        vm.prank(investor);
        token.transfer(address(rewardSystem), amount);

        assertEq(token.balanceOf(address(rewardSystem)), amount);
    }

    /// @notice Transfer to any address succeeds when buying enabled
    function testFuzz_transfer_allowedWhenBuyingEnabled(address recipient, uint256 amount) public {
        vm.assume(recipient != address(0));
        amount = bound(amount, 1, 10_000e18);

        vm.prank(owner);
        token.enableBuying();

        vm.prank(owner);
        token.mint(investor, amount);

        uint256 balBefore = token.balanceOf(recipient);
        vm.prank(investor);
        token.transfer(recipient, amount);

        // The sender is `investor`, so a self-transfer debits and credits the same account and nets
        // to zero. Kept inside the fuzz domain rather than excluded with vm.assume: "a self-transfer
        // is allowed and does not revert" is part of what this test claims.
        uint256 expectedDelta = recipient == investor ? 0 : amount;
        assertEq(token.balanceOf(recipient) - balBefore, expectedDelta);
    }

    /// @notice Mint to any address always works (mint bypasses canTransfer)
    function testFuzz_mint_alwaysAllowed(address recipient, uint256 amount) public {
        vm.assume(recipient != address(0));
        amount = bound(amount, 1, 10_000e18);

        uint256 balBefore = token.balanceOf(recipient);
        vm.prank(owner);
        token.mint(recipient, amount);

        assertEq(token.balanceOf(recipient) - balBefore, amount);
    }
}
