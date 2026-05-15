// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";

contract SetterImprovementsTest is Setup {
    function setUp() public override {
        super.setUp();
    }

    // ═══════════════════════════════════════════════════════════════
    //                    FUNDRAISE — EVENTS
    // ═══════════════════════════════════════════════════════════════

    function test_fundraise_setTrustedSigner_emitsEvent() public {
        address newSigner = makeAddr("newSigner");
        vm.expectEmit(false, false, false, true, address(fundraise));
        emit Fundraise.TrustedSignerUpdated(newSigner);
        vm.prank(manager);
        fundraise.setTrustedSigner(newSigner);
    }

    function test_fundraise_setManagerRegistry_emitsEvent() public {
        address newRegistry = makeAddr("newRegistry");
        vm.expectEmit(false, false, false, true, address(fundraise));
        emit Fundraise.ManagerRegistryUpdated(newRegistry);
        vm.prank(owner);
        fundraise.setManagerRegistry(newRegistry);
    }

    function test_fundraise_setTreasury_emitsEvent() public {
        address newTreasury = makeAddr("newTreasury");
        vm.expectEmit(false, false, false, true, address(fundraise));
        emit Fundraise.TreasuryUpdated(newTreasury);
        vm.prank(owner);
        fundraise.setTreasury(newTreasury);
    }

    function test_fundraise_setRewardSystem_emitsEvent() public {
        address newReward = makeAddr("newReward");
        vm.expectEmit(false, false, false, true, address(fundraise));
        emit Fundraise.RewardSystemUpdated(newReward);
        vm.prank(owner);
        fundraise.setRewardSystem(newReward);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    FUNDRAISE — ZERO-ADDRESS CHECKS
    // ═══════════════════════════════════════════════════════════════

    function test_fundraise_setTrustedSigner_revertsOnZeroAddress() public {
        vm.prank(manager);
        vm.expectRevert("Zero address");
        fundraise.setTrustedSigner(address(0));
    }

    function test_fundraise_setManagerRegistry_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("Zero address");
        fundraise.setManagerRegistry(address(0));
    }

    function test_fundraise_setTreasury_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("Zero address");
        fundraise.setTreasury(address(0));
    }

    function test_fundraise_setRewardSystem_allowsZeroAddress() public {
        vm.prank(owner);
        fundraise.setRewardSystem(address(0));
        assertEq(fundraise.rewardSystem(), address(0));
    }

    // ═══════════════════════════════════════════════════════════════
    //                    MANAGER REGISTRY — EVENT + ZERO-ADDRESS
    // ═══════════════════════════════════════════════════════════════

    function test_managerRegistry_setContractAddresses_emitsEvent() public {
        address rs = makeAddr("rs");
        address fr = makeAddr("fr");
        address tr = makeAddr("tr");
        vm.expectEmit(false, false, false, true, address(managerRegistry));
        emit ManagerRegistry.ContractAddressesUpdated(rs, fr, tr);
        vm.prank(owner);
        managerRegistry.setContractAddresses(rs, fr, tr);
    }

    function test_managerRegistry_setContractAddresses_revertsOnZeroRewardSystem() public {
        vm.prank(owner);
        vm.expectRevert("Zero address");
        managerRegistry.setContractAddresses(address(0), makeAddr("fr"), makeAddr("tr"));
    }

    function test_managerRegistry_setContractAddresses_revertsOnZeroFundraise() public {
        vm.prank(owner);
        vm.expectRevert("Zero address");
        managerRegistry.setContractAddresses(makeAddr("rs"), address(0), makeAddr("tr"));
    }

    function test_managerRegistry_setContractAddresses_revertsOnZeroTreasury() public {
        vm.prank(owner);
        vm.expectRevert("Zero address");
        managerRegistry.setContractAddresses(makeAddr("rs"), makeAddr("fr"), address(0));
    }

    // ═══════════════════════════════════════════════════════════════
    //                    REWARD SYSTEM — EVENTS
    // ═══════════════════════════════════════════════════════════════

    function test_rewardSystem_updateContracts_emitsEvent() public {
        address newRegistry = makeAddr("newRegistry");
        address newToken = makeAddr("newToken");
        address newUsdc = makeAddr("newUsdc");
        vm.expectEmit(false, false, false, true, address(rewardSystem));
        emit RewardSystem.ContractsUpdated(newRegistry, newToken, newUsdc);
        vm.prank(owner);
        rewardSystem.updateContracts(newRegistry, newToken, newUsdc);
    }

    function test_rewardSystem_updateUSDCAddress_emitsEvent() public {
        address newUsdc = makeAddr("newUsdc");
        vm.expectEmit(false, false, false, true, address(rewardSystem));
        emit RewardSystem.USDCAddressUpdated(newUsdc);
        vm.prank(owner);
        rewardSystem.updateUSDCAddress(newUsdc);
    }

    function test_rewardSystem_updateTokenAddress_emitsEvent() public {
        address newToken = makeAddr("newToken");
        vm.expectEmit(false, false, false, true, address(rewardSystem));
        emit RewardSystem.TokenAddressUpdated(newToken);
        vm.prank(owner);
        rewardSystem.updateTokenAddress(newToken);
    }

    function test_rewardSystem_updateUniswapRouterAddress_emitsEvent() public {
        address newRouter = makeAddr("newRouter");
        vm.expectEmit(false, false, false, true, address(rewardSystem));
        emit RewardSystem.UniswapRouterUpdated(newRouter);
        vm.prank(owner);
        rewardSystem.updateUniswapRouterAddress(newRouter);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    REWARD SYSTEM — ZERO-ADDRESS CHECKS
    // ═══════════════════════════════════════════════════════════════

    function test_rewardSystem_updateUSDCAddress_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("Zero address");
        rewardSystem.updateUSDCAddress(address(0));
    }

    function test_rewardSystem_updateTokenAddress_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("Zero address");
        rewardSystem.updateTokenAddress(address(0));
    }

    function test_rewardSystem_updateUniswapRouterAddress_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("Zero address");
        rewardSystem.updateUniswapRouterAddress(address(0));
    }

    // ═══════════════════════════════════════════════════════════════
    //                    TOKEN — EVENTS
    // ═══════════════════════════════════════════════════════════════

    function test_token_setManagerRegistry_updatesValue() public {
        address newRegistry = makeAddr("newRegistry");
        vm.prank(owner);
        token.setManagerRegistry(newRegistry);
        assertEq(token.managerRegistry(), newRegistry);
    }

    function test_token_disableMintingForever_disablesMinting() public {
        vm.prank(owner);
        token.disableMintingForever();
        assertFalse(token.mintingEnabled());
    }
}
