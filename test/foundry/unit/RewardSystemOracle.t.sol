// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";
import {MockOracle} from "../../../contracts/mocks/MockOracle.sol";

contract RewardSystemOracleTest is Setup {
    uint256 pid;

    function setUp() public override {
        super.setUp();
        pid = _createProject(20_000e6, 40_000e6);
    }

    // ═══════════════════════════════════════════════════════════════
    //                  Oracle price integration
    // ═══════════════════════════════════════════════════════════════

    function test_recordInvestment_usesOraclePrice() public {
        _investAs(investor, pid, 25_000e6, inviter);

        // tokenPercentage = 6% -> 1500 USDC worth of tokens
        // Oracle price = 1e6 (0.01 USD in 8 decimals)
        // tokensAmount = 1500e6 * 1e8 * 1e18 / (1e6 * 1e6) = 150_000e18
        (,uint256 totalTokens,,,) = rewardSystem.getProjectRewards(investor, pid);
        assertEq(totalTokens, 150_000e18, "Token reward amount from oracle incorrect");
    }

    function test_recordInvestment_revertsWhenOraclePriceZero() public {
        // Set oracle to one that returns price=0
        MockOracle zeroOracle = new MockOracle();
        vm.prank(owner);
        rewardSystem.setOracle(address(zeroOracle));

        // Prepare invest manually (can't use _investAs with expectRevert)
        vm.prank(owner);
        usdc.mint(investor, 25_000e6);
        vm.prank(investor);
        usdc.approve(address(fundraise), 25_000e6);

        uint256 currentNonce = fundraise.nonce();
        bytes32 rootHash = keccak256(abi.encodePacked("test-root"));
        bytes memory sig = _signInvest(investor, pid, 25_000e6, rootHash, currentNonce + 1, inviter);

        vm.prank(investor);
        vm.expectRevert("Oracle: no valid price");
        fundraise.investUpdate(pid, 25_000e6, rootHash, currentNonce + 1, sig, inviter);
    }

    function test_recordInvestment_revertsWhenOracleNotSet() public {
        // Deploy a fresh RewardSystem without oracle set
        vm.startPrank(owner);
        RewardSystem impl = new RewardSystem();
        bytes memory initData = abi.encodeCall(
            RewardSystem.initialize,
            (address(managerRegistry), address(token), address(usdc), address(mockRouter))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        RewardSystem freshRS = RewardSystem(address(proxy));

        // Point both managerRegistry AND fundraise to fresh RS
        managerRegistry.setContractAddresses(
            address(freshRS),
            address(fundraise),
            address(treasury)
        );
        fundraise.setRewardSystem(address(freshRS));
        vm.stopPrank();

        // Prepare invest manually
        vm.prank(owner);
        usdc.mint(investor, 25_000e6);
        vm.prank(investor);
        usdc.approve(address(fundraise), 25_000e6);

        uint256 currentNonce = fundraise.nonce();
        bytes32 rootHash = keccak256(abi.encodePacked("test-root"));
        bytes memory sig = _signInvest(investor, pid, 25_000e6, rootHash, currentNonce + 1, inviter);

        vm.prank(investor);
        vm.expectRevert("Oracle not set");
        fundraise.investUpdate(pid, 25_000e6, rootHash, currentNonce + 1, sig, inviter);

        // Restore original reward system
        vm.startPrank(owner);
        managerRegistry.setContractAddresses(
            address(rewardSystem),
            address(fundraise),
            address(treasury)
        );
        fundraise.setRewardSystem(address(rewardSystem));
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //                  setOracle
    // ═══════════════════════════════════════════════════════════════

    function test_setOracle_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("Invalid address");
        rewardSystem.setOracle(address(0));
    }

    function test_setOracle_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        rewardSystem.setOracle(address(mockOracle));
    }

    function test_setOracle_updatesOracleAddress() public {
        MockOracle newOracle = new MockOracle();

        vm.prank(owner);
        rewardSystem.setOracle(address(newOracle));

        assertEq(rewardSystem.oracle(), address(newOracle), "Oracle address not updated");
    }

    function test_setOracle_emitsEvent() public {
        MockOracle newOracle = new MockOracle();

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit RewardSystem.OracleUpdated(address(newOracle));
        rewardSystem.setOracle(address(newOracle));
    }
}
