// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../Setup.sol";

contract FundraiseUpgradeTest is Setup {
    // =========================================================================
    // test_UUPS_UpgradePreservesState_Full
    // =========================================================================

    function test_UUPS_UpgradePreservesState_Full() public {
        // 1. Setup state
        uint256 pid = _createProject(100e6, 1_000_000e6);
        _investAs(investor, pid, 300e6, inviter);
        _investAs(investor2, pid, 200e6, inviter);

        vm.prank(owner);
        fundraise.setAmlGateway(makeAddr("dummy-gateway"));

        // Snapshot state BEFORE upgrade — split into smaller scopes to avoid stack-too-deep
        uint256 invested1Before;
        uint256 invested2Before;
        address gatewayBefore;
        uint256 nonceBefore;
        uint256 positionCountBefore;

        {
            (uint256 a,) = fundraise.investorInfo(investor, pid);
            (uint256 b,) = fundraise.investorInfo(investor2, pid);
            invested1Before = a;
            invested2Before = b;
            gatewayBefore = fundraise.amlGateway();
            nonceBefore = fundraise.userNonces(investor);
            positionCountBefore = fundraise.getPositionCount(investor, pid);
        }

        address ownerBefore = fundraise.owner();
        address rewardSystemBefore = fundraise.rewardSystem();

        // 2. Deploy new impl + upgrade
        Fundraise newImpl = new Fundraise();
        vm.prank(owner);
        fundraise.upgradeToAndCall(address(newImpl), "");

        // 3. Verify state preserved
        {
            (uint256 invested1After,) = fundraise.investorInfo(investor, pid);
            (uint256 invested2After,) = fundraise.investorInfo(investor2, pid);
            assertEq(invested1After, invested1Before, "investor1 investedAmount must be preserved");
            assertEq(invested2After, invested2Before, "investor2 investedAmount must be preserved");
        }

        assertEq(fundraise.amlGateway(), gatewayBefore, "amlGateway must be preserved");
        assertEq(fundraise.userNonces(investor), nonceBefore, "userNonce must be preserved");
        assertEq(fundraise.getPositionCount(investor, pid), positionCountBefore, "positionCount must be preserved");
        assertEq(fundraise.owner(), ownerBefore, "owner must be preserved");
        assertEq(fundraise.rewardSystem(), rewardSystemBefore, "rewardSystem must be preserved");
    }

    // =========================================================================
    // test_UUPS_NonOwner_Reverts
    // =========================================================================

    function test_UUPS_NonOwner_Reverts() public {
        Fundraise newImpl = new Fundraise();

        vm.prank(attacker);
        vm.expectRevert();
        fundraise.upgradeToAndCall(address(newImpl), "");
    }

    // =========================================================================
    // test_UUPS_AmlGatewayPreserved
    // =========================================================================

    function test_UUPS_AmlGatewayPreserved() public {
        address dummyGateway = makeAddr("aml-gateway-preserved");

        vm.prank(owner);
        fundraise.setAmlGateway(dummyGateway);

        assertEq(fundraise.amlGateway(), dummyGateway, "amlGateway should be set before upgrade");

        Fundraise newImpl = new Fundraise();
        vm.prank(owner);
        fundraise.upgradeToAndCall(address(newImpl), "");

        assertEq(fundraise.amlGateway(), dummyGateway, "amlGateway must equal previously-set value after upgrade");
    }

    // =========================================================================
    // test_UUPS_EmptyData
    // =========================================================================

    function test_UUPS_EmptyData() public {
        Fundraise newImpl = new Fundraise();

        vm.prank(owner);
        // passing "" as data — upgrade succeeds with no extra init call
        fundraise.upgradeToAndCall(address(newImpl), "");

        // Contract still works correctly after upgrade with empty data
        assertEq(fundraise.owner(), owner, "owner should still be correct after empty-data upgrade");
    }
}
