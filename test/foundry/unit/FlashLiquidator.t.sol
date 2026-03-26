// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../../../contracts/lending/FlashLiquidator.sol";
import "../../../contracts/lending/interfaces/ILending8.sol";
import "../../../contracts/lending/interfaces/ILending8Callbacks.sol";
import "../../../contracts/lending/lib/MarketParamsLib.sol";
import "../../../contracts/lending/lib/SharesMathLib.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Simple ERC20 mock that avoids OZ IERC20 collision with lending's IERC20
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

/// @notice Mock Lending8 that simulates flash loan + liquidation
contract MockLending8 {
    using MarketParamsLib for MarketParams;

    uint128 public totalBorrowAssets = 100_000e6;
    uint128 public totalBorrowShares = 100_000e6;

    bool public accrueInterestCalled;
    bool public liquidateCalled;
    address public lastLiquidatedBorrower;
    uint256 public lastRepaidShares;

    bool public flashLoanShouldFail;

    function setFlashLoanShouldFail(bool _fail) external {
        flashLoanShouldFail = _fail;
    }

    function setMarketState(uint128 _totalBorrowAssets, uint128 _totalBorrowShares) external {
        totalBorrowAssets = _totalBorrowAssets;
        totalBorrowShares = _totalBorrowShares;
    }

    function accrueInterest(MarketParams memory) external {
        accrueInterestCalled = true;
    }

    function market(Id) external view returns (Market memory) {
        return Market({
            totalSupplyAssets: 1_000_000e6,
            totalSupplyShares: 1_000_000e6,
            totalBorrowAssets: totalBorrowAssets,
            totalBorrowShares: totalBorrowShares,
            lastUpdate: uint128(block.timestamp),
            fee: 0
        });
    }

    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        require(!flashLoanShouldFail, "MockLending8: flash loan failed");

        // Transfer tokens to caller (flash loan)
        MockLoanToken(token).transfer(msg.sender, assets);

        // Call the callback
        ILending8FlashLoanCallback(msg.sender).onLending8FlashLoan(assets, data);

        // Pull tokens back (repayment)
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
        return (0, 0);
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

        // Deploy mocks
        loanToken = new MockLoanToken();
        collateralToken = new MockLoanToken();
        mockLending8 = new MockLending8();

        // Deploy FlashLiquidator (UUPS proxy)
        {
            FlashLiquidator impl = new FlashLiquidator();
            bytes memory initData = abi.encodeCall(
                FlashLiquidator.initialize,
                (ILending8(address(mockLending8)), ownerAddr)
            );
            ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
            flashLiquidator = FlashLiquidator(address(proxy));
        }

        // Seed mock lending with loan tokens for flash loans
        loanToken.mint(address(mockLending8), 1_000_000e6);

        // Setup market params
        testMarketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            irm: address(0),
            lltv: 800_000_000_000_000_000 // 80%
        });

        vm.stopPrank();
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

    function test_initialize_revert_doubleInit() public {
        vm.expectRevert();
        flashLiquidator.initialize(ILending8(address(mockLending8)), ownerAddr);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    flashLiquidate
    // ═══════════════════════════════════════════════════════════════

    function test_flashLiquidate_success() public {
        uint256 repaidShares = 10_000e6;

        flashLiquidator.flashLiquidate(testMarketParams, borrowerAddr, repaidShares);

        assertTrue(mockLending8.accrueInterestCalled());
        assertTrue(mockLending8.liquidateCalled());
        assertEq(mockLending8.lastLiquidatedBorrower(), borrowerAddr);
        assertEq(mockLending8.lastRepaidShares(), repaidShares);
    }

    function test_flashLiquidate_revert_zeroShares() public {
        vm.expectRevert("zero repaidShares");
        flashLiquidator.flashLiquidate(testMarketParams, borrowerAddr, 0);
    }

    function test_flashLiquidate_anyoneCanCall() public {
        vm.prank(attackerAddr);
        flashLiquidator.flashLiquidate(testMarketParams, borrowerAddr, 1_000e6);
        assertTrue(mockLending8.liquidateCalled());
    }

    function test_flashLiquidate_revert_flashLoanFails() public {
        mockLending8.setFlashLoanShouldFail(true);
        vm.expectRevert("MockLending8: flash loan failed");
        flashLiquidator.flashLiquidate(testMarketParams, borrowerAddr, 1_000e6);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    testFlashLoan
    // ═══════════════════════════════════════════════════════════════

    function test_testFlashLoan_success() public {
        vm.prank(ownerAddr);
        flashLiquidator.testFlashLoan(address(loanToken), 1_000e6);
    }

    function test_testFlashLoan_revert_notOwner() public {
        vm.prank(attackerAddr);
        vm.expectRevert();
        flashLiquidator.testFlashLoan(address(loanToken), 1_000e6);
    }

    function test_testFlashLoan_revert_zeroAmount() public {
        vm.prank(ownerAddr);
        vm.expectRevert("zero amount");
        flashLiquidator.testFlashLoan(address(loanToken), 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    onLending8FlashLoan CALLBACK
    // ═══════════════════════════════════════════════════════════════

    function test_callback_revert_notLending8() public {
        bytes memory data = abi.encode(testMarketParams, borrowerAddr, uint256(100));

        vm.prank(attackerAddr);
        vm.expectRevert("only Lending8");
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
