// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice A claim pays the exact pro rata share — what came back, times the position, over the
///         pool — and does so down to positions whose share of the pool is under one millionth.
/// @dev The figures in the first test are a reported case: a holder of 121.5 USDC in a 49 002.6
///      pool, against 53 678.281084 repaid.
contract FundraiseClaimPrecisionTest is Setup {
    function setUp() public override {
        super.setUp();
        // These pools are large enough that the reward buyback outruns the mock router's
        // liquidity. It takes no part in what is measured here, so it is switched off rather than
        // worked around — the subject is the claim arithmetic alone.
        vm.startPrank(owner);
        fundraise.setRewardSystem(address(0));
        fundraise.setLimitedSeller(address(0));
        vm.stopPrank();
    }

    function _pool(uint256 mine, uint256 theirs) internal returns (uint256 pid) {
        uint256 total = mine + theirs;
        pid = _createProject(total, total);
        _investAs(investor, pid, mine, address(0));
        _investAs(investor2, pid, theirs, address(0));
        _fundProject(pid);
    }

    function _claim(uint256 pid, address who) internal returns (uint256 received) {
        uint256 before = usdc.balanceOf(who);
        vm.prank(who);
        fundraise.claim(pid, who);
        return usdc.balanceOf(who) - before;
    }

    /// The reported case, to the cent.
    function test_the_reported_position_is_paid_pro_rata() public {
        uint256 mine = 121_500_000;
        uint256 total = 49_002_600_000;
        uint256 repaid = 53_678_281_084;

        uint256 pid = _pool(mine, total - mine);
        _repay(pid, repaid);

        uint256 received = _claim(pid, investor);
        assertEq(received, Math.mulDiv(repaid, mine, total), "pro rata");
        assertEq(received, 133_093_165, "the figure the schedule promised");
    }

    /// The severe end: a share under one millionth of the pool — on five million, anything below
    /// 5 USDC. It is still owed its share, however small.
    function test_a_position_below_one_millionth_is_still_paid() public {
        uint256 mine = 4_900_000; // 4.9 USDC
        uint256 total = 5_000_000_000_000; // 5m USDC
        uint256 repaid = 5_477_088_000_000;

        uint256 pid = _pool(mine, total - mine);
        _repay(pid, repaid);

        uint256 received = _claim(pid, investor);
        assertEq(received, Math.mulDiv(repaid, mine, total), "pro rata");
        assertGt(received, 0, "a share this small is still a share");
    }

    /// The view the interface reads has to agree with what the claim transfers: the arithmetic is
    /// written out in both places, and any difference is a figure shown that is not the figure paid.
    function test_availableToClaim_matches_what_is_paid() public {
        uint256 mine = 104_750_000;
        uint256 total = 5_000_000_000_000;

        uint256 pid = _pool(mine, total - mine);
        _repay(pid, 5_477_088_000_000);

        uint256 quoted = fundraise.availableToClaim(pid, investor);
        assertEq(_claim(pid, investor), quoted, "quoted and paid");
    }

    /// Paying everyone their exact share must not overdraw what the borrower returned. Each share
    /// is floored, so the sum stays under, and what stays behind is rounding rather than a
    /// percentage of the pool.
    function testFuzz_the_pool_is_never_overdrawn(uint256 a, uint256 b, uint256 repaidPct) public {
        a = bound(a, 1e6, 100_000e6);
        b = bound(b, 1e6, 100_000e6);
        repaidPct = bound(repaidPct, 0, 130);

        uint256 pid = _pool(a, b);
        uint256 total = a + b;
        uint256 repaid = (total * repaidPct) / 100;
        if (repaid > 0) _repay(pid, repaid);

        uint256 paid = _claim(pid, investor) + _claim(pid, investor2);
        assertLe(paid, repaid, "never more than came in");
        // Two floors, so at most two units can stay behind.
        assertGe(paid + 2, repaid, "and essentially all of it");
    }
}
