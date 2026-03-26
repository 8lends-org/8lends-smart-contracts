// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../../../contracts/limited-seller/LimitedSeller.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ── Minimal mocks ──

contract MockUSDC_LS is ERC20 {
    constructor() ERC20("USDC", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockToken_LS is ERC20 {
    constructor() ERC20("8LND", "8LND") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @notice Mock Fundraise that returns configurable project/investor data
contract MockFundraise_LS {
    using LimitedSellerTypes for *;

    uint256 public _projectCount = 10;
    address public trustedSigner;

    struct MockProject {
        IFundraise.Stage stage;
    }

    struct MockInvestorInfo {
        uint256 investedAmount;
        uint256 totalClaimed;
    }

    mapping(uint256 => MockProject) public mockProjects;
    mapping(address => mapping(uint256 => MockInvestorInfo)) public mockInvestorInfo;

    function setTrustedSigner(address _signer) external {
        trustedSigner = _signer;
    }

    function setProject(uint256 pid, IFundraise.Stage stage) external {
        mockProjects[pid] = MockProject(stage);
    }

    function setInvestorInfo(address investor, uint256 pid, uint256 invested, uint256 claimed) external {
        mockInvestorInfo[investor][pid] = MockInvestorInfo(invested, claimed);
    }

    function projectCount() external view returns (uint256) { return _projectCount; }

    function projects(uint256 pid) external view returns (IFundraise.Project memory) {
        IFundraise.Project memory p;
        p.innerStruct.stage = mockProjects[pid].stage;
        return p;
    }

    function investorInfo(address investor, uint256 pid) external view returns (IFundraise.InvestorInfo memory) {
        MockInvestorInfo memory m = mockInvestorInfo[investor][pid];
        return IFundraise.InvestorInfo(m.investedAmount, m.totalClaimed);
    }
}

/// @dev Namespace to avoid collision with LimitedSeller's IFundraise import
library LimitedSellerTypes {}

/// @notice Mock ManagerRegistry for LimitedSeller
contract MockManagerRegistry_LS {
    mapping(address => bool) public poolStatus;
    mapping(address => address) public claimAddresses;

    function setPoolStatusForReward(address _pool, bool _status) external {
        poolStatus[_pool] = _status;
    }

    function getInvestorClaimAddress(address _investor) external view returns (address) {
        address addr = claimAddresses[_investor];
        return addr != address(0) ? addr : _investor;
    }

    function isPool(address _pool) external view returns (bool) {
        return poolStatus[_pool];
    }

    function setClaimAddress(address investor, address claim) external {
        claimAddresses[investor] = claim;
    }
}

/// @notice Mock Market for secondary investment tracking
contract MockMarket_LS {
    mapping(address => mapping(uint256 => uint256)) public secondaryInvestedAmount;

    function setSecondaryInvestedAmount(address user, uint256 projectId, uint256 amount) external {
        secondaryInvestedAmount[user][projectId] = amount;
    }
}

/// @notice Mock Uniswap V2 router: 1 USDC = 100 tokens
contract MockRouter_LS {
    address public tokenAddr;
    address public usdcAddr;

    constructor(address _token, address _usdc) {
        tokenAddr = _token;
        usdcAddr = _usdc;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 /* amountOutMin */,
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        // 1 USDC (6 dec) = 100 tokens (18 dec)
        amounts[1] = amountIn * 100 * 1e12;

        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        IERC20(path[1]).transfer(to, amounts[1]);
    }
}

contract LimitedSellerTest is Test {
    LimitedSeller public limitedSeller;
    MockUSDC_LS public usdc;
    MockToken_LS public token;
    MockFundraise_LS public mockFundraise;
    MockManagerRegistry_LS public mockRegistry;
    MockRouter_LS public mockRouter;
    MockMarket_LS public mockMarket;

    address public owner;
    address public investor;
    address public investor2;
    address public attacker;

    uint256 public backendPk;
    address public backend;

    uint256 public constant SELLER_PERCENT = 60_000; // 6%
    uint256 public constant PID = 0;

    function setUp() public {
        owner = makeAddr("owner");
        investor = makeAddr("investor");
        investor2 = makeAddr("investor2");
        attacker = makeAddr("attacker");
        (backend, backendPk) = makeAddrAndKey("backend");

        vm.warp(1_700_000_000);
        vm.startPrank(owner);

        // Deploy mocks
        usdc = new MockUSDC_LS();
        token = new MockToken_LS();
        mockFundraise = new MockFundraise_LS();
        mockRegistry = new MockManagerRegistry_LS();
        mockRouter = new MockRouter_LS(address(token), address(usdc));
        mockMarket = new MockMarket_LS();

        // Configure mock fundraise
        mockFundraise.setTrustedSigner(backend);
        mockFundraise.setProject(PID, IFundraise.Stage.Funded);
        mockFundraise.setInvestorInfo(investor, PID, 30_000e6, 0);

        // Deploy LimitedSeller (UUPS proxy)
        {
            LimitedSeller impl = new LimitedSeller();
            bytes memory initData = abi.encodeCall(
                LimitedSeller.initialize,
                (
                    address(mockFundraise),
                    address(mockRouter),
                    address(usdc),
                    address(token),
                    SELLER_PERCENT,
                    address(mockRegistry)
                )
            );
            ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
            limitedSeller = LimitedSeller(address(proxy));
        }

        // Seed mock router with tokens for swaps
        token.mint(address(mockRouter), 10_000_000e18);

        // Set market for secondary investment tracking
        limitedSeller.setMarket(address(mockMarket));

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //                    INITIALIZATION
    // ═══════════════════════════════════════════════════════════════

    function test_initialize_setsParams() public view {
        assertEq(address(limitedSeller.fundraise()), address(mockFundraise));
        assertEq(address(limitedSeller.router()), address(mockRouter));
        assertEq(address(limitedSeller.usdc()), address(usdc));
        assertEq(address(limitedSeller.token()), address(token));
        assertEq(limitedSeller.percent(), SELLER_PERCENT);
        assertEq(address(limitedSeller.managerRegistry()), address(mockRegistry));
    }

    function test_initialize_revert_invalidPercent() public {
        LimitedSeller impl = new LimitedSeller();
        vm.expectRevert();
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                LimitedSeller.initialize,
                (address(mockFundraise), address(mockRouter), address(usdc), address(token), 1e6 + 1, address(mockRegistry))
            )
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //                    estimateAvailableBuy
    // ═══════════════════════════════════════════════════════════════

    function test_estimateAvailableBuy_fundedProject() public view {
        uint256[] memory pids = new uint256[](1);
        pids[0] = PID;

        LimitedSeller.EstimateResult memory result = limitedSeller.estimateAvailableBuy(investor, pids);

        assertEq(result.fundedProjectsInvestedTotal, 30_000e6);
        assertEq(result.alreadyBoughtTokensInUSDC, 0);
        // 30_000e6 * 60_000 / 1_000_000 = 1_800e6
        assertEq(result.availableBuyTokensInUSDC, 1_800e6);
        assertEq(result.percent, SELLER_PERCENT);
    }

    function test_estimateAvailableBuy_revert_emptyProjectIds() public {
        uint256[] memory pids = new uint256[](0);
        vm.expectRevert(LimitedSeller.EmptyProjectIds.selector);
        limitedSeller.estimateAvailableBuy(investor, pids);
    }

    function test_estimateAvailableBuy_nonInvestor() public view {
        uint256[] memory pids = new uint256[](1);
        pids[0] = PID;

        LimitedSeller.EstimateResult memory result = limitedSeller.estimateAvailableBuy(attacker, pids);
        assertEq(result.fundedProjectsInvestedTotal, 0);
        assertEq(result.availableBuyTokensInUSDC, 0);
    }

    function test_estimateAvailableBuy_ignoresNonFundedProjects() public {
        // Add a non-funded project
        vm.prank(owner);
        mockFundraise.setProject(1, IFundraise.Stage.Open);
        vm.prank(owner);
        mockFundraise.setInvestorInfo(investor, 1, 10_000e6, 0);

        uint256[] memory pids = new uint256[](2);
        pids[0] = PID;
        pids[1] = 1;

        LimitedSeller.EstimateResult memory result = limitedSeller.estimateAvailableBuy(investor, pids);
        // Only the funded project counts
        assertEq(result.fundedProjectsInvestedTotal, 30_000e6);
    }

    function test_estimateAvailableBuy_repaidProjectCounts() public {
        vm.prank(owner);
        mockFundraise.setProject(1, IFundraise.Stage.Repaid);
        vm.prank(owner);
        mockFundraise.setInvestorInfo(investor, 1, 10_000e6, 0);

        uint256[] memory pids = new uint256[](2);
        pids[0] = PID;
        pids[1] = 1;

        LimitedSeller.EstimateResult memory result = limitedSeller.estimateAvailableBuy(investor, pids);
        assertEq(result.fundedProjectsInvestedTotal, 40_000e6);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    limitedBuy
    // ═══════════════════════════════════════════════════════════════

    function _signLimitedBuy(address buyer, uint256 nonce) internal view returns (bytes memory sig) {
        bytes32 messageHash = keccak256(abi.encodePacked(buyer, nonce));
        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(backendPk, ethSignedMessageHash);
        sig = abi.encodePacked(r, s, v);
    }

    /// @dev Helper: sign and call limitedBuy for a given buyer (must be pranked already)
    function _limitedBuyWithSig(address buyer, uint256 usdcAmount, uint256[] memory pids) internal {
        uint256 nonce = limitedSeller.buyerNonce(buyer);
        bytes memory sig = _signLimitedBuy(buyer, nonce);
        limitedSeller.limitedBuy(usdcAmount, 0, pids, sig);
    }

    function test_limitedBuy_success() public {
        uint256 buyAmount = 1_000e6;

        vm.prank(owner);
        usdc.mint(investor, buyAmount);

        vm.startPrank(investor);
        usdc.approve(address(limitedSeller), buyAmount);

        uint256[] memory pids = new uint256[](1);
        pids[0] = PID;

        _limitedBuyWithSig(investor, buyAmount, pids);
        vm.stopPrank();

        assertEq(limitedSeller.boughtUsdcByUser(investor), buyAmount);
        assertEq(limitedSeller.totalBoughtInUSDC(), buyAmount);
        assertGt(limitedSeller.totalBoughtInTokens(), 0);
    }

    function test_limitedBuy_revert_exceedsLimit() public {
        uint256 buyAmount = 2_000e6; // exceeds 1_800e6 limit

        vm.prank(owner);
        usdc.mint(investor, buyAmount);

        uint256 nonce = limitedSeller.buyerNonce(investor);
        bytes memory sig = _signLimitedBuy(investor, nonce);

        vm.startPrank(investor);
        usdc.approve(address(limitedSeller), buyAmount);

        uint256[] memory pids = new uint256[](1);
        pids[0] = PID;

        vm.expectRevert(LimitedSeller.ExceedsAvailableLimit.selector);
        limitedSeller.limitedBuy(buyAmount, 0, pids, sig);
        vm.stopPrank();
    }

    function test_limitedBuy_revert_emptyProjectIds() public {
        uint256 nonce = limitedSeller.buyerNonce(investor);
        bytes memory sig = _signLimitedBuy(investor, nonce);

        uint256[] memory pids = new uint256[](0);
        vm.prank(investor);
        vm.expectRevert(LimitedSeller.EmptyProjectIds.selector);
        limitedSeller.limitedBuy(100e6, 0, pids, sig);
    }

    function test_limitedBuy_tracksMultiplePurchases() public {
        uint256[] memory pids = new uint256[](1);
        pids[0] = PID;

        // First buy
        vm.prank(owner);
        usdc.mint(investor, 500e6);
        vm.startPrank(investor);
        usdc.approve(address(limitedSeller), 500e6);
        _limitedBuyWithSig(investor, 500e6, pids);
        vm.stopPrank();

        // Second buy
        vm.prank(owner);
        usdc.mint(investor, 500e6);
        vm.startPrank(investor);
        usdc.approve(address(limitedSeller), 500e6);
        _limitedBuyWithSig(investor, 500e6, pids);
        vm.stopPrank();

        assertEq(limitedSeller.boughtUsdcByUser(investor), 1_000e6);
        assertEq(limitedSeller.totalBoughtInUSDC(), 1_000e6);
    }

    function test_limitedBuy_revert_managerRegistryNotSet() public {
        vm.startPrank(owner);
        LimitedSeller impl = new LimitedSeller();
        bytes memory initData = abi.encodeCall(
            LimitedSeller.initialize,
            (address(mockFundraise), address(mockRouter), address(usdc), address(token), SELLER_PERCENT, address(0))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        LimitedSeller noRegistrySeller = LimitedSeller(address(proxy));
        vm.stopPrank();

        uint256[] memory pids = new uint256[](1);
        pids[0] = PID;

        uint256 nonce = noRegistrySeller.buyerNonce(investor);
        bytes memory sig = _signLimitedBuy(investor, nonce);

        vm.prank(investor);
        vm.expectRevert(LimitedSeller.ManagerRegistryNotSet.selector);
        noRegistrySeller.limitedBuy(100e6, 0, pids, sig);
    }

    function test_limitedBuyWithSignature_success() public {
        uint256 buyAmount = 1_000e6;

        vm.prank(owner);
        usdc.mint(investor, buyAmount);

        uint256 nonce = limitedSeller.buyerNonce(investor);
        bytes memory sig = _signLimitedBuy(investor, nonce);

        vm.startPrank(investor);
        usdc.approve(address(limitedSeller), buyAmount);

        uint256[] memory pids = new uint256[](1);
        pids[0] = PID;

        limitedSeller.limitedBuy(buyAmount, 0, pids, sig);
        vm.stopPrank();

        assertEq(limitedSeller.buyerNonce(investor), nonce + 1);
        assertEq(limitedSeller.boughtUsdcByUser(investor), buyAmount);
    }

    function test_limitedBuyWithSignature_revert_invalidSigner() public {
        uint256 buyAmount = 1_000e6;
        vm.prank(owner);
        usdc.mint(investor, buyAmount);

        (, uint256 wrongPk) = makeAddrAndKey("wrong");
        bytes32 messageHash = keccak256(abi.encodePacked(investor, uint256(0)));
        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPk, ethSignedMessageHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.startPrank(investor);
        usdc.approve(address(limitedSeller), buyAmount);
        uint256[] memory pids = new uint256[](1);
        pids[0] = PID;
        vm.expectRevert("Not trusted signer");
        limitedSeller.limitedBuy(buyAmount, 0, pids, sig);
        vm.stopPrank();
    }

    function test_limitedBuyWithSignature_revert_replayNonce() public {
        uint256 buyAmount = 500e6;
        vm.prank(owner);
        usdc.mint(investor, buyAmount * 2);

        uint256 nonce = limitedSeller.buyerNonce(investor);
        bytes memory sig = _signLimitedBuy(investor, nonce);

        vm.startPrank(investor);
        usdc.approve(address(limitedSeller), buyAmount * 2);
        uint256[] memory pids = new uint256[](1);
        pids[0] = PID;

        limitedSeller.limitedBuy(buyAmount, 0, pids, sig);

        vm.expectRevert("Not trusted signer");
        limitedSeller.limitedBuy(buyAmount, 0, pids, sig);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //                    ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    function test_setPercent_success() public {
        vm.prank(owner);
        limitedSeller.setPercent(100_000);
        assertEq(limitedSeller.percent(), 100_000);
    }

    function test_setPercent_revert_tooHigh() public {
        vm.prank(owner);
        vm.expectRevert(LimitedSeller.InvalidPercent.selector);
        limitedSeller.setPercent(1e6 + 1);
    }

    function test_setPercent_revert_notOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        limitedSeller.setPercent(100_000);
    }

    function test_setManagerRegistry_success() public {
        address newRegistry = makeAddr("newRegistry");
        vm.prank(owner);
        limitedSeller.setManagerRegistry(newRegistry);
        assertEq(address(limitedSeller.managerRegistry()), newRegistry);
    }

    function test_setManagerRegistry_revert_notOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        limitedSeller.setManagerRegistry(makeAddr("newRegistry"));
    }

    // ═══════════════════════════════════════════════════════════════
    //                    UPGRADE
    // ═══════════════════════════════════════════════════════════════

    function test_upgrade_revert_notOwner() public {
        LimitedSeller newImpl = new LimitedSeller();
        vm.prank(attacker);
        vm.expectRevert();
        limitedSeller.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgrade_success() public {
        LimitedSeller newImpl = new LimitedSeller();
        vm.prank(owner);
        limitedSeller.upgradeToAndCall(address(newImpl), "");
    }

    // ═══════════════════════════════════════════════════════════════
    //                    EVENTS
    // ═══════════════════════════════════════════════════════════════

    function test_limitedBuy_emitsBoughtEvent() public {
        uint256 buyAmount = 1_000e6;
        vm.prank(owner);
        usdc.mint(investor, buyAmount);

        vm.startPrank(investor);
        usdc.approve(address(limitedSeller), buyAmount);
        uint256[] memory pids = new uint256[](1);
        pids[0] = PID;

        vm.expectEmit(true, false, false, false);
        emit LimitedSeller.Bought(investor, investor, buyAmount, 0, block.timestamp);
        _limitedBuyWithSig(investor, buyAmount, pids);
        vm.stopPrank();
    }

    function test_setPercent_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit LimitedSeller.PercentSet(100_000);
        limitedSeller.setPercent(100_000);
    }

    // ═══════════════════════════════════════════════════════════════
    //          SECONDARY MARKET — limitedBuy restriction
    // ═══════════════════════════════════════════════════════════════

    /// @notice User bought investment on secondary market → limitedBuy limit = 0
    function test_secondaryMarket_noLimitForSecondaryBuyer() public {
        address buyer = makeAddr("secondaryBuyer");

        // buyer has 100k investedAmount (all from secondary market)
        vm.prank(owner);
        mockFundraise.setInvestorInfo(buyer, PID, 100_000e6, 0);
        mockMarket.setSecondaryInvestedAmount(buyer, PID, 100_000e6);

        uint256[] memory pids = new uint256[](1);
        pids[0] = PID;

        LimitedSeller.EstimateResult memory result = limitedSeller.estimateAvailableBuy(buyer, pids);
        assertEq(result.fundedProjectsInvestedTotal, 0);
        assertEq(result.availableBuyTokensInUSDC, 0);
    }

    /// @notice User has 50k primary + 100k secondary → limit only from 50k primary
    function test_secondaryMarket_limitOnlyFromPrimaryInvestment() public {
        address buyer = makeAddr("mixedBuyer");

        // 150k total: 50k primary + 100k secondary
        vm.prank(owner);
        mockFundraise.setInvestorInfo(buyer, PID, 150_000e6, 0);
        mockMarket.setSecondaryInvestedAmount(buyer, PID, 100_000e6);

        uint256[] memory pids = new uint256[](1);
        pids[0] = PID;

        LimitedSeller.EstimateResult memory result = limitedSeller.estimateAvailableBuy(buyer, pids);
        // primary = 150k - 100k = 50k, limit = 50k * 6% = 3000
        assertEq(result.fundedProjectsInvestedTotal, 50_000e6);
        assertEq(result.availableBuyTokensInUSDC, 3_000e6);
    }

    /// @notice Chain resale A→B→C: C gets no limit
    function test_secondaryMarket_chainResale_noLimit() public {
        address userC = makeAddr("userC");

        // userC bought from userB who bought from userA
        vm.prank(owner);
        mockFundraise.setInvestorInfo(userC, PID, 100_000e6, 0);
        mockMarket.setSecondaryInvestedAmount(userC, PID, 100_000e6);

        uint256[] memory pids = new uint256[](1);
        pids[0] = PID;

        LimitedSeller.EstimateResult memory result = limitedSeller.estimateAvailableBuy(userC, pids);
        assertEq(result.fundedProjectsInvestedTotal, 0);
        assertEq(result.availableBuyTokensInUSDC, 0);
    }

    /// @notice Secondary buyer cannot execute limitedBuy
    function test_secondaryMarket_limitedBuyReverts() public {
        address buyer = makeAddr("secondaryBuyer2");

        vm.prank(owner);
        mockFundraise.setInvestorInfo(buyer, PID, 100_000e6, 0);
        mockMarket.setSecondaryInvestedAmount(buyer, PID, 100_000e6);

        vm.prank(owner);
        usdc.mint(buyer, 1_000e6);

        uint256 nonce = limitedSeller.buyerNonce(buyer);
        bytes memory sig = _signLimitedBuy(buyer, nonce);

        vm.startPrank(buyer);
        usdc.approve(address(limitedSeller), 1_000e6);

        uint256[] memory pids = new uint256[](1);
        pids[0] = PID;

        vm.expectRevert(LimitedSeller.ExceedsAvailableLimit.selector);
        limitedSeller.limitedBuy(1_000e6, 0, pids, sig);
        vm.stopPrank();
    }

    /// @notice Primary investor still works when market is set
    function test_secondaryMarket_primaryInvestorStillWorks() public {
        // investor has 30k primary, 0 secondary (default)
        uint256 buyAmount = 1_000e6;
        vm.prank(owner);
        usdc.mint(investor, buyAmount);

        vm.startPrank(investor);
        usdc.approve(address(limitedSeller), buyAmount);

        uint256[] memory pids = new uint256[](1);
        pids[0] = PID;

        _limitedBuyWithSig(investor, buyAmount, pids);
        vm.stopPrank();

        assertEq(limitedSeller.boughtUsdcByUser(investor), buyAmount);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    setMarket
    // ═══════════════════════════════════════════════════════════════

    function test_setMarket_success() public {
        address newMarket = makeAddr("newMarket");
        vm.prank(owner);
        limitedSeller.setMarket(newMarket);
        assertEq(address(limitedSeller.market()), newMarket);
    }

    function test_setMarket_revert_notOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        limitedSeller.setMarket(makeAddr("newMarket"));
    }

    // ═══════════════════════════════════════════════════════════════
    //                    addEarnedLimit
    // ═══════════════════════════════════════════════════════════════

    function test_addEarnedLimit_success() public {
        // Only fundraise can call
        vm.prank(address(mockFundraise));
        limitedSeller.addEarnedLimit(investor, 10_000e6);

        // 10_000e6 * 60_000 / 1_000_000 = 600e6
        assertEq(limitedSeller.earnedLimitUsdc(investor), 600e6);
    }

    function test_addEarnedLimit_accumulates() public {
        vm.startPrank(address(mockFundraise));
        limitedSeller.addEarnedLimit(investor, 10_000e6);
        limitedSeller.addEarnedLimit(investor, 5_000e6);
        vm.stopPrank();

        // (10_000 + 5_000) * 6% = 900
        assertEq(limitedSeller.earnedLimitUsdc(investor), 900e6);
    }

    function test_addEarnedLimit_revert_notFundraise() public {
        vm.prank(attacker);
        vm.expectRevert(LimitedSeller.OnlyFundraise.selector);
        limitedSeller.addEarnedLimit(investor, 10_000e6);
    }

    function test_addEarnedLimit_revert_ownerCannotCall() public {
        vm.prank(owner);
        vm.expectRevert(LimitedSeller.OnlyFundraise.selector);
        limitedSeller.addEarnedLimit(investor, 10_000e6);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    migrateEarnedLimits
    // ═══════════════════════════════════════════════════════════════

    function test_migrateEarnedLimits_success() public {
        address[] memory users = new address[](2);
        users[0] = investor;
        users[1] = investor2;
        uint256[] memory limits = new uint256[](2);
        limits[0] = 1_800e6;
        limits[1] = 500e6;

        vm.prank(owner);
        limitedSeller.migrateEarnedLimits(users, limits);

        assertEq(limitedSeller.earnedLimitUsdc(investor), 1_800e6);
        assertEq(limitedSeller.earnedLimitUsdc(investor2), 500e6);
    }

    function test_migrateEarnedLimits_revert_notOwner() public {
        address[] memory users = new address[](1);
        users[0] = investor;
        uint256[] memory limits = new uint256[](1);
        limits[0] = 1_000e6;

        vm.prank(attacker);
        vm.expectRevert();
        limitedSeller.migrateEarnedLimits(users, limits);
    }

    function test_migrateEarnedLimits_revert_lengthMismatch() public {
        address[] memory users = new address[](2);
        users[0] = investor;
        users[1] = investor2;
        uint256[] memory limits = new uint256[](1);
        limits[0] = 1_000e6;

        vm.prank(owner);
        vm.expectRevert("Length mismatch");
        limitedSeller.migrateEarnedLimits(users, limits);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    estimateAvailableBuy with earnedLimit
    // ═══════════════════════════════════════════════════════════════

    function test_estimateAvailableBuy_usesEarnedLimit() public {
        // Set earned limit for investor (simulating post-upgrade invest)
        vm.prank(address(mockFundraise));
        limitedSeller.addEarnedLimit(investor, 30_000e6); // → 1_800e6 earned

        uint256[] memory pids = new uint256[](1);
        pids[0] = PID;

        LimitedSeller.EstimateResult memory result = limitedSeller.estimateAvailableBuy(investor, pids);
        assertEq(result.availableBuyTokensInUSDC, 1_800e6);
    }

    function test_estimateAvailableBuy_fallbackForLegacyUser() public {
        // investor has no earnedLimitUsdc (legacy user, not migrated)
        // Should fallback to on-chain calculation
        assertEq(limitedSeller.earnedLimitUsdc(investor), 0);

        uint256[] memory pids = new uint256[](1);
        pids[0] = PID;

        LimitedSeller.EstimateResult memory result = limitedSeller.estimateAvailableBuy(investor, pids);
        // Legacy: 30_000e6 * 6% = 1_800e6
        assertEq(result.availableBuyTokensInUSDC, 1_800e6);
    }

    // ═══════════════════════════════════════════════════════════════
    //           BUG FIX: sell investment does NOT reduce limit
    // ═══════════════════════════════════════════════════════════════

    /// @notice Reproduces the reported bug scenario and verifies the fix
    function test_bugFix_sellInvestmentDoesNotReduceLimit() public {
        // Step 1: investor invests 4_800 USDC (simulated via addEarnedLimit)
        vm.prank(address(mockFundraise));
        limitedSeller.addEarnedLimit(investor, 4_800e6);
        // earnedLimitUsdc = 4_800 * 6% = 288

        uint256[] memory pids = new uint256[](1);
        pids[0] = PID;

        // Step 2: buy tokens for full limit (288 USDC)
        vm.prank(owner);
        usdc.mint(investor, 288e6);
        vm.startPrank(investor);
        usdc.approve(address(limitedSeller), 288e6);
        _limitedBuyWithSig(investor, 288e6, pids);
        vm.stopPrank();

        assertEq(limitedSeller.boughtUsdcByUser(investor), 288e6);

        // Step 3: investor sells investment on secondary market
        // In the old code this would reduce fundedProjectsInvestedTotal
        // With new code, earnedLimitUsdc stays at 288e6

        // Simulate: investment goes down to 4_500 on-chain
        vm.prank(owner);
        mockFundraise.setInvestorInfo(investor, PID, 4_500e6, 0);

        // Available should be 0 (288 earned - 288 bought = 0), NOT negative/broken
        LimitedSeller.EstimateResult memory result = limitedSeller.estimateAvailableBuy(investor, pids);
        assertEq(result.availableBuyTokensInUSDC, 0);

        // Step 4: new investment of 5_000 USDC
        vm.prank(address(mockFundraise));
        limitedSeller.addEarnedLimit(investor, 5_000e6);
        // earnedLimitUsdc = 288 + 300 = 588

        // Now available = 588 - 288 = 300
        result = limitedSeller.estimateAvailableBuy(investor, pids);
        assertEq(result.availableBuyTokensInUSDC, 300e6);

        // Step 5: investor can actually buy these 300 USDC
        vm.prank(owner);
        usdc.mint(investor, 300e6);
        vm.startPrank(investor);
        usdc.approve(address(limitedSeller), 300e6);
        _limitedBuyWithSig(investor, 300e6, pids);
        vm.stopPrank();

        assertEq(limitedSeller.boughtUsdcByUser(investor), 588e6);
    }

    /// @notice Earned limit is independent of secondary market activity
    function test_earnedLimit_ignoredSecondaryMarket() public {
        address user = makeAddr("earnerUser");

        // User earned limit via primary investment
        vm.prank(address(mockFundraise));
        limitedSeller.addEarnedLimit(user, 50_000e6); // → 3_000e6 earned

        // User also bought something on secondary market (should not matter)
        vm.prank(owner);
        mockFundraise.setInvestorInfo(user, PID, 80_000e6, 0);
        mockMarket.setSecondaryInvestedAmount(user, PID, 30_000e6);

        uint256[] memory pids = new uint256[](1);
        pids[0] = PID;

        LimitedSeller.EstimateResult memory result = limitedSeller.estimateAvailableBuy(user, pids);
        // Uses earnedLimitUsdc (3_000e6), NOT on-chain calc
        assertEq(result.availableBuyTokensInUSDC, 3_000e6);
    }

    /// @notice Migrated user gets correct limit even after selling investment
    function test_migratedUser_limitPreservedAfterSell() public {
        // Migrate: user historically had 10_000 invested → 600 limit
        address[] memory users = new address[](1);
        users[0] = investor;
        uint256[] memory limits = new uint256[](1);
        limits[0] = 600e6;

        vm.prank(owner);
        limitedSeller.migrateEarnedLimits(users, limits);

        // Simulate: investment was sold, on-chain shows less
        vm.prank(owner);
        mockFundraise.setInvestorInfo(investor, PID, 5_000e6, 0);

        uint256[] memory pids = new uint256[](1);
        pids[0] = PID;

        // Should use migrated earnedLimitUsdc, not on-chain calc
        LimitedSeller.EstimateResult memory result = limitedSeller.estimateAvailableBuy(investor, pids);
        assertEq(result.availableBuyTokensInUSDC, 600e6);
    }
}
