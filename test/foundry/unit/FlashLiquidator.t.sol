// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../../../contracts/lending/FlashLiquidator.sol";
import "../../../contracts/lending/interfaces/ILending8.sol";
import "../../../contracts/lending/interfaces/ILending8Callbacks.sol";
import "../../../contracts/lending/lib/MarketParamsLib.sol";
import "../../../contracts/lending/lib/SharesMathLib.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Simple ERC20 mock that avoids OZ IERC20 collision with lending's IERC20.
contract MockLoanToken {
    string public name = "Mock Loan";
    string public symbol = "MLOAN";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Mock Lending8 that simulates the minimal FlashLiquidator integration surface.
contract MockLending8 {
    using MarketParamsLib for MarketParams;

    uint128 public totalBorrowAssets = 100_000e6;
    uint128 public totalBorrowShares = 100_000e6;

    bool public accrueInterestCalled;
    bool public liquidateCalled;
    address public lastLiquidatedBorrower;
    uint256 public lastRepaidShares;
    MarketParams internal storedMarketParams;

    function setMarketState(uint128 _totalBorrowAssets, uint128 _totalBorrowShares) external {
        totalBorrowAssets = _totalBorrowAssets;
        totalBorrowShares = _totalBorrowShares;
    }

    function setMarketParams(MarketParams memory marketParams) external {
        storedMarketParams = marketParams;
    }

    function accrueInterest(MarketParams memory) external {
        accrueInterestCalled = true;
    }

    function market(Id marketId) external view returns (Market memory) {
        if (Id.unwrap(marketId) != Id.unwrap(MarketParamsLib.id(storedMarketParams))) {
            return Market(0, 0, 0, 0, 0, 0);
        }
        return Market({
            totalSupplyAssets: 1_000_000e6,
            totalSupplyShares: 1_000_000e6,
            totalBorrowAssets: totalBorrowAssets,
            totalBorrowShares: totalBorrowShares,
            lastUpdate: uint128(block.timestamp),
            fee: 0
        });
    }

    function idToMarketParams(Id marketId) external view returns (MarketParams memory) {
        if (Id.unwrap(marketId) != Id.unwrap(MarketParamsLib.id(storedMarketParams))) {
            return MarketParams({ loanToken: address(0), collateralToken: address(0), irm: address(0), lltv: 0 });
        }
        return storedMarketParams;
    }

    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        MockLoanToken(token).transfer(msg.sender, assets);
        ILending8FlashLoanCallback(msg.sender).onLending8FlashLoan(assets, data);
        MockLoanToken(token).transferFrom(msg.sender, address(this), assets);
    }

    function liquidate(
        MarketParams memory,
        address borrower,
        uint256,
        uint256 repaidShares,
        bytes memory
    ) external returns (uint256, uint256) {
        liquidateCalled = true;
        lastLiquidatedBorrower = borrower;
        lastRepaidShares = repaidShares;
        return (0, repaidShares);
    }
}

