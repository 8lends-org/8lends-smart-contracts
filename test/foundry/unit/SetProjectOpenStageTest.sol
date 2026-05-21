// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../Setup.sol";

contract SetProjectOpenStageTest is Setup {

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-059: setProject: decrease openStageEndAt → NOT applied
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP059_setProject_decreaseOpenStageEndAt_notApplied() public {
        // GAP-059: setProject: decrease openStageEndAt → NOT applied (stays same)
        uint256 pid = _createProject(100e6, 10_000e6);

        // Move to Open stage by investing
        _investAs(investor, pid, 1e6, inviter);

        (,,, uint256 startAt,,,uint256 openStageEndAtBefore,) = fundraise.projects(pid);

        // Try to decrease openStageEndAt
        Fundraise.Project memory proj;
        proj.openStageEndAt = openStageEndAtBefore - 1 days;
        // Other fields don't matter for Open stage update (only openStageEndAt, rates checked)
        (,,,,,uint256 investorRate,,) = fundraise.projects(pid);
        proj.investorInterestRate = investorRate;
        (uint256 platformRate,,,,,,) = _getInnerStruct(pid);
        proj.innerStruct.platformInterestRate = platformRate;

        vm.prank(manager);
        fundraise.setProject(pid, proj);

        (,,,,,, uint256 openStageEndAtAfter,) = fundraise.projects(pid);
        assertEq(openStageEndAtAfter, openStageEndAtBefore, "openStageEndAt should not decrease");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-060: setProject: equal openStageEndAt → NOT applied
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP060_setProject_equalOpenStageEndAt_notApplied() public {
        // GAP-060: setProject: equal openStageEndAt → NOT applied
        uint256 pid = _createProject(100e6, 10_000e6);
        _investAs(investor, pid, 1e6, inviter);

        (,,,,,, uint256 openStageEndAtBefore,) = fundraise.projects(pid);

        Fundraise.Project memory proj;
        proj.openStageEndAt = openStageEndAtBefore; // same value
        (,,,,,uint256 investorRate,,) = fundraise.projects(pid);
        proj.investorInterestRate = investorRate;
        (uint256 platformRate,,,,,,) = _getInnerStruct(pid);
        proj.innerStruct.platformInterestRate = platformRate;

        vm.prank(manager);
        fundraise.setProject(pid, proj);

        (,,,,,, uint256 openStageEndAtAfter,) = fundraise.projects(pid);
        assertEq(openStageEndAtAfter, openStageEndAtBefore, "openStageEndAt should not change when equal");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-061: setProject: increase by exactly 30 days → succeed
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP061_setProject_increaseBy30Days_succeeds() public {
        // GAP-061: setProject: increase by exactly 30 days → succeed
        uint256 pid = _createProject(100e6, 10_000e6);
        _investAs(investor, pid, 1e6, inviter);

        (,,,,,, uint256 openStageEndAtBefore,) = fundraise.projects(pid);

        Fundraise.Project memory proj;
        proj.openStageEndAt = openStageEndAtBefore + 30 days;
        (,,,,,uint256 investorRate,,) = fundraise.projects(pid);
        proj.investorInterestRate = investorRate;
        (uint256 platformRate,,,,,,) = _getInnerStruct(pid);
        proj.innerStruct.platformInterestRate = platformRate;

        vm.prank(manager);
        fundraise.setProject(pid, proj);

        (,,,,,, uint256 openStageEndAtAfter,) = fundraise.projects(pid);
        assertEq(openStageEndAtAfter, openStageEndAtBefore + 30 days, "should be extended by 30 days");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-062: setProject: increase by 30 days + 1 → revert
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP062_setProject_increaseBy30DaysPlus1_reverts() public {
        // GAP-062: setProject: increase by 30 days + 1 → revert OpenStageExtensionTooLong
        uint256 pid = _createProject(100e6, 10_000e6);
        _investAs(investor, pid, 1e6, inviter);

        (,,,,,, uint256 openStageEndAtBefore,) = fundraise.projects(pid);

        Fundraise.Project memory proj;
        proj.openStageEndAt = openStageEndAtBefore + 30 days + 1;
        (,,,,,uint256 investorRate,,) = fundraise.projects(pid);
        proj.investorInterestRate = investorRate;
        (uint256 platformRate,,,,,,) = _getInnerStruct(pid);
        proj.innerStruct.platformInterestRate = platformRate;

        vm.prank(manager);
        vm.expectRevert(Fundraise.OpenStageExtensionTooLong.selector);
        fundraise.setProject(pid, proj);
    }

    // ── Helper to read InnerProjectStruct ──

    function _getInnerStruct(uint256 pid) internal view returns (
        uint256 platformInterestRate,
        uint256 totalRepaid,
        address borrowerAddr,
        uint256 fundedTime,
        IERC20 loanToken,
        Fundraise.Stage stage,
        uint256 dummy
    ) {
        Fundraise.Project memory p = _readProject(pid);
        return (
            p.innerStruct.platformInterestRate,
            p.innerStruct.totalRepaid,
            p.innerStruct.borrower,
            p.innerStruct.fundedTime,
            p.innerStruct.loanToken,
            p.innerStruct.stage,
            0
        );
    }

    function _readProject(uint256 pid) internal view returns (Fundraise.Project memory p) {
        (
            uint256 hardCap,
            uint256 softCap,
            uint256 totalInvested,
            uint256 startAt,
            uint256 preFundDuration,
            uint256 investorInterestRate,
            uint256 openStageEndAt,
            Fundraise.InnerProjectStruct memory inner
        ) = fundraise.projects(pid);
        p.hardCap = hardCap;
        p.softCap = softCap;
        p.totalInvested = totalInvested;
        p.startAt = startAt;
        p.preFundDuration = preFundDuration;
        p.investorInterestRate = investorInterestRate;
        p.openStageEndAt = openStageEndAt;
        p.innerStruct = inner;
    }
}
