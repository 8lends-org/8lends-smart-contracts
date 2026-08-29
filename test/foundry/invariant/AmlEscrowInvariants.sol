// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../Setup.sol";
import {AmlEscrow} from "../../../contracts/escrow/AmlEscrow.sol";
import {EscrowFactory} from "../../../contracts/escrow/EscrowFactory.sol";
import {IAmlEscrow} from "../../../contracts/interfaces/protocol/IAmlEscrow.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

/// @notice Stateful handler that the Foundry invariant runner calls in random
///         sequences to exercise the AML escrow stack.
contract AmlEscrowHandler is Test {
    // ── Protocol contracts ──
    Fundraise public fundraise;
    EscrowFactory public factory;
    MockUSDC public usdc;

    // ── Actors ──
    address public owner;
    address public signer; // backend / signer

    // ── Populations ──
    address[] internal _users;
    uint256[] internal _projectIds;

    // ── Tracked request identifiers ──
    // Each entry is (userIndex, requestId) packed for simplicity.
    // We keep them separate for readability.
    address[] public requestUser;
    uint256[] public requestId;

    // ── Ghost variables ──
    uint256 public ghost_totalRefunded; // cumulative USDC returned via reject or cancel

    constructor(
        Fundraise _fundraise,
        EscrowFactory _factory,
        MockUSDC _usdc,
        address _owner,
        address _signer,
        address[] memory users_,
        uint256[] memory projectIds_
    ) {
        fundraise = _fundraise;
        factory = _factory;
        usdc = _usdc;
        owner = _owner;
        signer = _signer;

        for (uint256 i = 0; i < users_.length; i++) _users.push(users_[i]);
        for (uint256 i = 0; i < projectIds_.length; i++) _projectIds.push(projectIds_[i]);
    }

    // ── Helpers ──

    function usersLength() external view returns (uint256) {
        return _users.length;
    }

    function users(uint256 i) external view returns (address) {
        return _users[i];
    }

    function projectIdsLength() external view returns (uint256) {
        return _projectIds.length;
    }

    // ── Internal: ensure escrow exists for user ──
    function _ensureEscrow(address u) internal returns (AmlEscrow esc) {
        address addr = factory.escrows(u);
        if (addr == address(0)) {
            // signer is also authorized to create escrows
            vm.prank(signer);
            try factory.createEscrow(u) returns (address e) {
                addr = e;
            } catch {
                return AmlEscrow(address(0));
            }
        }
        esc = AmlEscrow(addr);
    }

    // ── Handler actions ──

    /// @notice Create an escrow for a random user (idempotent)
    function createEscrow(uint256 userIdx) public {
        userIdx = bound(userIdx, 0, _users.length - 1);
        address u = _users[userIdx];
        vm.prank(signer);
        try factory.createEscrow(u) {} catch {}
    }

    /// @notice Random user invests a random amount in a random project
    function invest(uint256 amt, uint256 userIdx, uint256 projectIdx) public {
        userIdx = bound(userIdx, 0, _users.length - 1);
        projectIdx = bound(projectIdx, 0, _projectIds.length - 1);
        address u = _users[userIdx];
        uint256 pid = _projectIds[projectIdx];

        uint256 minAmt = factory.minInvestAmount();
        uint256 maxAmt = factory.maxInvestAmount();
        amt = bound(amt, minAmt, maxAmt);

        AmlEscrow esc = _ensureEscrow(u);
        if (address(esc) == address(0)) return;

        // Mint + approve
        vm.prank(owner);
        usdc.mint(u, amt);
        vm.prank(u);
        usdc.approve(address(esc), amt);

        uint256 newReqId = esc.getRequestCount();
        vm.prank(u);
        try esc.invest(pid, amt, address(0)) {
            requestUser.push(u);
            requestId.push(newReqId);
        } catch {}
    }

    /// @notice Backend approves a tracked request
    function approveRequest(uint256 idx) public {
        uint256 len = requestId.length;
        if (len == 0) return;
        idx = bound(idx, 0, len - 1);

        address u = requestUser[idx];
        uint256 rid = requestId[idx];

        AmlEscrow esc = AmlEscrow(factory.escrows(u));
        if (address(esc) == address(0)) return;
        if (rid >= esc.getRequestCount()) return;

        IAmlEscrow.InvestRequest memory req = esc.getRequest(rid);
        if (req.status != IAmlEscrow.RequestStatus.Pending) return;

        vm.prank(signer);
        try factory.approveInvest(u, rid) {} catch {}
    }

    /// @notice Backend rejects a tracked request (refund → ghost update)
    function rejectRequest(uint256 idx) public {
        uint256 len = requestId.length;
        if (len == 0) return;
        idx = bound(idx, 0, len - 1);

        address u = requestUser[idx];
        uint256 rid = requestId[idx];

        AmlEscrow esc = AmlEscrow(factory.escrows(u));
        if (address(esc) == address(0)) return;
        if (rid >= esc.getRequestCount()) return;

        IAmlEscrow.InvestRequest memory req = esc.getRequest(rid);
        if (req.status != IAmlEscrow.RequestStatus.Pending) return;

        vm.prank(signer);
        try factory.rejectInvest(u, rid) {
            ghost_totalRefunded += req.amount;
        } catch {}
    }

    /// @notice User cancels a tracked request after timeout (refund → ghost update)
    function cancelRequest(uint256 idx, uint256 timeJump) public {
        uint256 len = requestId.length;
        if (len == 0) return;
        idx = bound(idx, 0, len - 1);
        // warp up to 31 days so we can pass the refundTimeout
        timeJump = bound(timeJump, 0, 31 days);

        address u = requestUser[idx];
        uint256 rid = requestId[idx];

        AmlEscrow esc = AmlEscrow(factory.escrows(u));
        if (address(esc) == address(0)) return;
        if (rid >= esc.getRequestCount()) return;

        IAmlEscrow.InvestRequest memory req = esc.getRequest(rid);
        if (req.status != IAmlEscrow.RequestStatus.Pending) return;

        // Warp forward to pass the refund timeout window
        vm.warp(block.timestamp + timeJump);

        vm.prank(u);
        try esc.cancelRequest(rid) {
            ghost_totalRefunded += req.amount;
        } catch {}
    }
}

