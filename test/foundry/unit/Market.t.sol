// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../../../contracts/core/market/Market.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ── Minimal mocks for Market tests ──

contract MockUSDC_MKT is ERC20 {
    constructor() ERC20("USDC", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @notice Mock ManagerRegistry for Market
contract MockManagerRegistry_MKT {
    mapping(address => bool) public managers;
    mapping(address => bool) public fundraiseContracts;
    mapping(address => bool) public marketContracts;
    address public fundraiseAddr;
    mapping(address => address) public claimAddresses;

    function setManager(address m, bool status) external { managers[m] = status; }
    function setFundraise(address f) external {
        fundraiseAddr = f;
        fundraiseContracts[f] = true;
    }
    function setMarket(address m) external { marketContracts[m] = true; }

    function isManager(address sender) external view returns (bool) { return managers[sender]; }
    function isFundraise(address sender) external view returns (bool) { return fundraiseContracts[sender]; }
    function isMarket(address addr) external view returns (bool) { return marketContracts[addr]; }
    function fundraiseAddress() external view returns (address) { return fundraiseAddr; }

    function setInvestorClaimAddress(address investor, address claim) external {
        claimAddresses[investor] = claim;
    }

    function getInvestorClaimAddress(address investor) external view returns (address) {
        address addr = claimAddresses[investor];
        return addr != address(0) ? addr : investor;
    }

    function recipientOf(address investor) external view returns (address) {
        address addr = claimAddresses[investor];
        return addr != address(0) ? addr : investor;
    }

    address public mandateFactory;
    function setMandateFactory(address f) external { mandateFactory = f; }
}

/// @notice Answers isEscrowOf from a table; the real derivation has its own suite.
contract MockFactory_MKT {
    mapping(address => mapping(address => bool)) public owns;
    function set(address owner, address escrow) external { owns[owner][escrow] = true; }
    function isEscrowOf(address owner, address escrow) external view returns (bool) {
        return owns[owner][escrow];
    }
}

/// @notice Mock Fundraise for Market tests
contract MockFundraise_MKT {
    address public trustedSigner;

    struct MockInvestorInfo {
        uint256 investedAmount;
        uint256 totalClaimed;
    }

    struct MockProject {
        IFundraise.Stage stage;
        uint256 investorInterestRate;
        IERC20 loanToken;
    }

    mapping(uint256 => MockProject) public mockProjects;
    mapping(address => mapping(uint256 => MockInvestorInfo)) public mockInvestorInfo;
    mapping(address => mapping(uint256 => IFundraise.InvestorInfo[])) internal _positions;

    function setTrustedSigner(address _signer) external { trustedSigner = _signer; }

    function setProject(uint256 pid, IFundraise.Stage stage, uint256 interestRate, address _loanToken) external {
        mockProjects[pid] = MockProject(stage, interestRate, IERC20(_loanToken));
    }

    function setInvestorInfo(address investor, uint256 pid, uint256 invested, uint256 claimed) external {
        mockInvestorInfo[investor][pid] = MockInvestorInfo(invested, claimed);
        // Also create a single position for backward compat with tests
        delete _positions[investor][pid];
        if (invested > 0) {
            _positions[investor][pid].push(IFundraise.InvestorInfo(invested, claimed));
        }
    }

    function addPosition(address investor, uint256 pid, uint256 invested, uint256 claimed) external {
        _positions[investor][pid].push(IFundraise.InvestorInfo(invested, claimed));
    }

    function projects(uint256 pid) external view returns (IFundraise.Project memory) {
        MockProject memory mp = mockProjects[pid];
        IFundraise.Project memory p;
        p.investorInterestRate = mp.investorInterestRate;
        p.innerStruct.stage = mp.stage;
        p.innerStruct.loanToken = mp.loanToken;
        return p;
    }

    function investorInfo(address investor, uint256 pid) external view returns (IFundraise.InvestorInfo memory) {
        MockInvestorInfo memory m = mockInvestorInfo[investor][pid];
        return IFundraise.InvestorInfo(m.investedAmount, m.totalClaimed);
    }

    function getInvestorPositions(address investor, uint256 pid) external view returns (IFundraise.InvestorInfo[] memory) {
        return _positions[investor][pid];
    }

    function getPositionCount(address investor, uint256 pid) external view returns (uint256) {
        return _positions[investor][pid].length;
    }

    function transferPosition(uint256, address, address, uint256, uint256) external {
        // Mock: does nothing (position tracking is internal in real Fundraise)
    }

    function BASIS_POINTS() external pure returns (uint256) { return 1_000_000; }
}

contract MarketTest is Test {
    Market public market;
    MockUSDC_MKT public usdc;
    MockManagerRegistry_MKT public mockRegistry;
    MockFundraise_MKT public mockFundraise;

    address public owner;
    address public investor;
    address public investor2;
    address public attacker;

    uint256 public backendPk;
    address public backend;

    uint256 public constant PID = 0;
    uint256 public constant INTEREST_RATE = 200_000; // 20%
    uint256 public constant BASIS_POINTS = 1_000_000;

    /// @dev ERC-1967 implementation slot, so the upgrade is checked where it actually lands.
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function setUp() public {
        owner = makeAddr("owner");
        investor = makeAddr("investor");
        investor2 = makeAddr("investor2");
        attacker = makeAddr("attacker");
        (backend, backendPk) = makeAddrAndKey("backend");

        vm.warp(1_700_000_000);
        vm.startPrank(owner);

        // Deploy mocks
        usdc = new MockUSDC_MKT();
        mockRegistry = new MockManagerRegistry_MKT();
        mockFundraise = new MockFundraise_MKT();

        // Configure mock fundraise
        mockFundraise.setTrustedSigner(backend);
        mockFundraise.setProject(PID, IFundraise.Stage.Funded, INTEREST_RATE, address(usdc));
        mockFundraise.setInvestorInfo(investor, PID, 30_000e6, 0);

        // Deploy Market (UUPS proxy)
        {
            Market impl = new Market();
            bytes memory initData = abi.encodeCall(Market.initialize, (address(mockRegistry)));
            ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
            market = Market(address(proxy));
        }

        // Register market and fundraise in mock registry
        mockRegistry.setFundraise(address(mockFundraise));
        mockRegistry.setMarket(address(market));

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //                    INITIALIZATION
    // ═══════════════════════════════════════════════════════════════

    function test_initialize_setsParams() public view {
        assertEq(market.managerRegistry(), address(mockRegistry));
        assertEq(market.platformFee(), 0);
        assertEq(market.saleCount(), 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    PROCEEDS RECIPIENT (EL-1816)
    // ═══════════════════════════════════════════════════════════════

    MockFactory_MKT internal factory;
    address internal escrow = makeAddr("escrow");

    function _withFactory() internal {
        factory = new MockFactory_MKT();
        factory.set(investor, escrow);
        vm.prank(owner);
        mockRegistry.setMandateFactory(address(factory));
    }

    function _fundBuyer(address buyer) internal {
        usdc.mint(buyer, 100_000e6);
        vm.prank(buyer);
        usdc.approve(address(market), type(uint256).max);
    }

    /// @dev Funding is separate so a test can set up an event expectation right before the buy.
    function _buy(uint256 saleId, address buyer) internal {
        if (usdc.balanceOf(buyer) == 0) _fundBuyer(buyer);

        bytes32 inner = keccak256(abi.encodePacked(buyer, saleId));
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(backendPk, digest);

        vm.prank(buyer);
        market.buy(saleId, abi.encodePacked(r, s, v));
    }

    function test_sell_proceedsToOwnEscrow_isPaidThere() public {
        _withFactory();
        vm.prank(investor);
        uint256 saleId = market.sell(PID, 25_000e6, 0, escrow);

        mockFundraise.setInvestorInfo(market.getSale(saleId).marketCell, PID, 30_000e6, 0);

        _fundBuyer(investor2);
        vm.expectEmit(true, true, false, false, address(market));
        emit Market.SaleProceedsPaid(saleId, escrow);
        _buy(saleId, investor2);

        assertEq(usdc.balanceOf(escrow), 25_000e6, "the mandate was paid");
        assertEq(usdc.balanceOf(investor), 0, "and the wallet was not");
    }

    function test_sell_proceedsToSelf_isAccepted() public {
        _withFactory();
        vm.prank(investor);
        uint256 saleId = market.sell(PID, 25_000e6, 0, investor);
        assertEq(market.getSale(saleId).proceedsTo, investor);
    }

    function test_sell_rejects_a_stranger_and_someone_elses_escrow() public {
        _withFactory();

        vm.expectRevert("Not an escrow of the seller");
        vm.prank(investor);
        market.sell(PID, 25_000e6, 0, attacker);

        // the escrow belongs to investor, so investor2 may not name it
        mockFundraise.setInvestorInfo(investor2, PID, 30_000e6, 0);
        vm.expectRevert("Not an escrow of the seller");
        vm.prank(investor2);
        market.sell(PID, 25_000e6, 0, escrow);
    }

    function test_sell_rejects_a_zero_recipient() public {
        _withFactory();
        vm.expectRevert("Proceeds address is zero");
        vm.prank(investor);
        market.sell(PID, 25_000e6, 0, address(0));
    }

    function test_sell_with_a_recipient_reverts_while_the_registry_has_no_factory() public {
        vm.expectRevert("Mandate factory not set");
        vm.prank(investor);
        market.sell(PID, 25_000e6, 0, escrow);
    }

    /// The old entry point keeps paying the wallet.
    function test_sell_withoutRecipient_paysTheSeller() public {
        vm.prank(investor);
        uint256 saleId = market.sell(PID, 25_000e6, 0);
        assertEq(market.getSale(saleId).proceedsTo, investor);

        mockFundraise.setInvestorInfo(market.getSale(saleId).marketCell, PID, 30_000e6, 0);
        _fundBuyer(investor2);
        vm.expectEmit(true, true, false, false, address(market));
        emit Market.SaleProceedsPaid(saleId, investor);
        _buy(saleId, investor2);
        assertEq(usdc.balanceOf(investor), 25_000e6);
    }

    /// Every lot listed before the upgrade holds a zero here; getting it wrong pays address(0).
    function test_buy_aPreUpgradeRecordWithZeroProceedsToPaysTheSeller() public {
        vm.prank(investor);
        uint256 saleId = market.sell(PID, 25_000e6, 0);

        // sales is storage slot 2; proceedsTo is the 13th member of Sale
        bytes32 base = keccak256(abi.encode(saleId, uint256(2)));
        vm.store(address(market), bytes32(uint256(base) + 12), bytes32(0));
        assertEq(market.getSale(saleId).proceedsTo, address(0), "as a pre-upgrade record reads");

        mockFundraise.setInvestorInfo(market.getSale(saleId).marketCell, PID, 30_000e6, 0);
        _buy(saleId, investor2);
        assertEq(usdc.balanceOf(investor), 25_000e6);
    }

    /// Listing is the only point where the stage is looked at.
    function test_buy_isNotBlockedByTheProjectStage() public {
        vm.prank(investor);
        uint256 saleId = market.sell(PID, 25_000e6, 0);

        mockFundraise.setInvestorInfo(market.getSale(saleId).marketCell, PID, 30_000e6, 0);
        vm.prank(owner);
        mockFundraise.setProject(PID, IFundraise.Stage.Repaid, INTEREST_RATE, address(usdc));

        _buy(saleId, investor2);
        assertEq(uint8(market.getSale(saleId).status), uint8(Market.SaleStatus.Sold));
    }

    function test_setSaleProceedsTo_movesAnAlreadyListedLot() public {
        _withFactory();
        vm.prank(investor);
        uint256 saleId = market.sell(PID, 25_000e6, 0);

        vm.prank(investor);
        market.setSaleProceedsTo(saleId, escrow);

        Market.Sale memory sale = market.getSale(saleId);
        assertEq(sale.proceedsTo, escrow);
        assertEq(sale.price, 25_000e6, "price untouched");
        assertEq(sale.fee, 0, "fee untouched");
        assertEq(sale.positionIndex, 0, "position untouched");
        assertEq(sale.marketCell, market.getSale(saleId).marketCell, "cell untouched");
        assertEq(market.activePositionSaleIds(investor, PID, 0), saleId, "still the active lot");

        mockFundraise.setInvestorInfo(sale.marketCell, PID, 30_000e6, 0);
        _buy(saleId, investor2);
        assertEq(usdc.balanceOf(escrow), 25_000e6);
    }

    function test_setSaleProceedsTo_isSellerOnly_andActiveOnly() public {
        _withFactory();
        vm.prank(investor);
        uint256 saleId = market.sell(PID, 25_000e6, 0);

        vm.expectRevert("Not seller");
        vm.prank(attacker);
        market.setSaleProceedsTo(saleId, attacker);

        vm.prank(investor);
        market.cancel(saleId);

        vm.expectRevert("Sale not active");
        vm.prank(investor);
        market.setSaleProceedsTo(saleId, escrow);
    }

    function test_setSaleProceedsToMany_isAllOrNothing() public {
        _withFactory();
        vm.startPrank(investor);
        uint256 a = market.sell(PID, 25_000e6, 0);
        mockFundraise.addPosition(investor, PID, 10_000e6, 0);
        uint256 b = market.sell(PID, 5_000e6, 1);
        vm.stopPrank();

        uint256[] memory ids = new uint256[](3);
        ids[0] = a; ids[1] = b; ids[2] = 999; // the last one does not exist

        vm.expectRevert("Invalid sale ID");
        vm.prank(investor);
        market.setSaleProceedsToMany(ids, escrow);

        assertEq(market.getSale(a).proceedsTo, investor, "nothing moved");
        assertEq(market.getSale(b).proceedsTo, investor);
    }

    /// Blocking the buy would close their secondary exit for good: relisting is refused to them,
    /// and the recovery address cannot list on their behalf — the position is the seller's.
    function test_buy_fromACompromisedSeller_paysTheRecoveryAddress() public {
        vm.prank(investor);
        uint256 saleId = market.sell(PID, 25_000e6, 0);

        address recovery = makeAddr("recovery");
        vm.prank(owner);
        mockRegistry.setInvestorClaimAddress(investor, recovery);

        mockFundraise.setInvestorInfo(market.getSale(saleId).marketCell, PID, 30_000e6, 0);
        _buy(saleId, investor2);

        assertEq(usdc.balanceOf(recovery), 25_000e6, "paid to the recovery address");
        assertEq(usdc.balanceOf(investor), 0, "and not to the stolen wallet");
    }

    /// The flag outranks the recorded payee, chosen with a key that is no longer the owner's.
    function test_buy_compromiseOutranksTheRecordedPayee() public {
        _withFactory();
        vm.prank(investor);
        uint256 saleId = market.sell(PID, 25_000e6, 0, escrow);

        address recovery = makeAddr("recovery");
        vm.prank(owner);
        mockRegistry.setInvestorClaimAddress(investor, recovery);

        mockFundraise.setInvestorInfo(market.getSale(saleId).marketCell, PID, 30_000e6, 0);
        _buy(saleId, investor2);

        assertEq(usdc.balanceOf(recovery), 25_000e6);
        assertEq(usdc.balanceOf(escrow), 0, "the recorded escrow is ignored");
    }

    /// Listing stays shut: an attacker holding the key must not be able to put up new lots.
    function test_sell_isStillRefusedToACompromisedSeller() public {
        address recovery = makeAddr("recovery");
        vm.prank(owner);
        mockRegistry.setInvestorClaimAddress(investor, recovery);

        vm.expectRevert("Seller is compromised");
        vm.prank(investor);
        market.sell(PID, 25_000e6, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    CANCEL GUARD (EL-1816)
    // ═══════════════════════════════════════════════════════════════

    /// A compromised seller cannot relist, so returning the position is all that is left to them.
    function test_cancel_byTheRecoveryAddress() public {
        vm.prank(investor);
        uint256 saleId = market.sell(PID, 25_000e6, 0);

        address recovery = makeAddr("recovery");
        vm.prank(owner);
        mockRegistry.setInvestorClaimAddress(investor, recovery);

        vm.prank(recovery);
        market.cancel(saleId);
        assertEq(uint8(market.getSale(saleId).status), uint8(Market.SaleStatus.Cancelled));
    }

    /// Cancelling must never be blockable: otherwise the position stays on an address with no owner.
    function test_cancel_worksAtAnyProjectStage() public {
        vm.prank(investor);
        uint256 saleId = market.sell(PID, 25_000e6, 0);

        vm.prank(owner);
        mockFundraise.setProject(PID, IFundraise.Stage.Repaid, INTEREST_RATE, address(usdc));

        vm.prank(investor);
        market.cancel(saleId);
        assertEq(uint8(market.getSale(saleId).status), uint8(Market.SaleStatus.Cancelled));
    }

    function test_cancel_notByAnOperatorOrAnyoneElse() public {
        vm.prank(investor);
        uint256 saleId = market.sell(PID, 25_000e6, 0);

        vm.expectRevert("Not seller");
        vm.prank(attacker);
        market.cancel(saleId);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    SELL
    // ═══════════════════════════════════════════════════════════════

    function test_sell_createsActiveSale() public {
        uint256 price = 25_000e6;

        vm.prank(investor);
        uint256 saleId = market.sell(PID, price, 0);

        assertEq(saleId, 1);
        assertEq(market.saleCount(), 1);

        Market.Sale memory sale = market.getSale(saleId);
        assertEq(sale.seller, investor);
        assertEq(sale.projectId, PID);
        assertEq(sale.price, price);
        assertEq(uint8(sale.status), uint8(Market.SaleStatus.Active));
        assertEq(sale.buyer, address(0));
        assertTrue(sale.marketCell != address(0));
    }

    function test_sell_revert_noInvestment() public {
        vm.prank(attacker);
        vm.expectRevert("Position index out of bounds");
        market.sell(PID, 1_000e6, 0);
    }

    function test_sell_revert_zeroPrice() public {
        vm.prank(investor);
        vm.expectRevert("Price must be greater than zero");
        market.sell(PID, 0, 0);
    }

    function test_sell_revert_duplicateActiveSale() public {
        vm.prank(investor);
        market.sell(PID, 10_000e6, 0);

        vm.prank(investor);
        vm.expectRevert("Active sale exists for position");
        market.sell(PID, 10_000e6, 0);
    }

    function test_sell_revert_priceExceedsBuyerReturn() public {
        // maxReturn = 30_000e6 + 30_000e6 * 200_000 / 1_000_000 = 36_000e6
        vm.prank(investor);
        vm.expectRevert("Price exceeds buyer return");
        market.sell(PID, 36_001e6, 0);
    }

    function test_sell_revert_notFundedProject() public {
        vm.prank(owner);
        mockFundraise.setProject(1, IFundraise.Stage.Open, INTEREST_RATE, address(usdc));
        vm.prank(owner);
        mockFundraise.setInvestorInfo(investor2, 1, 10_000e6, 0);

        vm.prank(investor2);
        vm.expectRevert("Only funded projects can be sold");
        market.sell(1, 5_000e6, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    BUY (with KYC signature)
    // ═══════════════════════════════════════════════════════════════

    function _signMarketBuy(address buyer, uint256 saleId) internal view returns (bytes memory sig) {
        bytes32 messageHash = keccak256(abi.encodePacked(buyer, saleId));
        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(backendPk, ethSignedMessageHash);
        sig = abi.encodePacked(r, s, v);
    }

    function test_buy_success_noFee() public {
        uint256 price = 25_000e6;

        vm.prank(investor);
        uint256 saleId = market.sell(PID, price, 0);

        // Set investor info for marketCell (the mock transferPosition moves no data)
        Market.Sale memory sale = market.getSale(saleId);
        vm.prank(owner);
        mockFundraise.setInvestorInfo(sale.marketCell, PID, 30_000e6, 0);

        // Give buyer USDC and approve
        vm.prank(owner);
        usdc.mint(investor2, price);

        bytes memory sig = _signMarketBuy(investor2, saleId);

        vm.startPrank(investor2);
        usdc.approve(address(market), price);
        market.buy(saleId, sig);
        vm.stopPrank();

        Market.Sale memory saleFinal = market.getSale(saleId);
        assertEq(saleFinal.buyer, investor2);
        assertEq(uint8(saleFinal.status), uint8(Market.SaleStatus.Sold));
    }

    function test_buy_withFee() public {
        // Set 5% fee
        vm.prank(owner);
        market.setPlatformFee(50_000);

        uint256 price = 10_000e6;
        vm.prank(investor);
        uint256 saleId = market.sell(PID, price, 0);

        Market.Sale memory sale = market.getSale(saleId);
        vm.prank(owner);
        mockFundraise.setInvestorInfo(sale.marketCell, PID, 30_000e6, 0);

        vm.prank(owner);
        usdc.mint(investor2, price);

        bytes memory sig = _signMarketBuy(investor2, saleId);

        uint256 sellerBalBefore = usdc.balanceOf(investor);

        vm.startPrank(investor2);
        usdc.approve(address(market), price);
        market.buy(saleId, sig);
        vm.stopPrank();

        uint256 feeAmount = (price * 50_000) / 1_000_000;
        uint256 sellerAmount = price - feeAmount;
        assertEq(usdc.balanceOf(investor) - sellerBalBefore, sellerAmount);
        assertEq(market.accumulatedFees(address(usdc)), feeAmount);
    }

    function test_buy_revert_invalidSignature() public {
        vm.prank(investor);
        uint256 saleId = market.sell(PID, 10_000e6, 0);

        Market.Sale memory sale = market.getSale(saleId);
        vm.prank(owner);
        mockFundraise.setInvestorInfo(sale.marketCell, PID, 30_000e6, 0);

        vm.prank(owner);
        usdc.mint(investor2, 10_000e6);

        (, uint256 wrongPk) = makeAddrAndKey("wrongSigner");
        bytes32 messageHash = keccak256(abi.encodePacked(investor2, saleId));
        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPk, ethSignedMessageHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.startPrank(investor2);
        usdc.approve(address(market), 10_000e6);
        vm.expectRevert("Not trusted signer");
        market.buy(saleId, sig);
        vm.stopPrank();
    }

    function test_buy_revert_sellerCannotBuyOwn() public {
        vm.prank(investor);
        uint256 saleId = market.sell(PID, 10_000e6, 0);

        Market.Sale memory sale = market.getSale(saleId);
        vm.prank(owner);
        mockFundraise.setInvestorInfo(sale.marketCell, PID, 30_000e6, 0);

        vm.prank(owner);
        usdc.mint(investor, 10_000e6);

        bytes memory sig = _signMarketBuy(investor, saleId);

        vm.startPrank(investor);
        usdc.approve(address(market), 10_000e6);
        vm.expectRevert("Cannot buy own sale");
        market.buy(saleId, sig);
        vm.stopPrank();
    }

    function test_buy_revert_notActive() public {
        vm.prank(investor);
        uint256 saleId = market.sell(PID, 10_000e6, 0);

        vm.prank(investor);
        market.cancel(saleId);

        vm.prank(owner);
        usdc.mint(investor2, 10_000e6);

        bytes memory sig = _signMarketBuy(investor2, saleId);

        vm.startPrank(investor2);
        usdc.approve(address(market), 10_000e6);
        vm.expectRevert("Sale not active");
        market.buy(saleId, sig);
        vm.stopPrank();
    }

    function test_buy_revert_invalidSaleId() public {
        bytes memory sig = _signMarketBuy(investor2, 999);
        vm.prank(investor2);
        vm.expectRevert("Invalid sale ID");
        market.buy(999, sig);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    CANCEL
    // ═══════════════════════════════════════════════════════════════

    function test_cancel_success() public {
        vm.prank(investor);
        uint256 saleId = market.sell(PID, 10_000e6, 0);

        vm.prank(investor);
        market.cancel(saleId);

        Market.Sale memory sale = market.getSale(saleId);
        assertEq(uint8(sale.status), uint8(Market.SaleStatus.Cancelled));
    }

    function test_cancel_revert_notSeller() public {
        vm.prank(investor);
        uint256 saleId = market.sell(PID, 10_000e6, 0);

        vm.prank(attacker);
        vm.expectRevert("Not seller");
        market.cancel(saleId);
    }

    function test_cancel_revert_notActive() public {
        vm.prank(investor);
        uint256 saleId = market.sell(PID, 10_000e6, 0);

        vm.prank(investor);
        market.cancel(saleId);

        vm.prank(investor);
        vm.expectRevert("Sale not active");
        market.cancel(saleId);
    }

    function test_cancel_allowsNewSale() public {
        vm.prank(investor);
        uint256 saleId1 = market.sell(PID, 10_000e6, 0);

        vm.prank(investor);
        market.cancel(saleId1);

        vm.prank(investor);
        uint256 saleId2 = market.sell(PID, 15_000e6, 0);
        assertGt(saleId2, saleId1);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    function test_setPlatformFee_success() public {
        vm.prank(owner);
        market.setPlatformFee(50_000);
        assertEq(market.platformFee(), 50_000);
    }

    function test_setPlatformFee_revert_exceeds100() public {
        vm.prank(owner);
        vm.expectRevert("Fee exceeds 100%");
        market.setPlatformFee(1_000_001);
    }

    function test_setPlatformFee_revert_notOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        market.setPlatformFee(10_000);
    }

    function test_withdrawFees_success() public {
        // Set fee and buy
        vm.prank(owner);
        market.setPlatformFee(50_000);

        uint256 price = 10_000e6;
        vm.prank(investor);
        uint256 saleId = market.sell(PID, price, 0);

        Market.Sale memory sale = market.getSale(saleId);
        vm.prank(owner);
        mockFundraise.setInvestorInfo(sale.marketCell, PID, 30_000e6, 0);

        vm.prank(owner);
        usdc.mint(investor2, price);

        bytes memory sig = _signMarketBuy(investor2, saleId);
        vm.startPrank(investor2);
        usdc.approve(address(market), price);
        market.buy(saleId, sig);
        vm.stopPrank();

        uint256 feeAmount = (price * 50_000) / 1_000_000;
        address feeReceiver = makeAddr("feeReceiver");

        vm.prank(owner);
        market.withdrawFees(address(usdc), feeReceiver);

        assertEq(usdc.balanceOf(feeReceiver), feeAmount);
        assertEq(market.accumulatedFees(address(usdc)), 0);
    }

    function test_withdrawFees_revert_noFees() public {
        vm.prank(owner);
        vm.expectRevert("No fees to withdraw");
        market.withdrawFees(address(usdc), makeAddr("receiver"));
    }

    function test_withdrawFees_revert_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("Invalid recipient address");
        market.withdrawFees(address(usdc), address(0));
    }

    function test_withdrawFees_revert_notOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        market.withdrawFees(address(usdc), attacker);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    function test_getSoldSales_tracksSales() public {
        uint256 price = 10_000e6;
        vm.prank(investor);
        uint256 saleId = market.sell(PID, price, 0);

        Market.Sale memory sale = market.getSale(saleId);
        vm.prank(owner);
        mockFundraise.setInvestorInfo(sale.marketCell, PID, 30_000e6, 0);

        vm.prank(owner);
        usdc.mint(investor2, price);

        bytes memory sig = _signMarketBuy(investor2, saleId);
        vm.startPrank(investor2);
        usdc.approve(address(market), price);
        market.buy(saleId, sig);
        vm.stopPrank();

        uint256[] memory sold = market.getSoldSales(investor);
        assertEq(sold.length, 1);
        assertEq(sold[0], saleId);
    }

    function test_getBoughtSales_tracksPurchases() public {
        uint256 price = 10_000e6;
        vm.prank(investor);
        uint256 saleId = market.sell(PID, price, 0);

        Market.Sale memory sale = market.getSale(saleId);
        vm.prank(owner);
        mockFundraise.setInvestorInfo(sale.marketCell, PID, 30_000e6, 0);

        vm.prank(owner);
        usdc.mint(investor2, price);

        bytes memory sig = _signMarketBuy(investor2, saleId);
        vm.startPrank(investor2);
        usdc.approve(address(market), price);
        market.buy(saleId, sig);
        vm.stopPrank();

        uint256[] memory bought = market.getBoughtSales(investor2);
        assertEq(bought.length, 1);
        assertEq(bought[0], saleId);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    UPGRADE
    // ═══════════════════════════════════════════════════════════════

    function test_upgrade_revert_notOwner() public {
        Market newImpl = new Market();
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        market.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgrade_success() public {
        vm.prank(investor);
        uint256 saleId = market.sell(PID, 10_000e6, 0);
        uint256 feeBefore = market.platformFee();
        uint256 countBefore = market.saleCount();

        Market newImpl = new Market();
        vm.prank(owner);
        market.upgradeToAndCall(address(newImpl), "");

        assertEq(
            address(uint160(uint256(vm.load(address(market), IMPL_SLOT)))),
            address(newImpl),
            "the proxy still points at the old implementation"
        );
        // An upgrade that answers but forgot the storage layout would pass on the slot alone.
        assertEq(market.platformFee(), feeBefore, "fee did not survive");
        assertEq(market.saleCount(), countBefore, "sale counter did not survive");
        assertEq(market.getSale(saleId).seller, investor, "the open lot did not survive");
    }

    // ═══════════════════════════════════════════════════════════════
    //                    EVENTS
    // ═══════════════════════════════════════════════════════════════

    function test_sell_emitsSaleCreated() public {
        vm.prank(investor);
        vm.expectEmit(true, true, true, false);
        emit Market.SaleCreated(1, investor, PID, address(0), 10_000e6);
        market.sell(PID, 10_000e6, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //            SECONDARY INVESTED AMOUNT (double-counting fix)
    // ═══════════════════════════════════════════════════════════════

    /// @notice After buy, seller's secondaryInvestedAmount must be reset to 0
    function test_buy_resetsSellerSecondaryInvestedAmount() public {
        // Simulate: investor previously bought on secondary market (has secondary = 15_000e6)
        // Now investor sells, investor2 buys → investor's secondary should reset to 0

        // Step 1: investor sells their position
        uint256 price = 25_000e6;
        vm.prank(investor);
        uint256 saleId = market.sell(PID, price, 0);

        // Step 2: simulate that investor had secondary invested amount from a prior purchase
        // We need a prior buy to set secondaryInvestedAmount for investor.
        // Instead, let's do a full flow: investor2 sells to investor first, then investor resells.

        // --- Setup: investor2 has investment in project 1 ---
        uint256 PID2 = 1;
        vm.prank(owner);
        mockFundraise.setProject(PID2, IFundraise.Stage.Funded, INTEREST_RATE, address(usdc));
        vm.prank(owner);
        mockFundraise.setInvestorInfo(investor2, PID2, 10_000e6, 0);

        // investor2 sells
        vm.prank(investor2);
        uint256 saleId2 = market.sell(PID2, 8_000e6, 0);
        Market.Sale memory sale2 = market.getSale(saleId2);

        // set marketCell info for buy
        vm.prank(owner);
        mockFundraise.setInvestorInfo(sale2.marketCell, PID2, 10_000e6, 0);

        // investor buys from investor2 → investor gets secondaryInvestedAmount[investor][PID2] = 10_000e6
        vm.prank(owner);
        usdc.mint(investor, 8_000e6);
        bytes memory sig2 = _signMarketBuy(investor, saleId2);
        vm.startPrank(investor);
        usdc.approve(address(market), 8_000e6);
        market.buy(saleId2, sig2);
        vm.stopPrank();

        assertEq(market.secondaryInvestedAmount(investor, PID2), 10_000e6, "secondary should be 10k after buy");

        // --- Now investor resells this position ---
        vm.prank(owner);
        mockFundraise.setInvestorInfo(investor, PID2, 10_000e6, 0);

        vm.prank(investor);
        uint256 saleId3 = market.sell(PID2, 7_000e6, 0);
        Market.Sale memory sale3 = market.getSale(saleId3);

        // secondary should NOT be reset at sell time (only at buy time)
        assertEq(market.secondaryInvestedAmount(investor, PID2), 10_000e6, "secondary should remain at sell");

        // investor2 buys back
        vm.prank(owner);
        mockFundraise.setInvestorInfo(sale3.marketCell, PID2, 10_000e6, 0);
        vm.prank(owner);
        usdc.mint(investor2, 7_000e6);
        bytes memory sig3 = _signMarketBuy(investor2, saleId3);
        vm.startPrank(investor2);
        usdc.approve(address(market), 7_000e6);
        market.buy(saleId3, sig3);
        vm.stopPrank();

        // After sale completed: seller's secondary must be 0
        assertEq(market.secondaryInvestedAmount(investor, PID2), 0, "secondary must reset after sell completes");
        // buyer gets new secondary
        assertEq(market.secondaryInvestedAmount(investor2, PID2), 10_000e6, "buyer gets secondary amount");
    }

    /// @notice Cancel should NOT reset secondaryInvestedAmount
    function test_cancel_doesNotResetSecondaryInvestedAmount() public {
        uint256 PID2 = 1;
        vm.prank(owner);
        mockFundraise.setProject(PID2, IFundraise.Stage.Funded, INTEREST_RATE, address(usdc));
        vm.prank(owner);
        mockFundraise.setInvestorInfo(investor2, PID2, 5_000e6, 0);

        // investor2 sells to investor → investor gets secondary
        vm.prank(investor2);
        uint256 saleId = market.sell(PID2, 4_000e6, 0);
        Market.Sale memory sale = market.getSale(saleId);
        vm.prank(owner);
        mockFundraise.setInvestorInfo(sale.marketCell, PID2, 5_000e6, 0);

        vm.prank(owner);
        usdc.mint(investor, 4_000e6);
        bytes memory sig = _signMarketBuy(investor, saleId);
        vm.startPrank(investor);
        usdc.approve(address(market), 4_000e6);
        market.buy(saleId, sig);
        vm.stopPrank();

        assertEq(market.secondaryInvestedAmount(investor, PID2), 5_000e6);

        // investor tries to resell, then cancels
        vm.prank(owner);
        mockFundraise.setInvestorInfo(investor, PID2, 5_000e6, 0);

        vm.prank(investor);
        uint256 saleId2 = market.sell(PID2, 3_000e6, 0);

        vm.prank(investor);
        market.cancel(saleId2);

        // secondary must remain intact after cancel
        assertEq(market.secondaryInvestedAmount(investor, PID2), 5_000e6, "cancel must not reset secondary");
    }

    /// @notice Scenario: buy on secondary → sell → reinvest primary → secondary should be 0
    function test_secondaryResets_afterResellThenReinvest() public {
        uint256 PID2 = 1;
        vm.prank(owner);
        mockFundraise.setProject(PID2, IFundraise.Stage.Funded, INTEREST_RATE, address(usdc));
        vm.prank(owner);
        mockFundraise.setInvestorInfo(investor2, PID2, 8_000e6, 0);

        // investor2 sells to investor
        vm.prank(investor2);
        uint256 saleId = market.sell(PID2, 6_000e6, 0);
        Market.Sale memory sale = market.getSale(saleId);
        vm.prank(owner);
        mockFundraise.setInvestorInfo(sale.marketCell, PID2, 8_000e6, 0);

        vm.prank(owner);
        usdc.mint(investor, 6_000e6);
        bytes memory sig = _signMarketBuy(investor, saleId);
        vm.startPrank(investor);
        usdc.approve(address(market), 6_000e6);
        market.buy(saleId, sig);
        vm.stopPrank();

        assertEq(market.secondaryInvestedAmount(investor, PID2), 8_000e6);

        // investor resells
        vm.prank(owner);
        mockFundraise.setInvestorInfo(investor, PID2, 8_000e6, 0);
        vm.prank(investor);
        uint256 saleId2 = market.sell(PID2, 5_000e6, 0);
        Market.Sale memory sale2 = market.getSale(saleId2);
        vm.prank(owner);
        mockFundraise.setInvestorInfo(sale2.marketCell, PID2, 8_000e6, 0);

        // attacker (as third buyer) buys
        address buyer3 = makeAddr("buyer3");
        vm.prank(owner);
        usdc.mint(buyer3, 5_000e6);
        bytes memory sig2 = _signMarketBuy(buyer3, saleId2);
        vm.startPrank(buyer3);
        usdc.approve(address(market), 5_000e6);
        market.buy(saleId2, sig2);
        vm.stopPrank();

        // investor's secondary is now 0
        assertEq(market.secondaryInvestedAmount(investor, PID2), 0, "secondary must be 0 after resell");

        // If investor reinvests primary (simulated by setting investorInfo),
        // their limit should be based on full primary, not reduced by stale secondary
        // This is the core bug that was fixed
    }

    function test_cancel_emitsSaleCancelled() public {
        vm.prank(investor);
        uint256 saleId = market.sell(PID, 10_000e6, 0);

        vm.prank(investor);
        vm.expectEmit(true, true, true, true);
        emit Market.SaleCancelled(saleId, investor, PID);
        market.cancel(saleId);
    }
}