contract FlashLiquidatorTest is Test {
    FlashLiquidator public flashLiquidator;
    MockLending8 public mockLending8;
    MockLoanToken public loanToken;
    MockLoanToken public collateralToken;

    address public ownerAddr;
    address public attackerAddr;
    address public borrowerAddr;

    MarketParams public testMarketParams;

    function setUp() public {
        ownerAddr = makeAddr("owner");
        attackerAddr = makeAddr("attacker");
        borrowerAddr = makeAddr("borrower");

        vm.startPrank(ownerAddr);
        loanToken = new MockLoanToken();
        collateralToken = new MockLoanToken();
        mockLending8 = new MockLending8();
        testMarketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            irm: address(0),
            lltv: 800_000_000_000_000_000
        });
        mockLending8.setMarketParams(testMarketParams);
        FlashLiquidator impl = new FlashLiquidator();
        bytes memory initData = abi.encodeCall(
            FlashLiquidator.initialize,
            (ILending8(address(mockLending8)), ownerAddr, address(0))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        flashLiquidator = FlashLiquidator(address(proxy));
        vm.stopPrank();
    }

    function _marketId() internal view returns (Id) {
        return MarketParamsLib.id(testMarketParams);
    }

    function _seedLiquidator(uint256 amount) internal {
        loanToken.mint(address(flashLiquidator), amount);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    INITIALIZATION
    // ═══════════════════════════════════════════════════════════════

    function test_initialize_setsLending8() public view {
        assertEq(address(flashLiquidator.LENDING8()), address(mockLending8));
    }

    function test_initialize_setsOwner() public view {
        assertEq(flashLiquidator.owner(), ownerAddr);
    }

    function test_initialize_setsRouter() public view {
        assertEq(flashLiquidator.uniswapV2Router(), address(0));
    }

    function test_initialize_revert_doubleInit() public {
        vm.expectRevert();
        flashLiquidator.initialize(ILending8(address(mockLending8)), ownerAddr, address(0));
    }

    // ═══════════════════════════════════════════════════════════════
    //                    liquidate
    // ═══════════════════════════════════════════════════════════════

    function test_liquidate_success_withoutFlashLoan() public {
        uint256 repaidAssets = 10_000e6;
        _seedLiquidator(repaidAssets);
        flashLiquidator.liquidate(_marketId(), borrowerAddr, repaidAssets);
        assertTrue(mockLending8.accrueInterestCalled());
        assertTrue(mockLending8.liquidateCalled());
        assertEq(mockLending8.lastLiquidatedBorrower(), borrowerAddr);
        uint256 expectedRepaidShares = SharesMathLib.toSharesDown(repaidAssets, 100_000e6, 100_000e6);
        assertEq(mockLending8.lastRepaidShares(), expectedRepaidShares);
    }

    function test_liquidate_revert_zeroRepaidAssets() public {
        vm.expectRevert("FlashLiq: zero repaidAssets");
        flashLiquidator.liquidate(_marketId(), borrowerAddr, 0);
    }

    function test_liquidate_anyoneCanCall() public {
        uint256 repaidAssets = 1_000e6;
        _seedLiquidator(repaidAssets);
        vm.prank(attackerAddr);
        flashLiquidator.liquidate(_marketId(), borrowerAddr, repaidAssets);
        assertTrue(mockLending8.liquidateCalled());
    }

    function test_liquidate_revert_insufficientLoanBalance() public {
        vm.expectRevert("FlashLiq: insufficient loan balance");
        flashLiquidator.liquidate(_marketId(), borrowerAddr, 1_000e6);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    ADMIN
    // ═══════════════════════════════════════════════════════════════

    function test_setUniswapV2Router_success() public {
        address router = makeAddr("router");
        vm.prank(ownerAddr);
        flashLiquidator.setUniswapV2Router(router);
        assertEq(flashLiquidator.uniswapV2Router(), router);
    }

    function test_setUniswapV2Router_revert_notOwner() public {
        vm.prank(attackerAddr);
        vm.expectRevert();
        flashLiquidator.setUniswapV2Router(makeAddr("router"));
    }

    function test_withdraw_success() public {
        uint256 amount = 1_000e6;
        _seedLiquidator(amount);
        vm.prank(ownerAddr);
        flashLiquidator.withdraw(address(loanToken), ownerAddr, amount);
        assertEq(loanToken.balanceOf(ownerAddr), amount);
    }

    function test_withdraw_revert_zeroTo() public {
        vm.prank(ownerAddr);
        vm.expectRevert("FlashLiq: zero to");
        flashLiquidator.withdraw(address(loanToken), address(0), 1_000e6);
    }

    function test_withdraw_revert_notOwner() public {
        vm.prank(attackerAddr);
        vm.expectRevert();
        flashLiquidator.withdraw(address(loanToken), attackerAddr, 1_000e6);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    CALLBACK
    // ═══════════════════════════════════════════════════════════════

    function test_callback_revert_notLending8() public {
        bytes memory data = abi.encode(testMarketParams, borrowerAddr, uint256(100));
        vm.prank(attackerAddr);
        vm.expectRevert("FlashLiq: only Lending8");
        flashLiquidator.onLending8FlashLoan(1_000e6, data);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    UPGRADE
    // ═══════════════════════════════════════════════════════════════

    function test_upgrade_revert_notOwner() public {
        FlashLiquidator newImpl = new FlashLiquidator();
        vm.prank(attackerAddr);
        vm.expectRevert();
        flashLiquidator.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgrade_success_owner() public {
        FlashLiquidator newImpl = new FlashLiquidator();
        vm.prank(ownerAddr);
        flashLiquidator.upgradeToAndCall(address(newImpl), "");
    }
}
