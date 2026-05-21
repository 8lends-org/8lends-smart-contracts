// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../Setup.sol";
import {AmlEscrow} from "../../../contracts/escrow/AmlEscrow.sol";
import {EscrowFactory} from "../../../contracts/escrow/EscrowFactory.sol";
import {IOracle} from "../../../contracts/fundraise/interfaces/IOracle.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Mock oracle that allows configuring priceSource and updatedAt timestamps
contract MockOracleWithStaleness {
    uint8 public constant priceDecimals = 8;

    struct Config {
        uint256 price;
        IOracle.PriceSource priceSource;
        uint256 pythUpdatedAt;
        uint256 chainLinkUpdatedAt;
    }

    mapping(address => Config) public configs;

    function setConfig(
        address _token,
        uint256 _price,
        IOracle.PriceSource _priceSource,
        uint256 _pythUpdatedAt,
        uint256 _chainLinkUpdatedAt
    ) external {
        configs[_token] = Config(_price, _priceSource, _pythUpdatedAt, _chainLinkUpdatedAt);
    }

    function getPrice(address _token) external view returns (IOracle.PriceResult memory result) {
        Config memory c = configs[_token];
        result.price = c.price;
        result.priceSource = c.priceSource;
        result.pythUpdatedAt = c.pythUpdatedAt;
        result.chainLinkUpdatedAt = c.chainLinkUpdatedAt;
        result.pythPrice = c.priceSource == IOracle.PriceSource.Pyth ? c.price : 0;
        result.chainLinkPrice = c.priceSource == IOracle.PriceSource.ChainLink ? c.price : 0;
        result.uniswapPrice = c.priceSource == IOracle.PriceSource.Uniswap ? c.price : 0;
    }
}

