// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";
import "../../../contracts/core/market/Market.sol";

/// @notice Regression suite for CRITICAL finding #1 + HIGH finding #2 (.docs/findings.md),
///         locking in fix variant A (single source of truth for the claimed watermark).
///
/// Fix A: `Fundraise.transferPosition` derives the claimed watermark a position carries from
/// the holder's aggregate (`aggClaimed * posAmount / aggInvested`, rounded up) instead of
/// reading the stale per-position field that `claim()` never updates. The Market price gate
/// derives the same value, and `claim()` enforces a per-project solvency backstop
/// (`projectTotalClaimed[pid] <= totalRepaid`).
///
/// These tests assert the SECURE (post-fix) behavior: a buyer of an already-claimed position
/// inherits the correct watermark and can claim nothing extra. If finding #1 is ever
/// reintroduced, they go red.
contract DoubleClaimMarketTest is Setup {
    Market public market;

    function setUp() public override {
        super.setUp();

        // Deploy a real Market (UUPS proxy) and wire it into the registry so its
        // calls to Fundraise.transferPosition pass the `isMarket` gate.
        vm.startPrank(owner);
        Market impl = new Market();
        bytes memory initData = abi.encodeCall(Market.initialize, (address(managerRegistry)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        market = Market(address(proxy));
        managerRegistry.setMarketAddress(address(market));
        vm.stopPrank();
    }

    // ── Read project.innerStruct.totalRepaid in an isolated frame (avoids stack-too-deep) ──
    function _totalRepaid(uint256 pid) internal view returns (uint256) {
        ( , , , , , , , Fundraise.InnerProjectStruct memory inner) = fundraise.projects(pid);
        return inner.totalRepaid;
    }

    // ── Backend (trustedSigner) KYC signature over (buyer, saleId), as Market.buy expects ──
    function _signMarketBuy(address buyer, uint256 saleId) internal view returns (bytes memory sig) {
        bytes32 messageHash = keccak256(abi.encodePacked(buyer, saleId));
        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(backendPk, ethSignedMessageHash);
        sig = abi.encodePacked(r, s, v);
    }

    /// @notice One hop: `seller` sells position `posIndex`, `buyer` buys it with a valid KYC
    ///         signature, then `buyer` claims. Returns how much `buyer` was paid on claim.
    function _sellBuyClaim(uint256 pid, address seller, address buyer, uint256 posIndex)
        internal
        returns (uint256 claimed)
    {
        uint256 price = 1_000e6;

        vm.prank(seller);
        uint256 saleId = market.sell(pid, price, posIndex);

        vm.prank(owner);
        usdc.mint(buyer, price);
        bytes memory sig = _signMarketBuy(buyer, saleId);
        vm.startPrank(buyer);
        usdc.approve(address(market), price);
        market.buy(saleId, sig);
        vm.stopPrank();

        uint256 before = usdc.balanceOf(buyer);
        vm.prank(buyer);
        fundraise.claim(pid, buyer);
        claimed = usdc.balanceOf(buyer) - before;
    }

    // ═══════════════════════════════════════════════════════════════════
    //  #1 — buyer of an already-claimed position cannot double-claim
    // ═══════════════════════════════════════════════════════════════════

    function test_doubleClaimIsBlocked_viaSecondaryMarket() public {
        // Other investors' liquidity custodied in the shared balance (P2 stays Open).
        address victimLP = makeAddr("victimLP");
        uint256 pid2 = _createProject(40_000e6, 100_000e6);
        _investAs(victimLP, pid2, 50_000e6, inviter);

        // Victim project P1: A is the sole investor (100% share).
        uint256 pid1 = _createProject(10_000e6, 30_000e6);
        uint256 X = 30_000e6;
        _investAs(investor, pid1, X, inviter);
        _fundProject(pid1);

        uint256 R = 10_000e6;
        _repay(pid1, R); // partial repay → P1 stays Funded (sellable)

        // ── A claims its full pro-rata share R ──
        uint256 aBefore = usdc.balanceOf(investor);
        vm.prank(investor);
        fundraise.claim(pid1, investor);
        uint256 firstClaim = usdc.balanceOf(investor) - aBefore;
        assertEq(firstClaim, R, "A claims full repaid amount R");

        // ── A lists the drained position; the gate now derives the claimed watermark ──
        uint256 price = 1_000e6;
        vm.prank(investor);
        uint256 saleId = market.sell(pid1, price, 0);

        // ── Honest buyer B buys with a valid backend KYC signature ──
        vm.prank(owner);
        usdc.mint(investor2, price);
        bytes memory sig = _signMarketBuy(investor2, saleId);
        vm.startPrank(investor2);
        usdc.approve(address(market), price);
        market.buy(saleId, sig);
        vm.stopPrank();

        // FIX: B inherits the correct watermark R (derived at transfer), not the stale 0.
        (, uint256 bClaimedWatermark) = fundraise.investorInfo(investor2, pid1);
        assertEq(bClaimedWatermark, R, "buyer inherits correct watermark = R");
        // Seller's orphaned watermark is gone too.
        (uint256 aInvested, uint256 aClaimed) = fundraise.investorInfo(investor, pid1);
        assertEq(aInvested, 0, "seller aggregate invested drained to 0");
        assertEq(aClaimed, 0, "seller orphaned watermark cleared");

        // ── B claims → nothing extra ──
        uint256 bBefore = usdc.balanceOf(investor2);
        vm.prank(investor2);
        fundraise.claim(pid1, investor2);
        uint256 secondClaim = usdc.balanceOf(investor2) - bBefore;
        assertEq(secondClaim, 0, "FIX: buyer of a drained position claims nothing extra");

        // Total payout never exceeds what was repaid.
        assertEq(_totalRepaid(pid1), R, "only R was repaid into P1");
        assertEq(firstClaim + secondClaim, R, "cumulative payout == totalRepaid (no double-claim)");

        // Solvency preserved: P2's depositor funds are untouched.
        assertEq(usdc.balanceOf(address(fundraise)), 50_000e6, "P2 liquidity intact");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  #1 — a resale chain across fresh addresses still cannot double-claim
    // ═══════════════════════════════════════════════════════════════════

    function test_resaleChainCannotDoubleClaim() public {
        address victimLP = makeAddr("victimLP");
        uint256 pid2 = _createProject(40_000e6, 200_000e6);
        _investAs(victimLP, pid2, 100_000e6, inviter);

        uint256 pid1 = _createProject(10_000e6, 30_000e6);
        _investAs(investor, pid1, 30_000e6, inviter);
        _fundProject(pid1);
        uint256 R = 10_000e6;
        _repay(pid1, R);

        vm.prank(investor);
        fundraise.claim(pid1, investor); // A claims R

        address sybilB = makeAddr("sybilB");
        address sybilC = makeAddr("sybilC");

        uint256 claimB = _sellBuyClaim(pid1, investor, sybilB, 0); // A → B
        uint256 claimC = _sellBuyClaim(pid1, sybilB, sybilC, 0);   // B → C

        assertEq(claimB, 0, "B inherits watermark R, claims nothing");
        assertEq(claimC, 0, "C inherits watermark R, claims nothing");
        assertEq(_totalRepaid(pid1), R, "still only R repaid");
        assertEq(usdc.balanceOf(address(fundraise)), 100_000e6, "P2 liquidity intact across the chain");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  #1 — single-address self-launder (sell + cancel) yields 0 (unchanged)
    // ═══════════════════════════════════════════════════════════════════

    function test_selfCancelCannotDoubleClaim() public {
        uint256 pid = _createProject(10_000e6, 30_000e6);
        _investAs(investor, pid, 30_000e6, inviter);
        _fundProject(pid);
        _repay(pid, 10_000e6);

        vm.prank(investor);
        fundraise.claim(pid, investor); // A claims R

        vm.prank(investor);
        uint256 saleId = market.sell(pid, 1_000e6, 0);
        vm.prank(investor);
        market.cancel(saleId);

        uint256 before = usdc.balanceOf(investor);
        vm.prank(investor);
        fundraise.claim(pid, investor);
        assertEq(usdc.balanceOf(investor) - before, 0, "self-cancel re-claim nets 0");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  #2 — Market price gate uses the derived claimed watermark
    // ═══════════════════════════════════════════════════════════════════

    function test_priceGate_usesDerivedClaimed() public {
        uint256 pid = _createProject(10_000e6, 30_000e6);
        _investAs(investor, pid, 30_000e6, inviter);
        _fundProject(pid);
        _repay(pid, 10_000e6);

        // A claims R=10k. maxReturn = 30k + 20% = 36k; remaining bound = 36k - 10k = 26k.
        vm.prank(investor);
        fundraise.claim(pid, investor);

        // Listing above the derived bound now reverts (previously it allowed the full 36k).
        vm.prank(investor);
        vm.expectRevert("Price exceeds buyer return");
        market.sell(pid, 26_000e6 + 1, 0);

        // At the bound it succeeds, and the snapshot reflects the derived claimed value.
        vm.prank(investor);
        uint256 saleId = market.sell(pid, 26_000e6, 0);
        Market.Sale memory sale = market.getSale(saleId);
        assertEq(sale.totalClaimed, 10_000e6, "sale snapshot uses derived claimed");
        assertEq(sale.maxReturn, 36_000e6, "maxReturn unchanged");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Mandatory CI invariant (findings.md): invest→repay→claim→sell→buy→claim
    //  never pays out more than totalRepaid.
    // ═══════════════════════════════════════════════════════════════════

    function test_invariant_payoutNeverExceedsTotalRepaid() public {
        address victimLP = makeAddr("victimLP");
        uint256 pid2 = _createProject(40_000e6, 100_000e6);
        _investAs(victimLP, pid2, 50_000e6, inviter);

        uint256 pid = _createProject(10_000e6, 30_000e6);
        _investAs(investor, pid, 30_000e6, inviter);
        _fundProject(pid);
        uint256 R = 10_000e6;
        _repay(pid, R);

        vm.prank(investor);
        fundraise.claim(pid, investor);

        uint256 reclaim = _sellBuyClaim(pid, investor, investor2, 0);
        assertEq(reclaim, 0, "buyer of a drained position can claim nothing extra");
        assertEq(_totalRepaid(pid), R, "totalRepaid unchanged");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Defense-in-depth: per-project solvency counter tracks claims and never
    //  blocks legitimate pro-rata claims across multiple repayments.
    // ═══════════════════════════════════════════════════════════════════

    function test_projectTotalClaimed_tracksLegitClaims() public {
        uint256 pid = _createProject(10_000e6, 40_000e6);
        _investAs(investor, pid, 20_000e6, inviter);
        _investAs(investor2, pid, 20_000e6, inviter);
        _fundProject(pid);

        // First repayment, both claim their pro-rata share.
        _repay(pid, 10_000e6);
        vm.prank(investor);
        fundraise.claim(pid, investor);
        vm.prank(investor2);
        fundraise.claim(pid, investor2);
        assertEq(fundraise.projectTotalClaimed(pid), 10_000e6, "counter tracks first round");
        assertLe(fundraise.projectTotalClaimed(pid), _totalRepaid(pid), "never exceeds repaid");

        // Second repayment, claim again — still bounded by totalRepaid.
        _repay(pid, 10_000e6);
        vm.prank(investor);
        fundraise.claim(pid, investor);
        vm.prank(investor2);
        fundraise.claim(pid, investor2);
        assertEq(fundraise.projectTotalClaimed(pid), 20_000e6, "counter tracks second round");
        assertLe(fundraise.projectTotalClaimed(pid), _totalRepaid(pid), "still never exceeds repaid");
    }
}
