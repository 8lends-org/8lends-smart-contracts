// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";

/// @notice Fuzz tests for Fundraise invest boundary conditions
contract FundraiseInvestFuzzTest is Setup {
    // ═══════════════════════════════════════════════════════════════
    //          INVEST AMOUNT vs HARDCAP
    // ═══════════════════════════════════════════════════════════════

    /// @notice Investment within hardCap always succeeds
    function testFuzz_invest_withinHardCap(uint256 amount) public {
        amount = bound(amount, 1e6, 40_000e6); // 1 USDC to 40K

        uint256 pid = _createProject(1_000e6, 40_000e6);
        _investAs(investor, pid, amount, inviter);

        (uint256 invested,) = fundraise.investorInfo(investor, pid);
        assertEq(invested, amount, "Investment recorded correctly");
    }

    /// @notice Investment that exceeds hardCap reverts
    function testFuzz_invest_exceedsHardCap_reverts(uint256 amount) public {
        uint256 hardCap = 10_000e6;
        amount = bound(amount, hardCap + 1, 100_000e6);

        uint256 pid = _createProject(1_000e6, hardCap);

        vm.prank(owner);
        usdc.mint(investor, amount);
        vm.prank(investor);
        usdc.approve(address(fundraise), amount);

        uint256 currentNonce = fundraise.userNonces(investor);
        bytes memory sig = _signInvest(investor, pid, amount, currentNonce + 1, inviter);

        vm.prank(investor);
        vm.expectRevert("Investment exceeds hardcap");
        fundraise.investUpdateV2(pid, amount, currentNonce + 1, sig, inviter);
    }

    /// @notice When investment fills hardCap exactly, project moves to PreFunded
    function testFuzz_invest_exactHardCap_movesToPreFunded(uint256 hardCap) public {
        hardCap = bound(hardCap, 1_000e6, 100_000e6);

        uint256 pid = _createProject(1_000e6, hardCap);
        _investAs(investor, pid, hardCap, inviter);

        (,,,,,,, Fundraise.InnerProjectStruct memory inner) = fundraise.projects(pid);
        assertEq(uint8(inner.stage), uint8(Fundraise.Stage.PreFunded), "Should be PreFunded");
    }

    /// @notice Two investments that sum to hardCap: second triggers PreFunded
    function testFuzz_invest_twoInvestors_fillHardCap(uint256 amount1) public {
        uint256 hardCap = 50_000e6;
        amount1 = bound(amount1, 1_000e6, hardCap - 1_000e6);
        uint256 amount2 = hardCap - amount1;

        uint256 pid = _createProject(1_000e6, hardCap);
        _investAs(investor, pid, amount1, inviter);

        // First invest: still Open
        (,,,,,,, Fundraise.InnerProjectStruct memory inner1) = fundraise.projects(pid);
        assertEq(uint8(inner1.stage), uint8(Fundraise.Stage.Open), "Still Open after first invest");

        _investAs(investor2, pid, amount2, address(0));

        // Second invest fills hardCap → PreFunded
        (,,,,,,, Fundraise.InnerProjectStruct memory inner2) = fundraise.projects(pid);
        assertEq(uint8(inner2.stage), uint8(Fundraise.Stage.PreFunded), "PreFunded after filling hardCap");
    }

    // ═══════════════════════════════════════════════════════════════
    //          INVEST AMOUNT ACCOUNTING
    // ═══════════════════════════════════════════════════════════════

    /// @notice totalInvested always equals sum of individual investments
    function testFuzz_invest_totalInvestedConsistency(uint256 a1, uint256 a2) public {
        a1 = bound(a1, 1_000e6, 20_000e6);
        a2 = bound(a2, 1_000e6, 20_000e6);

        uint256 pid = _createProject(1_000e6, a1 + a2 + 1e6);

        _investAs(investor, pid, a1, inviter);
        _investAs(investor2, pid, a2, address(0));

        (,, uint256 totalInvested,,,,,) = fundraise.projects(pid);
        (uint256 inv1,) = fundraise.investorInfo(investor, pid);
        (uint256 inv2,) = fundraise.investorInfo(investor2, pid);

        assertEq(totalInvested, inv1 + inv2, "totalInvested must equal sum of investments");
        assertEq(totalInvested, a1 + a2, "totalInvested must match input amounts");
    }
}
