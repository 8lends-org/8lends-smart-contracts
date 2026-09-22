// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../unit/Market.t.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice The money split in Market._executeBuy: the buyer pays in two transfers, one to the
///         contract as fee and one to the seller's recipient, and the two must add up to the price
///         the lot was listed at (Market.sol:250-258).
/// @dev Takes the mocks from the unit file but not its test contract — inheriting that would rerun
///      its fifty tests under a second name. The first two properties are stated through balances,
///      not through the formula: they cannot be satisfied by copying the line with the division,
///      only by actually moving the money. Before this file there was no fuzz over Market at all,
///      and the fee was measured at one point — price 10 000, rate 5%.
contract MarketFeeFuzzTest is Test {
    MockUSDC_MKT usdc;
    MockManagerRegistry_MKT mockRegistry;
    MockFundraise_MKT mockFundraise;
    Market market;

    address owner;
    address investor;
    address investor2;
    address backend;
    uint256 backendPk;

    uint256 constant PID = 0;
    uint256 constant INTEREST_RATE = 200_000; // 20%
    uint256 constant BASIS_POINTS = 1_000_000;

    /// @dev The position is 30 000 at 20%, so the price gate allows up to this.
    uint256 constant MAX_PRICE = 36_000e6;

    function setUp() public {
        owner = makeAddr("owner");
        investor = makeAddr("investor");
        investor2 = makeAddr("investor2");
        (backend, backendPk) = makeAddrAndKey("backend");

        vm.warp(1_700_000_000);
        vm.startPrank(owner);

        usdc = new MockUSDC_MKT();
        mockRegistry = new MockManagerRegistry_MKT();
        mockFundraise = new MockFundraise_MKT();

        mockFundraise.setTrustedSigner(backend);
        mockFundraise.setProject(PID, IFundraise.Stage.Funded, INTEREST_RATE, address(usdc));
        mockFundraise.setInvestorInfo(investor, PID, 30_000e6, 0);

        Market impl = new Market();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeCall(Market.initialize, (address(mockRegistry)))
        );
        market = Market(address(proxy));

        mockRegistry.setFundraise(address(mockFundraise));
        mockRegistry.setMarket(address(market));
        vm.stopPrank();
    }

    function _fundBuyer(address buyer) internal {
        vm.prank(owner);
        usdc.mint(buyer, 200_000e6);
        vm.prank(buyer);
        usdc.approve(address(market), type(uint256).max);
    }

    function _buy(uint256 saleId, address buyer) internal {
        if (usdc.balanceOf(buyer) == 0) _fundBuyer(buyer);

        bytes32 inner = keccak256(abi.encodePacked(buyer, saleId));
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(backendPk, digest);

        vm.prank(buyer);
        market.buy(saleId, abi.encodePacked(r, s, v));
    }

    function _setFee(uint256 fee) internal {
        vm.prank(owner);
        market.setPlatformFee(fee);
    }

    /// @dev A lot on `posIndex`, with its market cell funded so the buy can settle.
    function _list(uint256 price, uint256 posIndex) internal returns (uint256 saleId) {
        vm.prank(investor);
        saleId = market.sell(PID, price, posIndex);

        vm.prank(owner);
        mockFundraise.setInvestorInfo(market.getSale(saleId).marketCell, PID, 30_000e6, 0);
    }

    function _fees() internal view returns (uint256) {
        return market.accumulatedFees(address(usdc));
    }

    // ── 1. the buyer pays exactly the price ─────────────────────────────────────

    /// Two transfers leave the buyer, and together they must come to the listed price — no more,
    /// which would overcharge, and no less, which would mean the lot settled for under its price.
    function testFuzz_theBuyerPaysExactlyThePrice(uint256 price, uint256 fee) public {
        price = bound(price, 1, MAX_PRICE);
        fee = bound(fee, 0, BASIS_POINTS);

        _setFee(fee);
        uint256 saleId = _list(price, 0);

        _fundBuyer(investor2);
        uint256 buyerBefore = usdc.balanceOf(investor2);
        _buy(saleId, investor2);

        assertEq(buyerBefore - usdc.balanceOf(investor2), price, "the buyer paid something other than the price");
    }

    // ── 2. nothing is lost between the two transfers ────────────────────────────

    /// What the seller received plus what the contract kept is the price, exactly, at any rate.
    /// A gap either way is money created or destroyed in the split.
    function testFuzz_theSplitLosesNothing(uint256 price, uint256 fee) public {
        price = bound(price, 1, MAX_PRICE);
        fee = bound(fee, 0, BASIS_POINTS);

        _setFee(fee);
        uint256 saleId = _list(price, 0);

        uint256 sellerBefore = usdc.balanceOf(investor);
        uint256 feesBefore = _fees();
        _fundBuyer(investor2);
        _buy(saleId, investor2);

        uint256 toSeller = usdc.balanceOf(investor) - sellerBefore;
        uint256 toFees = _fees() - feesBefore;
        assertEq(toSeller + toFees, price, "the split does not add up to the price");
    }

    // ── 3. the rounding favours the seller ──────────────────────────────────────

    /// The fee floors, so the fraction of a unit that cannot be split goes to the seller rather
    /// than to the platform. Both ends are checked: the fee never exceeds its exact share, and the
    /// seller never gets less than the price minus that share rounded up.
    function testFuzz_theRoundingFavoursTheSeller(uint256 price, uint256 fee) public {
        price = bound(price, 1, MAX_PRICE);
        fee = bound(fee, 0, BASIS_POINTS);

        _setFee(fee);
        uint256 saleId = _list(price, 0);

        uint256 sellerBefore = usdc.balanceOf(investor);
        uint256 feesBefore = _fees();
        _fundBuyer(investor2);
        _buy(saleId, investor2);

        uint256 toSeller = usdc.balanceOf(investor) - sellerBefore;
        uint256 toFees = _fees() - feesBefore;

        assertLe(toFees * BASIS_POINTS, price * fee, "the fee took more than its exact share");
        assertGe(toSeller, price - Math.ceilDiv(price * fee, BASIS_POINTS), "the seller was short-changed");
    }

    // ── 4. the two extreme rates ────────────────────────────────────────────────

    function testFuzz_aZeroRateTakesNothing(uint256 price) public {
        price = bound(price, 1, MAX_PRICE);

        _setFee(0);
        uint256 saleId = _list(price, 0);

        uint256 sellerBefore = usdc.balanceOf(investor);
        _fundBuyer(investor2);
        _buy(saleId, investor2);

        assertEq(usdc.balanceOf(investor) - sellerBefore, price, "the seller did not get the whole price");
        assertEq(_fees(), 0, "a fee was accumulated at a zero rate");
    }

    /// At a full rate the seller is owed nothing, and the transfer of that nothing still has to go
    /// through — it is a safeTransferFrom of zero, and whether that reverts is up to the token.
    function testFuzz_aFullRateLeavesTheSellerNothingAndStillSettles(uint256 price) public {
        price = bound(price, 1, MAX_PRICE);

        _setFee(BASIS_POINTS);
        uint256 saleId = _list(price, 0);

        uint256 sellerBefore = usdc.balanceOf(investor);
        _fundBuyer(investor2);
        _buy(saleId, investor2);

        assertEq(usdc.balanceOf(investor) - sellerBefore, 0, "the seller was paid on a full-rate sale");
        assertEq(_fees(), price, "the whole price should have become fee");
        assertEq(uint8(market.getSale(saleId).status), uint8(Market.SaleStatus.Sold), "the sale did not settle");
    }

    // ── 5. fees accumulate without drift ────────────────────────────────────────

    /// Four lots at four prices: the running total is the sum of the individual fees, and the
    /// roundings do not accumulate into a discrepancy of their own.
    function testFuzz_feesAccumulateExactly(uint256 fee, uint256 a, uint256 b, uint256 c) public {
        fee = bound(fee, 0, BASIS_POINTS);
        uint256[4] memory prices = [
            bound(a, 1, MAX_PRICE),
            bound(b, 1, MAX_PRICE),
            bound(c, 1, MAX_PRICE),
            1 // the smallest lot there is, alongside the fuzzed ones
        ];

        _setFee(fee);
        // Same size as position zero, so one price bound covers every lot.
        vm.startPrank(owner);
        for (uint256 i = 1; i < 4; i++) mockFundraise.addPosition(investor, PID, 30_000e6, 0);
        vm.stopPrank();
        _fundBuyer(investor2);
        uint256 expected;
        for (uint256 i = 0; i < 4; i++) {
            uint256 feesBefore = _fees();
            uint256 saleId = _list(prices[i], i);
            _buy(saleId, investor2);

            expected += (prices[i] * fee) / BASIS_POINTS;
            assertEq(_fees() - feesBefore, (prices[i] * fee) / BASIS_POINTS, "one sale's fee is off");
        }

        assertEq(_fees(), expected, "the running total drifted from the sum of the fees");
    }

    // ── 6. prices too small to carry a fee ──────────────────────────────────────

    /// Below one unit of fee the platform gets nothing and the seller gets everything — and the
    /// sale still goes through rather than reverting on a zero-value transfer.
    function testFuzz_aPriceTooSmallForTheFeePaysNone(uint256 price, uint256 fee) public {
        fee = bound(fee, 1, 999);
        price = bound(price, 1, (BASIS_POINTS / fee) - 1); // price * fee < BASIS_POINTS

        _setFee(fee);
        uint256 saleId = _list(price, 0);

        uint256 sellerBefore = usdc.balanceOf(investor);
        _fundBuyer(investor2);
        _buy(saleId, investor2);

        assertEq(_fees(), 0, "a fee was taken where the exact share is under one unit");
        assertEq(usdc.balanceOf(investor) - sellerBefore, price, "the seller did not get the whole price");
    }
}
