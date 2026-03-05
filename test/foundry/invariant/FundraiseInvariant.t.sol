// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";
import "./handlers/FundraiseHandler.sol";

/// @notice Invariant tests for Fundraise contract
/// @dev Verifies protocol-wide properties hold under random action sequences:
///      1. No over-claim: sum of all claims <= totalRepaid
///      2. USDC conservation: all USDC is accounted for
///      3. Investment consistency: totalInvested == sum of individual amounts
contract FundraiseInvariantTest is Setup {
    FundraiseHandler handler;
    uint256 pid;

    function setUp() public override {
        super.setUp();

        pid = _createProject(5_000e6, 50_000e6);

        address[] memory investorList = new address[](3);
        investorList[0] = investor;
        investorList[1] = investor2;
        investorList[2] = makeAddr("investor3");

        handler = new FundraiseHandler(
            fundraise,
            usdc,
            managerRegistry,
            backendPk,
            owner,
            manager,
            borrower,
            investorList,
            pid
        );

        targetContract(address(handler));
    }

    /// @notice Sum of all claims never exceeds total repaid
    function invariant_noOverClaim() public view {
        if (handler.ghost_totalRepaid() == 0) return;
        assertLe(
            handler.ghost_totalClaimed(),
            handler.ghost_totalRepaid(),
            "INVARIANT VIOLATED: total claimed > total repaid"
        );
    }

    /// @notice USDC balance of Fundraise contract is consistent with ghost accounting
    /// @dev Balance = totalInvested - platformFee - borrowerReceived + totalRepaid - totalClaimed
    function invariant_usdcConservation() public view {
        uint256 expectedBalance;
        if (handler.ghost_isFunded()) {
            // After funding: USDC left = totalRepaid - totalClaimed
            // (invested USDC went to borrower + treasury)
            expectedBalance = handler.ghost_totalRepaid() - handler.ghost_totalClaimed();
        } else {
            // Before funding: all invested USDC is in the contract
            expectedBalance = handler.ghost_totalInvested();
        }

        uint256 actualBalance = usdc.balanceOf(address(fundraise));
        assertEq(actualBalance, expectedBalance, "INVARIANT VIOLATED: USDC balance mismatch");
    }

    /// @notice totalInvested in project matches ghost tracking
    function invariant_investmentAccounting() public view {
        (,, uint256 contractTotalInvested,,,,,) = fundraise.projects(pid);
        assertEq(
            contractTotalInvested,
            handler.ghost_totalInvested(),
            "INVARIANT VIOLATED: investment accounting mismatch"
        );
    }

    /// @notice Log call distribution for debugging
    function invariant_callSummary() public view {
        // This invariant always passes — it's here for logging
        // Run with -vvv to see call counts in output
    }
}