// ---------------------------------------------------------------------------
// Invariant test contract
// ---------------------------------------------------------------------------

contract AmlEscrowInvariants is Setup {
    AmlEscrowHandler public handler;
    AmlEscrow public escrowImpl;
    EscrowFactory public factory;

    uint256[] public projectIds;

    function setUp() public override {
        super.setUp();

        // Deploy AmlEscrow implementation
        escrowImpl = new AmlEscrow();

        // Deploy EscrowFactory as UUPS proxy
        EscrowFactory factoryImpl = new EscrowFactory();
        bytes memory initData = abi.encodeCall(
            EscrowFactory.initialize,
            (address(escrowImpl), address(fundraise), address(usdc), backend)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(factoryImpl), initData);
        factory = EscrowFactory(address(proxy));

        // Wire factory as Fundraise.amlGateway
        vm.prank(owner);
        fundraise.setAmlGateway(address(factory));

        // Create 3 test projects with generous caps
        for (uint256 i = 0; i < 3; i++) {
            uint256 pid = _createProject(100e6, 100_000_000e6);
            projectIds.push(pid);
        }

        // Populate test users (5 distinct users)
        address[] memory testUsers = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            testUsers[i] = makeAddr(string.concat("escrowUser", vm.toString(i)));
        }

        handler = new AmlEscrowHandler(
            fundraise,
            factory,
            usdc,
            owner,
            backend,
            testUsers,
            projectIds
        );

        // Register handler functions with the invariant runner
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = AmlEscrowHandler.createEscrow.selector;
        selectors[1] = AmlEscrowHandler.invest.selector;
        selectors[2] = AmlEscrowHandler.approveRequest.selector;
        selectors[3] = AmlEscrowHandler.rejectRequest.selector;
        selectors[4] = AmlEscrowHandler.cancelRequest.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    // =========================================================================
    //  INVARIANT 1 — every request.status is a valid enum value (0..3)
    // =========================================================================

    /// @notice All request statuses are within the valid enum range [0, 3].
    function invariant_TerminalStatusValidEnum() public view {
        uint256 numUsers = handler.usersLength();
        for (uint256 i = 0; i < numUsers; i++) {
            address u = handler.users(i);
            AmlEscrow esc = AmlEscrow(factory.escrows(u));
            if (address(esc) == address(0)) continue;

            uint256 count = esc.getRequestCount();
            for (uint256 r = 0; r < count; r++) {
                IAmlEscrow.InvestRequest memory req = esc.getRequest(r);
                // Solidity enum: Pending=0, Approved=1, Rejected=2, Cancelled=3
                assertTrue(
                    uint8(req.status) <= uint8(IAmlEscrow.RequestStatus.Cancelled),
                    "INVARIANT VIOLATED: request status out of valid enum range"
                );
            }
        }
    }

    // =========================================================================
    //  INVARIANT 2 — no double-spend: approved amounts == investorInfo amounts
    // =========================================================================

    /// @notice For each user, the sum of Approved request amounts equals
    ///         the sum of investorInfo(user, pid).investedAmount across all projects.
    function invariant_NoDoubleSpend() public view {
        uint256 numUsers = handler.usersLength();
        uint256 numProjects = projectIds.length;

        for (uint256 i = 0; i < numUsers; i++) {
            address u = handler.users(i);
            AmlEscrow esc = AmlEscrow(factory.escrows(u));

            // Sum approved amounts from escrow requests
            uint256 approvedSum = 0;
            if (address(esc) != address(0)) {
                uint256 count = esc.getRequestCount();
                for (uint256 r = 0; r < count; r++) {
                    IAmlEscrow.InvestRequest memory req = esc.getRequest(r);
                    if (req.status == IAmlEscrow.RequestStatus.Approved) {
                        approvedSum += req.amount;
                    }
                }
            }

            // Sum investorInfo amounts across all test projects
            uint256 investorSum = 0;
            for (uint256 p = 0; p < numProjects; p++) {
                (uint256 invested,) = fundraise.investorInfo(u, projectIds[p]);
                investorSum += invested;
            }

            assertEq(
                approvedSum,
                investorSum,
                "INVARIANT VIOLATED: approved escrow amounts != fundraise investorInfo"
            );
        }
    }



    // =========================================================================
    //  INVARIANT 3 — escrow balance matches pending request amounts
    // =========================================================================

    /// @notice For each deployed escrow, the USDC balance equals the sum of
    ///         amounts for all Pending requests.
    function invariant_EscrowBalanceMatchesPending() public view {
        uint256 numUsers = handler.usersLength();
        for (uint256 i = 0; i < numUsers; i++) {
            address u = handler.users(i);
            address escAddr = factory.escrows(u);
            if (escAddr == address(0)) continue;

            AmlEscrow esc = AmlEscrow(escAddr);
            uint256 count = esc.getRequestCount();

            uint256 pendingSum = 0;
            for (uint256 r = 0; r < count; r++) {
                IAmlEscrow.InvestRequest memory req = esc.getRequest(r);
                if (req.status == IAmlEscrow.RequestStatus.Pending) {
                    pendingSum += req.amount;
                }
            }

            uint256 escrowBalance = usdc.balanceOf(escAddr);
            assertEq(
                escrowBalance,
                pendingSum,
                "INVARIANT VIOLATED: escrow USDC balance != sum of pending request amounts"
            );
        }
    }

    // =========================================================================
    //  INVARIANT 4 — rejected + cancelled refunds match ghost tracking
    // =========================================================================

    /// @notice The sum of Rejected and Cancelled request amounts equals the
    ///         cumulative ghost_totalRefunded tracked in the handler.
    function invariant_RejectedRefundConservation() public view {
        uint256 numUsers = handler.usersLength();
        uint256 contractRefundSum = 0;

        for (uint256 i = 0; i < numUsers; i++) {
            address u = handler.users(i);
            AmlEscrow esc = AmlEscrow(factory.escrows(u));
            if (address(esc) == address(0)) continue;

            uint256 count = esc.getRequestCount();
            for (uint256 r = 0; r < count; r++) {
                IAmlEscrow.InvestRequest memory req = esc.getRequest(r);
                if (
                    req.status == IAmlEscrow.RequestStatus.Rejected ||
                    req.status == IAmlEscrow.RequestStatus.Cancelled
                ) {
                    contractRefundSum += req.amount;
                }
            }
        }

        assertEq(
            contractRefundSum,
            handler.ghost_totalRefunded(),
            "INVARIANT VIOLATED: on-chain refund sum != ghost_totalRefunded"
        );
    }

    // =========================================================================
    //  FUZZ TEST 1 — random valid amount always succeeds
    // =========================================================================

    /// @notice An invest with amount in [minInvest, maxInvest] always succeeds.
    function testFuzz_InvestRandomAmount(uint256 amt) public {
        uint256 minAmt = factory.minInvestAmount();
        uint256 maxAmt = factory.maxInvestAmount();
        amt = bound(amt, minAmt, maxAmt);

        uint256 pid = _createProject(100e6, 100_000_000e6);

        // Create escrow for the fuzz user
        vm.prank(backend);
        AmlEscrow esc = AmlEscrow(factory.createEscrow(investor));

        // Mint + approve
        vm.prank(owner);
        usdc.mint(investor, amt);
        vm.prank(investor);
        usdc.approve(address(esc), amt);

        uint256 reqId = esc.getRequestCount();
        vm.prank(investor);
        esc.invest(pid, amt, address(0));

        IAmlEscrow.InvestRequest memory req = esc.getRequest(reqId);
        assertEq(req.amount, amt, "Request amount should match invested amount");
        assertEq(uint8(req.status), uint8(IAmlEscrow.RequestStatus.Pending), "Status should be Pending");
    }

    // =========================================================================
    //  FUZZ TEST 2 — below minimum reverts
    // =========================================================================

    /// @notice An invest with amount below minInvestAmount must revert.
    function testFuzz_InvestBelowMinReverts(uint256 amt) public {
        uint256 minAmt = factory.minInvestAmount();
        vm.assume(minAmt > 0); // guard: if min=0 this test is vacuous
        amt = bound(amt, 0, minAmt - 1);

        uint256 pid = _createProject(100e6, 100_000_000e6);

        vm.prank(backend);
        AmlEscrow esc = AmlEscrow(factory.createEscrow(investor));

        vm.prank(owner);
        usdc.mint(investor, amt);
        vm.prank(investor);
        usdc.approve(address(esc), amt);

        vm.prank(investor);
        vm.expectRevert("Below minimum");
        esc.invest(pid, amt, address(0));
    }

    // =========================================================================
    //  FUZZ TEST 3 — above maximum reverts
    // =========================================================================

    /// @notice An invest with amount above maxInvestAmount must revert.
    function testFuzz_InvestAboveMaxReverts(uint256 amt) public {
        uint256 maxAmt = factory.maxInvestAmount();
        // Bound to avoid overflow; type(uint128).max is safe here.
        amt = bound(amt, maxAmt + 1, type(uint128).max);

        uint256 pid = _createProject(100e6, 100_000_000e6);

        vm.prank(backend);
        AmlEscrow esc = AmlEscrow(factory.createEscrow(investor));

        vm.prank(owner);
        usdc.mint(investor, amt);
        vm.prank(investor);
        usdc.approve(address(esc), amt);

        vm.prank(investor);
        vm.expectRevert("Above maximum");
        esc.invest(pid, amt, address(0));
    }
}
