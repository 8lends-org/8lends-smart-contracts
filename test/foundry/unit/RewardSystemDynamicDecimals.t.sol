// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {RewardSystem} from "../../../contracts/reward-system/RewardSystem.sol";
import {ManagerRegistry} from "../../../contracts/manager-registry/ManagerRegistry.sol";
import {Token} from "../../../contracts/8lnds/Token.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../mocks/MockUSDC.sol";
import "../mocks/MockUSDC18.sol";
import "../mocks/MockUniswapV2Router.sol";

contract RewardSystemDynamicDecimalsTest is Test {
    function test_initialize_dynamicDecimals_6() public {
        address owner = makeAddr("owner");
        vm.startPrank(owner);

        MockUSDC usdc6 = new MockUSDC();
        Token token = new Token();
        ManagerRegistry mgrImpl = new ManagerRegistry();
        ERC1967Proxy mgrProxy = new ERC1967Proxy(
            address(mgrImpl),
            abi.encodeCall(ManagerRegistry.initialize, ())
        );
        MockUniswapV2Router router = new MockUniswapV2Router(address(token), address(usdc6));

        RewardSystem impl = new RewardSystem();
        bytes memory initData = abi.encodeCall(
            RewardSystem.initialize,
            (address(mgrProxy), address(token), address(usdc6), address(router))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        RewardSystem rs = RewardSystem(address(proxy));

        assertEq(rs.welcomeBonusAmount(), 30e6, "welcomeBonusAmount should be 30 * 10^6");
        assertEq(rs.minInvestmentForBonus(), 1000e6, "minInvestmentForBonus should be 1000 * 10^6");

        vm.stopPrank();
    }

    function test_initialize_dynamicDecimals_18() public {
        address owner = makeAddr("owner");
        vm.startPrank(owner);

        MockUSDC18 usdc18 = new MockUSDC18();
        Token token = new Token();
        ManagerRegistry mgrImpl = new ManagerRegistry();
        ERC1967Proxy mgrProxy = new ERC1967Proxy(
            address(mgrImpl),
            abi.encodeCall(ManagerRegistry.initialize, ())
        );
        MockUniswapV2Router router = new MockUniswapV2Router(address(token), address(usdc18));

        RewardSystem impl = new RewardSystem();
        bytes memory initData = abi.encodeCall(
            RewardSystem.initialize,
            (address(mgrProxy), address(token), address(usdc18), address(router))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        RewardSystem rs = RewardSystem(address(proxy));

        assertEq(rs.welcomeBonusAmount(), 30e18, "welcomeBonusAmount should be 30 * 10^18");
        assertEq(rs.minInvestmentForBonus(), 1000e18, "minInvestmentForBonus should be 1000 * 10^18");

        vm.stopPrank();
    }
}