contract OracleStalenessTest is Setup {
    AmlEscrow public escrowImpl;
    EscrowFactory public escrowFactory;
    MockOracleWithStaleness public staleOracle;

    function setUp() public override {
        super.setUp();

        escrowImpl = new AmlEscrow();
        EscrowFactory factoryImpl = new EscrowFactory();
        bytes memory initData = abi.encodeCall(
            EscrowFactory.initialize,
            (address(escrowImpl), address(fundraise), address(usdc), backend)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(factoryImpl), initData);
        escrowFactory = EscrowFactory(address(proxy));

        vm.prank(owner);
        fundraise.setAmlGateway(address(escrowFactory));

        // Deploy staleness oracle
        staleOracle = new MockOracleWithStaleness();
    }

    function _createEscrow(address _user) internal returns (AmlEscrow esc) {
        vm.prank(_user);
        esc = AmlEscrow(escrowFactory.createEscrow(_user));
    }

    function _escrowInvest(
        AmlEscrow esc,
        address _user,
        uint256 _pid,
        uint256 _amount,
        address _inviter
    ) internal returns (uint256 reqId) {
        vm.prank(owner);
        usdc.mint(_user, _amount);
        vm.prank(_user);
        usdc.approve(address(esc), _amount);
        reqId = esc.getRequestCount();
        vm.prank(_user);
        esc.invest(_pid, _amount, _inviter);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-023: setMaxPriceAge: owner sets, verify stored
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP023_setMaxPriceAge_ownerSets() public {
        // GAP-023: setMaxPriceAge: owner sets, verify stored
        vm.prank(owner);
        fundraise.setMaxPriceAge(3600);
        assertEq(fundraise.maxPriceAge(), 3600, "maxPriceAge should be 3600");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-024: setMaxPriceAge: non-owner reverts
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP024_setMaxPriceAge_nonOwner_reverts() public {
        // GAP-024: setMaxPriceAge: non-owner reverts
        vm.prank(attacker);
        vm.expectRevert();
        fundraise.setMaxPriceAge(3600);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-025: maxPriceAge=0: stale Pyth price → NOT revert (disabled)
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP025_maxPriceAge0_stalePyth_notRevert() public {
        // GAP-025: maxPriceAge=0: stale Pyth price → NOT revert (disabled)
        vm.startPrank(owner);
        fundraise.setOracle(address(staleOracle));
        fundraise.setMaxPriceAge(0); // disabled
        vm.stopPrank();

        // Configure stale Pyth price (updated 1 year ago)
        staleOracle.setConfig(
            address(usdc),
            1e8,
            IOracle.PriceSource.Pyth,
            block.timestamp - 365 days, // very stale
            0
        );

        uint256 pid = _createProject(100e6, 10_000e6);
        AmlEscrow escrow = _createEscrow(investor);
        uint256 reqId = _escrowInvest(escrow, investor, pid, 100e6, inviter);

        // Should succeed because maxPriceAge == 0 disables staleness check
        vm.prank(backend);
        escrowFactory.approveInvest(investor, reqId);

        (uint256 investedAmount,) = fundraise.investorInfo(investor, pid);
        assertEq(investedAmount, 100e6);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-026: maxPriceAge>0, Pyth at boundary → succeed (NOT stale: > not >=)
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP026_maxPriceAge_pythAtBoundary_succeeds() public {
        // GAP-026: maxPriceAge>0, Pyth updatedAt = block.timestamp - maxPriceAge → succeed
        uint256 maxAge = 3600;
        vm.startPrank(owner);
        fundraise.setOracle(address(staleOracle));
        fundraise.setMaxPriceAge(maxAge);
        vm.stopPrank();

        // updatedAt exactly at boundary: block.timestamp - maxPriceAge
        // staleness check: block.timestamp - updatedAt > maxPriceAge → 3600 > 3600 → false → OK
        staleOracle.setConfig(
            address(usdc),
            1e8,
            IOracle.PriceSource.Pyth,
            block.timestamp - maxAge,
            0
        );

        uint256 pid = _createProject(100e6, 10_000e6);
        AmlEscrow escrow = _createEscrow(investor);
        uint256 reqId = _escrowInvest(escrow, investor, pid, 100e6, inviter);

        vm.prank(backend);
        escrowFactory.approveInvest(investor, reqId);

        (uint256 investedAmount,) = fundraise.investorInfo(investor, pid);
        assertEq(investedAmount, 100e6, "should succeed at exact boundary");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-027: maxPriceAge>0, Pyth updatedAt = boundary - 1 → revert
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP027_maxPriceAge_pythPastBoundary_reverts() public {
        // GAP-027: maxPriceAge>0, Pyth updatedAt = block.timestamp - maxPriceAge - 1 → revert StalePriceData
        uint256 maxAge = 3600;
        vm.startPrank(owner);
        fundraise.setOracle(address(staleOracle));
        fundraise.setMaxPriceAge(maxAge);
        vm.stopPrank();

        staleOracle.setConfig(
            address(usdc),
            1e8,
            IOracle.PriceSource.Pyth,
            block.timestamp - maxAge - 1,
            0
        );

        uint256 pid = _createProject(100e6, 10_000e6);
        AmlEscrow escrow = _createEscrow(investor);
        uint256 reqId = _escrowInvest(escrow, investor, pid, 100e6, inviter);

        vm.prank(backend);
        vm.expectRevert(Fundraise.StalePriceData.selector);
        escrowFactory.approveInvest(investor, reqId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-028: ChainLink: same boundary test
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP028_maxPriceAge_chainLink_boundary() public {
        // GAP-028: ChainLink: same boundary
        uint256 maxAge = 3600;
        vm.startPrank(owner);
        fundraise.setOracle(address(staleOracle));
        fundraise.setMaxPriceAge(maxAge);
        vm.stopPrank();

        // At boundary: succeed
        staleOracle.setConfig(
            address(usdc),
            1e8,
            IOracle.PriceSource.ChainLink,
            0,
            block.timestamp - maxAge
        );

        uint256 pid = _createProject(100e6, 10_000e6);
        AmlEscrow escrow = _createEscrow(investor);
        uint256 reqId = _escrowInvest(escrow, investor, pid, 100e6, inviter);

        vm.prank(backend);
        escrowFactory.approveInvest(investor, reqId);
        (uint256 investedAmount,) = fundraise.investorInfo(investor, pid);
        assertEq(investedAmount, 100e6, "ChainLink at boundary should succeed");

        // Past boundary: revert
        staleOracle.setConfig(
            address(usdc),
            1e8,
            IOracle.PriceSource.ChainLink,
            0,
            block.timestamp - maxAge - 1
        );

        uint256 pid2 = _createProject(100e6, 10_000e6);
        AmlEscrow escrow2 = _createEscrow(investor2);
        uint256 reqId2 = _escrowInvest(escrow2, investor2, pid2, 100e6, inviter);

        vm.prank(backend);
        vm.expectRevert(Fundraise.StalePriceData.selector);
        escrowFactory.approveInvest(investor2, reqId2);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-029: Uniswap source: NOT revert (skip staleness check)
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP029_uniswapSource_skipsStaleness() public {
        // GAP-029: Uniswap source: NOT revert (skip staleness check)
        uint256 maxAge = 1; // very strict
        vm.startPrank(owner);
        fundraise.setOracle(address(staleOracle));
        fundraise.setMaxPriceAge(maxAge);
        vm.stopPrank();

        staleOracle.setConfig(
            address(usdc),
            1e8,
            IOracle.PriceSource.Uniswap,
            0,
            0 // both timestamps zero — would be stale for Pyth/ChainLink
        );

        uint256 pid = _createProject(100e6, 10_000e6);
        AmlEscrow escrow = _createEscrow(investor);
        uint256 reqId = _escrowInvest(escrow, investor, pid, 100e6, inviter);

        vm.prank(backend);
        escrowFactory.approveInvest(investor, reqId);

        (uint256 investedAmount,) = fundraise.investorInfo(investor, pid);
        assertEq(investedAmount, 100e6, "Uniswap should skip staleness");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-030: PriceSource.None: NOT revert
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP030_priceSourceNone_skipsStaleness() public {
        // GAP-030: PriceSource.None: NOT revert
        uint256 maxAge = 1;
        vm.startPrank(owner);
        fundraise.setOracle(address(staleOracle));
        fundraise.setMaxPriceAge(maxAge);
        vm.stopPrank();

        staleOracle.setConfig(
            address(usdc),
            1e8,
            IOracle.PriceSource.None,
            0,
            0
        );

        uint256 pid = _createProject(100e6, 10_000e6);
        AmlEscrow escrow = _createEscrow(investor);
        uint256 reqId = _escrowInvest(escrow, investor, pid, 100e6, inviter);

        vm.prank(backend);
        escrowFactory.approveInvest(investor, reqId);

        (uint256 investedAmount,) = fundraise.investorInfo(investor, pid);
        assertEq(investedAmount, 100e6, "None should skip staleness");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-031: Staleness in investFromEscrow path
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP031_staleness_investFromEscrow_reverts() public {
        // GAP-031: Staleness in investFromEscrow path (oracle set, maxPriceAge > 0, stale → revert)
        vm.startPrank(owner);
        fundraise.setOracle(address(staleOracle));
        fundraise.setMaxPriceAge(3600);
        vm.stopPrank();

        staleOracle.setConfig(
            address(usdc),
            1e8,
            IOracle.PriceSource.Pyth,
            block.timestamp - 7200, // 2 hours old, maxAge = 1 hour
            0
        );

        uint256 pid = _createProject(100e6, 10_000e6);
        AmlEscrow escrow = _createEscrow(investor);
        uint256 reqId = _escrowInvest(escrow, investor, pid, 100e6, inviter);

        vm.prank(backend);
        vm.expectRevert(Fundraise.StalePriceData.selector);
        escrowFactory.approveInvest(investor, reqId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-032: Staleness in investUpdateV2 path (_tryToUSD → _toUSD)
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP032_staleness_investUpdateV2_reverts() public {
        // GAP-032: Staleness in investUpdateV2 path (_tryToUSD → _toUSD)
        // When oracle is set, _tryToUSD calls _toUSD which enforces staleness
        vm.startPrank(owner);
        fundraise.setOracle(address(staleOracle));
        fundraise.setMaxPriceAge(3600);
        vm.stopPrank();

        staleOracle.setConfig(
            address(usdc),
            1e8,
            IOracle.PriceSource.ChainLink,
            0,
            block.timestamp - 7200 // stale ChainLink
        );

        uint256 pid = _createProject(100e6, 10_000e6);

        // investUpdateV2 calls _invest which calls _tryToUSD → _toUSD → revert
        vm.prank(owner);
        usdc.mint(investor, 100e6);
        vm.prank(investor);
        usdc.approve(address(fundraise), 100e6);

        uint256 nonce = fundraise.userNonces(investor) + 1;
        bytes memory sig = _signInvest(investor, pid, 100e6, nonce, inviter);

        vm.prank(investor);
        vm.expectRevert(Fundraise.StalePriceData.selector);
        fundraise.investUpdateV2(pid, 100e6, nonce, sig, inviter);
    }
}
