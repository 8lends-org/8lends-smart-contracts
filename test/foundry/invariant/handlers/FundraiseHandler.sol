// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {Fundraise} from "../../../../contracts/fundraise/Fundraise.sol";
import {ManagerRegistry} from "../../../../contracts/manager-registry/ManagerRegistry.sol";
import "../../mocks/MockUSDC.sol";

/// @notice Handler for Fundraise invariant testing.
/// @dev The fuzzer calls these functions in random order to exercise the protocol.
///      Ghost variables track cumulative state for invariant assertions.
contract FundraiseHandler is Test {
    Fundraise public fundraise;
    MockUSDC public usdc;
    ManagerRegistry public managerRegistry;

    uint256 public backendPk;
    address public owner;
    address public manager;
    address public borrower;
    address[] public investors;

    uint256 public pid;
    uint256 constant BP = 1_000_000;

    // ── Ghost variables ──
    uint256 public ghost_totalInvested;
    uint256 public ghost_totalClaimed;
    uint256 public ghost_totalRepaid;
    uint256 public ghost_platformFee;
    uint256 public ghost_borrowerReceived;
    bool public ghost_isFunded;

    // Track calls for debugging
    uint256 public calls_invest;
    uint256 public calls_fund;
    uint256 public calls_repay;
    uint256 public calls_claim;

    constructor(
        Fundraise _fundraise,
        MockUSDC _usdc,
        ManagerRegistry _managerRegistry,
        uint256 _backendPk,
        address _owner,
        address _manager,
        address _borrower,
        address[] memory _investors,
        uint256 _pid
    ) {
        fundraise = _fundraise;
        usdc = _usdc;
        managerRegistry = _managerRegistry;
        backendPk = _backendPk;
        owner = _owner;
        manager = _manager;
        borrower = _borrower;
        investors = _investors;
        pid = _pid;
    }

    /// @notice Random investor invests a random amount
    function invest(uint256 investorIdx, uint256 amount) external {
        investorIdx = bound(investorIdx, 0, investors.length - 1);
        amount = bound(amount, 100e6, 5_000e6);
        address inv = investors[investorIdx];

        // Check project is Open and has room
        (uint256 hardCap,, uint256 totalInvested,,,,, Fundraise.InnerProjectStruct memory inner) =
            fundraise.projects(pid);

        if (uint8(inner.stage) != uint8(Fundraise.Stage.Open)) return;
        if (totalInvested + amount > hardCap) {
            // Clamp to remaining space
            amount = hardCap - totalInvested;
            if (amount < 100e6) return;
        }

        // Mint USDC, approve, sign, invest
        vm.prank(owner);
        usdc.mint(inv, amount);

        vm.prank(inv);
        usdc.approve(address(fundraise), amount);

        uint256 nonce = fundraise.userNonces(inv);
        bytes32 innerHash = keccak256(abi.encodePacked(inv, pid, amount, nonce + 1, address(0)));
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", innerHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(backendPk, ethHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(inv);
        fundraise.investUpdate(pid, amount, nonce + 1, sig, address(0));

        ghost_totalInvested += amount;
        calls_invest++;
    }

    /// @notice Fund the project (transfer to borrower)
    function fund() external {
        if (ghost_isFunded) return;

        (,uint256 softCap, uint256 totalInvested,,,,, Fundraise.InnerProjectStruct memory inner) =
            fundraise.projects(pid);

        if (uint8(inner.stage) != uint8(Fundraise.Stage.Open) &&
            uint8(inner.stage) != uint8(Fundraise.Stage.PreFunded)) return;

        if (totalInvested < softCap) return;

        uint256 platformFee = (totalInvested * inner.platformInterestRate) / BP;

        vm.prank(manager);
        fundraise.transferFundsToBorrower(pid);

        ghost_platformFee = platformFee;
        ghost_borrowerReceived = totalInvested - platformFee;
        ghost_isFunded = true;
        calls_fund++;
    }

    /// @notice Borrower repays a random amount
    function repay(uint256 amount) external {
        if (!ghost_isFunded) return;

        (,, uint256 totalInvested,,,uint256 interestRate,,Fundraise.InnerProjectStruct memory inner) =
            fundraise.projects(pid);

        if (uint8(inner.stage) != uint8(Fundraise.Stage.Funded)) return;

        uint256 totalOwed = totalInvested + (totalInvested * interestRate) / BP;
        uint256 remaining = totalOwed - inner.totalRepaid;
        if (remaining == 0) return;

        amount = bound(amount, 1e6, remaining);

        vm.prank(owner);
        usdc.mint(borrower, amount);

        vm.prank(borrower);
        usdc.approve(address(fundraise), amount);

        vm.prank(borrower);
        fundraise.makeRepayment(pid, amount);

        ghost_totalRepaid += amount;
        calls_repay++;
    }

    /// @notice Random investor claims
    function claim(uint256 investorIdx) external {
        if (!ghost_isFunded) return;

        investorIdx = bound(investorIdx, 0, investors.length - 1);
        address inv = investors[investorIdx];

        (uint256 invested,) = fundraise.investorInfo(inv, pid);
        if (invested == 0) return;

        uint256 available = fundraise.availableToClaim(pid, inv);
        if (available == 0) return;

        uint256 balBefore = usdc.balanceOf(inv);
        vm.prank(inv);
        fundraise.claim(pid, inv);
        uint256 claimed = usdc.balanceOf(inv) - balBefore;

        ghost_totalClaimed += claimed;
        calls_claim++;
    }
}
